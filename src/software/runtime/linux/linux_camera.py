#!/usr/bin/env python3
"""Single-owner camera/NPU/HDMI daemon; control locally or through SSH.

The kernel owns DDR mappings and GPIOs. This process owns all accepted graph,
frame and display leases. Stop/switch cancels and drains before reuse. No reset,
/dev/mem, cache-attribute manipulation, software full-frame copy or TCP listener.
"""
from __future__ import annotations
import argparse
import ctypes as C
import json
import math
import os
from pathlib import Path
import signal
import socket
import sys
import time

from manifest import require
from npu_runtime import Hardware, Runtime, FRONTEND, RAW, WORKSPACE, CONTROL, STATS

HERE = Path(__file__).resolve().parent
NAMES = {1: "ResNet18", 3: "NEU6", 4: "COCO80"}
IDLE, RUN, LOAD, ERROR = range(4)


def bcd(value, digits):
    value = min(max(int(value), 0), 10 ** digits - 1)
    result = 0
    for digit in range(digits):
        result |= value % 10 << (digit * 4)
        value //= 10
    return result


def load_config(path):
    config = json.loads(Path(path).read_text("utf-8"))
    require(config.get("schema") == 1, "camera config schema")
    for key in ("device", "bundle", "bridge", "socket"):
        require(isinstance(config.get(key), str) and Path(config[key]).is_absolute(), key + " must be absolute")
    require(config.get("model", 3) in NAMES, "configured model must be 1, 3 or 4")
    for key in ("auto_start", "matched_view", "keys_enabled"):
        require(type(config.get(key)) is bool, key + " must be boolean")
    display = config.get("display", {})
    confidence, nms = display.get("confidence", 0.25), display.get("nms", 0.65)
    minimum = display.get("minimum_box_pixels", 6)
    require(type(confidence) in (int, float) and math.isfinite(confidence) and 0 <= confidence <= 1, "display confidence")
    require(type(nms) in (int, float) and math.isfinite(nms) and 0 <= nms <= 1, "display NMS")
    require(type(minimum) is int and 4 <= minimum <= 720, "minimum box pixels 4..720")
    timeout = config.get("inference_timeout_seconds", 900)
    require(type(timeout) in (int, float) and math.isfinite(timeout) and 0 < timeout <= 86400, "inference timeout")
    config["display"] = dict(confidence=confidence, nms=nms, minimum_box_pixels=minimum)
    return config


class Bridge:
    def __init__(self, library, model, options):
        self.lib = C.CDLL(str(library))
        self.lib.npu_camera_bridge_abi.restype = C.c_uint32
        require(self.lib.npu_camera_bridge_abi() == 3, "C bridge ABI mismatch")
        self.lib.npu_camera_new.argtypes = [C.c_uint32, C.c_float, C.c_uint32, C.c_float]
        self.lib.npu_camera_new.restype = C.c_void_p
        self.lib.npu_camera_free.argtypes = [C.c_void_p]
        self.lib.npu_camera_prepare_begin.argtypes = [C.c_void_p, C.c_void_p, C.c_uint32, C.c_void_p, C.c_uint32]
        self.lib.npu_camera_prepare_step.argtypes = [C.c_void_p, C.c_uint32]
        self.lib.npu_camera_post_begin.argtypes = [C.c_void_p, C.c_void_p, C.c_uint32]
        self.lib.npu_camera_post_step.argtypes = [C.c_void_p, C.c_uint32]
        self.lib.npu_camera_result.argtypes = [C.c_void_p, C.POINTER(C.c_uint32), C.c_uint32]
        self.context = self.lib.npu_camera_new(model, options["confidence"], options["minimum_box_pixels"], options["nms"])
        require(bool(self.context), "C bridge allocation/options")

    def close(self):
        if self.context:
            self.lib.npu_camera_free(self.context)
            self.context = None

    def prepare(self, raw_map, raw_offset, workspace, input_offset, input_bytes, progress, cancelled):
        raw = (C.c_ubyte * (1280 * 720 * 2)).from_buffer(raw_map, raw_offset)
        tensor = (C.c_ubyte * input_bytes).from_buffer(workspace, input_offset)
        try:
            require(self.lib.npu_camera_prepare_begin(self.context, C.addressof(raw), len(raw),
                    C.addressof(tensor), input_bytes) == 0, "preprocess initialization")
            while True:
                progress()
                if cancelled():
                    return False
                status = self.lib.npu_camera_prepare_step(self.context, 16)
                require(status >= 0, "preprocess failed")
                if status:
                    return True
        finally:
            del raw, tensor

    def postprocess(self, result, progress, cancelled):
        # The C routines require 8-byte aligned Q16 data, independent of Python
        # bytes' implementation-specific alignment.
        storage = (C.c_uint64 * ((len(result) + 7) // 8))()
        C.memmove(storage, result, len(result))
        require(self.lib.npu_camera_post_begin(self.context, C.addressof(storage), len(result)) == 0,
                "postprocess initialization / output shape")
        while True:
            progress()
            if cancelled():
                return None
            status = self.lib.npu_camera_post_step(self.context, 128)
            require(status >= 0, "postprocess failed")
            if status:
                words = (C.c_uint32 * 52)()
                require(self.lib.npu_camera_result(self.context, words, len(words)) == 0, "postprocess result")
                require(words[3] <= 8, "postprocess box count")
                return dict(classification=words[0], score=words[1], detection=bool(words[2]),
                            boxes=[tuple(words[4 + i * 6:10 + i * 6]) for i in range(words[3])])


class Camera:
    def __init__(self, config):
        self.config = config
        self.selected, self.requested_run = config.get("model", 3), config["auto_start"]
        self.hw, self.runtime, self.bridge, self.server = None, None, None, None
        self.stopping = False
        self.state, self.error, self.last_result = "initializing", None, None
        self.published = 0
        self.rate_start = time.monotonic()
        self.rate_count, self.fps_x100 = 0, 0
        self.next_poll = 0.0
        self.key_previous = self.key_stable = None
        self.key_changed = [0.0] * 4
        self.bridge_model = 0
        self.bridge_options = None
        self.socket_bound = False
        self.intent_version = self.running_version = 0

    def cancelled(self):
        return (self.stopping or not self.requested_run or self.runtime.active != self.selected or
                self.intent_version != self.running_version)

    def changed_intent(self):
        self.intent_version += 1
        if self.runtime:
            self.overlay_state(LOAD if self.requested_run else IDLE)

    def overlay_state(self, state):
        self.runtime.fw(0x194, self.selected)
        self.runtime.fw(0x1A0, state)

    def status(self):
        return dict(state=self.state, selected_model=self.selected, model=NAMES[self.selected],
                    requested_run=self.requested_run, completed_results=self.published,
                    result_fps=self.fps_x100 / 100, display=dict(self.config["display"]),
                    matched_view=self.config["matched_view"], error=self.error, last_result=self.last_result,
                    hardware=self.runtime.status() if self.runtime else None)

    def command(self, request):
        operation = request.get("operation")
        if operation == "status":
            pass
        elif operation == "select":
            require(type(request.get("model")) is int and request["model"] in NAMES, "model must be 1/3/4")
            if self.selected != request["model"]:
                self.selected = request["model"]
                self.changed_intent()
        elif operation == "start":
            require(not self.error, "daemon fault retained; inspect status and safely restart")
            self.requested_run = True
        elif operation == "stop":
            self.requested_run = False
            self.changed_intent()
        elif operation == "display":
            require(isinstance(request.get("display"), dict), "display options must be object")
            require(set(request["display"]) <= {"confidence", "minimum_box_pixels", "nms"}, "unknown display option")
            prospective = dict(self.config)
            prospective["display"] = {**self.config["display"], **request.get("display", {})}
            confidence = prospective["display"]["confidence"]
            minimum = prospective["display"]["minimum_box_pixels"]
            nms = prospective["display"]["nms"]
            require(type(confidence) in (int, float) and math.isfinite(confidence) and 0 <= confidence <= 1,
                    "confidence 0..1")
            require(type(nms) in (int, float) and math.isfinite(nms) and 0 <= nms <= 1, "nms 0..1")
            require(type(minimum) is int and 4 <= minimum <= 720, "minimum box pixels 4..720")
            self.config["display"] = prospective["display"]
            self.changed_intent()
        elif operation == "view":
            require(type(request.get("matched")) is bool, "matched must be boolean")
            self.config["matched_view"] = request["matched"]
            # Live-only mode deliberately suppresses mismatched geometry in PL.
            value = self.runtime.fr(4)
            self.runtime.fw(4, (value | 32) if request["matched"] else (value & ~32))
        else:
            raise ValueError("unsupported camera command")
        return self.status()

    def poll_commands(self):
        if self.server is None:
            return
        for _ in range(4):
            try:
                connection, _ = self.server.accept()
            except BlockingIOError:
                break
            with connection:
                connection.settimeout(0.05)
                try:
                    data = bytearray()
                    while not data.endswith(b"\n"):
                        block = connection.recv(4096)
                        require(bool(block), "incomplete request")
                        data.extend(block)
                        require(len(data) <= 65536, "request exceeds 64 KiB")
                    require(data.count(b"\n") == 1, "one request per connection")
                    request = json.loads(data)
                    require(isinstance(request, dict), "request must be object")
                    response = dict(ok=True, result=self.command(request))
                except (ValueError, TypeError, KeyError, RuntimeError, OSError) as error:
                    response = dict(ok=False, error=str(error))
                try:
                    connection.sendall((json.dumps(response) + "\n").encode())
                except OSError:
                    pass

    def progress(self):
        now = time.monotonic()
        if now < self.next_poll:
            return
        self.next_poll = now + 0.01
        self.poll_commands()
        if not self.config["keys_enabled"]:
            return
        raw = self.hw.key_state()
        if self.key_previous is None:
            self.key_previous = self.key_stable = raw
            self.key_changed = [now] * 4
            return
        pressed = 0
        for index in range(4):
            bit = 1 << index
            if (raw ^ self.key_previous) & bit:
                self.key_changed[index] = now
            if (raw ^ self.key_stable) & bit and now - self.key_changed[index] >= 0.025:
                self.key_stable = (self.key_stable & ~bit) | (raw & bit)
                pressed |= raw & bit
        self.key_previous = raw
        prior_model = self.selected
        if pressed & 1:
            self.selected = 1
        elif pressed & 2:
            self.selected = 3
        elif pressed & 4:
            self.selected = 4
        if pressed & 8 and not self.error:
            self.requested_run = not self.requested_run
        if prior_model != self.selected or pressed & 8:
            self.changed_intent()

    def wait_camera(self, predicate, timeout, why):
        deadline = time.monotonic() + timeout
        while not predicate():
            self.progress()
            if self.stopping:
                raise InterruptedError("camera service stopping")
            require(time.monotonic() < deadline, why)
            time.sleep(0.01)

    def start_preview(self):
        self.hw.write(CONTROL, 4, 0)
        self.hw.write(CONTROL, 12, 0xFFFFFFFF)
        self.hw.write(STATS, 4, 0xFFFFFFFF)
        self.hw.write(STATS, 12, 0xFFFFFFFF)
        control = self.hw.read(CONTROL, 0)
        require(not control & ~7, "unexpected camera control bits")
        # Never pulse stream reset: accepted AXI transactions must drain.
        self.hw.write(CONTROL, 0, control | 2)
        self.wait_camera(lambda: self.hw.read(CONTROL, 8) & 0x41 == 0x41, 15,
                         "camera sensor/stream not ready")
        require(not self.hw.read(CONTROL, 8) & 0x22, "camera sensor/capture fault")
        initial = self.hw.read(STATS, 8)
        self.hw.write(CONTROL, 0, 7)
        control = 8 | 16 | 1 | 4 | (32 if self.config["matched_view"] else 0)
        self.runtime.fw(4, control)
        self.wait_camera(lambda: (self.hw.read(STATS, 8) - initial) & 0xFFFFFFFF >= 3,
                         10, "camera did not capture three complete frames")

    def bind_socket(self):
        path = Path(self.config["socket"])
        require(path.parent.is_dir() and not path.exists(), "camera socket directory missing or path exists")
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(path))
        self.socket_bound = True
        os.chmod(path, 0o600)
        self.server.listen(8)
        self.server.setblocking(False)

    def reset_metrics(self):
        self.rate_start = time.monotonic()
        self.rate_count = self.fps_x100 = 0

    def ensure_bridge(self):
        options = self.config["display"]
        if self.bridge_model == self.selected and self.bridge_options == options:
            return
        if self.bridge:
            self.bridge.close()
        self.bridge = Bridge(self.config["bridge"], self.selected, options)
        self.bridge_model, self.bridge_options = self.selected, dict(options)

    def one_result(self):
        runtime = self.runtime
        model = runtime.models[runtime.active]
        lease = runtime.claim_frame(timeout=5)
        workspace = self.hw.mapping(WORKSPACE)
        self.hw.fence()
        prepared = self.bridge.prepare(self.hw.mapping(RAW), lease["raw_address"] - 0x12000000,
            workspace, model["input_offset"], model["input_bytes"], self.progress, self.cancelled)
        if not prepared:
            runtime.release_frame()
            return
        self.hw.fence()
        output, receipt = runtime.submit(self.config.get("inference_timeout_seconds", 900))
        result = self.bridge.postprocess(output, self.progress, self.cancelled)
        if result is None:
            runtime.release_frame()
            return
        self.progress()
        if self.cancelled():
            runtime.release_frame()
            return
        require(not self.hw.read(CONTROL, 8) & 0x22, "camera capture fault during inference")
        now = time.monotonic()
        elapsed = now - self.rate_start
        fps = self.fps_x100
        if elapsed >= 1.0:
            fps = min(9999, int((self.rate_count + 1) * 100 / elapsed + 0.5))
        hi, lo, check = runtime.fr(0xB4), runtime.fr(0xB0), runtime.fr(0xB4)
        while hi != check:
            hi, lo, check = check, runtime.fr(0xB0), runtime.fr(0xB4)
        current_cycles = lo | hi << 32
        captured = lease.get("captured_cycles", 0)
        # Frontend timestamp is in the fixed 100 MHz video domain.
        capture_ms = ((current_cycles - captured) & 0xFFFFFFFFFFFFFFFF) // 100000
        # Preserve full COCO class IDs in JSON; legacy 3-bit labels show '--'.
        display_boxes = result["boxes"]
        classification = result["classification"]
        if runtime.active == 4:
            classification = 7
            display_boxes = [(*box[:4], 7, box[5]) for box in display_boxes]
        runtime.publish_frame(classification, result["score"], display_boxes, result["detection"],
            model_id=runtime.active,
            inference_ms_bcd=bcd(int(receipt["graph_seconds"] * 1000 + 0.5), 5),
            result_fps_bcd=bcd(fps, 4), capture_delay_bcd=bcd(capture_ms, 5))
        self.rate_count += 1
        if elapsed >= 1.0:
            self.fps_x100 = fps
        self.published += 1
        self.last_result = dict(**receipt, detection=result, result_fps=fps / 100)
        print(json.dumps(dict(event="result", **self.last_result)), flush=True)

    def run(self):
        try:
            require(Path(self.config["bridge"]).is_file(), "build/install app/libnpu_camera.so first")
            self.hw = Hardware(self.config["device"])
            self.runtime = Runtime(self.hw, self.config["bundle"])
            self.runtime.progress_hook = self.progress
            self.runtime.cancel_requested = self.cancelled
            self.overlay_state(LOAD)
            # All three SD packages are validated before any DDR overwrite.
            self.runtime.preload()
            self.start_preview()
            self.bind_socket()
            self.state = "idle"
            self.overlay_state(IDLE)
            print(json.dumps(dict(event="ready", **self.status())), flush=True)
            while not self.stopping:
                self.progress()
                if not self.requested_run:
                    if self.runtime.active:
                        self.runtime.switch(0)
                        self.runtime.fw(4, 8 | 16 | 1 | 4 | (32 if self.config["matched_view"] else 0))
                        self.reset_metrics()
                    self.state = "idle"
                    self.overlay_state(IDLE)
                    time.sleep(0.01)
                    continue
                if self.runtime.active != self.selected:
                    self.state = "switching"
                    self.overlay_state(LOAD)
                    self.runtime.switch(self.selected)
                    self.reset_metrics()
                self.progress()
                if self.stopping or not self.requested_run or self.runtime.active != self.selected:
                    continue
                self.ensure_bridge()
                if self.running_version != self.intent_version:
                    self.reset_metrics()
                self.running_version = self.intent_version
                self.overlay_state(RUN)
                self.state = "running"
                try:
                    self.one_result()
                except TimeoutError:
                    if self.cancelled() and not self.runtime.blocked:
                        if self.runtime.lease is not None:
                            self.runtime.release_frame()
                        continue
                    raise
        except InterruptedError:
            if not self.stopping:
                raise
        except BaseException as error:
            self.error, self.state = str(error), "fault"
            if self.runtime:
                try:
                    self.overlay_state(ERROR)
                except OSError:
                    pass
            print(json.dumps(dict(event="fault", error=self.error)), file=sys.stderr, flush=True)
            raise
        finally:
            if self.runtime and not self.runtime.blocked:
                try:
                    self.runtime.quiesce()
                    if not self.error:
                        self.overlay_state(IDLE)
                except BaseException as error:
                    print("Shutdown retains hardware ownership: " + str(error), file=sys.stderr)
            if self.bridge:
                self.bridge.close()
            if self.server:
                self.server.close()
            if self.socket_bound:
                Path(self.config["socket"]).unlink(missing_ok=True)
            if self.hw:
                self.hw.close()


def client(path, request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(10)
        connection.connect(path)
        connection.sendall((json.dumps(request) + "\n").encode())
        data = bytearray()
        while not data.endswith(b"\n"):
            block = connection.recv(4096)
            require(bool(block), "incomplete daemon response")
            data.extend(block)
            require(len(data) <= 1024 * 1024, "oversized daemon response")
    response = json.loads(data)
    print(json.dumps(response, ensure_ascii=False, indent=2))
    return 0 if response.get("ok") else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="/etc/npu100/camera.json")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("serve", "status", "start", "stop"):
        commands.add_parser(name)
    commands.add_parser("select").add_argument("model", type=int, choices=NAMES)
    display = commands.add_parser("display")
    display.add_argument("--confidence", type=float)
    display.add_argument("--minimum-box-pixels", type=int)
    display.add_argument("--nms", type=float)
    commands.add_parser("view").add_argument("mode", choices=("matched", "live"))
    args = parser.parse_args()
    config = load_config(args.config)
    if args.command == "serve":
        camera = Camera(config)
        def stop(signum, frame):
            camera.stopping = True
            camera.requested_run = False
        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGTERM, stop)
        camera.run()
        return 0
    request = dict(operation=args.command)
    if args.command == "select":
        request["model"] = args.model
    elif args.command == "display":
        request["display"] = {key: value for key, value in vars(args).items()
                              if key in ("confidence", "minimum_box_pixels", "nms") and value is not None}
    elif args.command == "view":
        request["matched"] = args.mode == "matched"
    return client(config["socket"], request)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, OSError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
