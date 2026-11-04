#!/usr/bin/env python3
"""Single-owner Linux SD->DDR runtime and local CLI. No /dev/mem access.

The daemon loads all three immutable packages at every start, then switches resident
descriptors and the shared workspace after all graph/frame/display users drain.
`run` actually submits an NPUPLN1 graph with a prepared tensor, reads its result,
and records task/frame/generation/cycles. This is not a Linux camera driver.
"""
from __future__ import annotations
import argparse
from dataclasses import dataclass
import fcntl
import json
import mmap
import os
from pathlib import Path
import signal
import socket
import struct
import sys
import time
import threading
from manifest import (WORKSPACE_BASE, check_image, check_manifest, child_file,
                      crc, parse_json, require, sha, wire_id)

FRONTEND, GRAPH, RAW, MODELS, WORKSPACE, COCO, CONTROL, STATS = range(8)
DDR_REGIONS = (RAW, MODELS, WORKSPACE, COCO)
WINDOWS = ((0x43C10000, 0x8000), (0x43C18000, 0x8000),
           (0x12000000, 0x02000000), (0x14000000, 0x06000000),
           (WORKSPACE_BASE, 0x01000000), (0x1B000000, 0x01000000),
           (0x41200000, 0x10000), (0x41210000, 0x10000))
IOC = lambda number: (3 << 30) | (32 << 16) | (ord("N") << 8) | number
STOPPING = False


def packed_bcd(value, digits):
    value = max(0, min(int(value), 10**digits-1))
    result = 0
    for i in range(digits):
        result |= (value % 10) << (4*i)
        value //= 10
    return result


def valid_bcd(value, digits):
    return type(value) is int and 0 <= value < (1 << (4*digits)) and all(
        ((value >> (4*i)) & 15) <= 9 for i in range(digits))


class Hardware:
    """The char driver exposes exact DDR windows and 32-bit CSR ioctls only."""
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR | os.O_CLOEXEC | os.O_SYNC)
        self.maps = {}
        self.lock = threading.RLock()
        try:
            require(os.sysconf("SC_PAGE_SIZE") == 4096, "this Zynq template requires 4 KiB pages")
            for region, expected in enumerate(WINDOWS):
                result = self.ioctl(1, region)
                require(tuple(result[4:6]) == expected and result[6] == (1 if region in DDR_REGIONS else 0), "driver map ABI")
        except BaseException:
            self.close()
            raise

    def ioctl(self, command, region=0, offset=0, value=0):
        data = bytearray(struct.pack("<8I", 3, region, offset, value, 0, 0, 0, 0))
        with self.lock:
            fcntl.ioctl(self.fd, IOC(command), data, True)
        return struct.unpack("<8I", data)

    def read(self, region, offset):
        return self.ioctl(2, region, offset)[3]

    def write(self, region, offset, value):
        self.ioctl(3, region, offset, value)

    def fence(self):
        self.ioctl(4)

    def key_state(self):
        """Pressed mask: bit0 ResNet, bit1 NEU6, bit2 COCO, bit3 run/stop."""
        return self.ioctl(5)[3]

    def mapping(self, region):
        require(region in DDR_REGIONS, "register mmap is not supported")
        if region not in self.maps:
            self.maps[region] = mmap.mmap(self.fd, WINDOWS[region][1], flags=mmap.MAP_SHARED,
                                         prot=mmap.PROT_READ | mmap.PROT_WRITE, offset=region * 4096)
        return self.maps[region]

    def close(self):
        for mapping in self.maps.values():
            mapping.close()
        self.maps.clear()
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1


@dataclass
class OwnedTask:
    model: int
    task: int
    frame: int
    generation: int


class Runtime:
    """Importable single-owner interface for a future Linux camera application.

    Never use concurrently with the bare-metal application or another master.
    Public operations are serialized by the daemon; callers embedding this class
    must provide the same single-threaded ownership. No method resets hardware.
    """
    def __init__(self, hardware, root):
        self.hw = hardware
        self.root = Path(root).resolve()
        raw_manifest = (self.root / "manifest.json").read_bytes()
        receipt = (self.root / "manifest.sha256").read_text("ascii").split()
        require(len(receipt) == 2 and receipt[1] == "manifest.json" and
                receipt[0] == sha(raw_manifest), "manifest integrity receipt")
        self.manifest = parse_json(raw_manifest)
        self.models = {m["id"]: m for m in check_manifest(self.manifest)}
        self.active, self.generation, self.frame = 0, 0, 0
        self.task = None
        self.lease = None
        self.resident = set()
        self.blocked = False
        self.last_result = None
        self.progress_hook = None
        self.cancel_requested = lambda: False
        self.last_completion = None
        self.result_fps_bcd = 0
        self.discarded_graph_fault = 0
        self.check_abi()

    def gr(self, off): return self.hw.read(GRAPH, off)
    def gw(self, off, value): self.hw.write(GRAPH, off, value)
    def fr(self, off): return self.hw.read(FRONTEND, off)
    def fw(self, off, value): self.hw.write(FRONTEND, off, value)

    def check_abi(self):
        abi = self.manifest["abi"]
        require(self.fr(0) == abi["frontend_magic"] and self.fr(0x5C) == abi["frontend"] and
                self.fr(0x88) == abi["camera_feature"] and self.fr(0x94) == abi["live_feature"] and
                self.fr(0xAC) == abi["overlay_feature"] and self.fr(0x1A4) == abi["build_id"] and
                self.fr(0x1A8) == abi["caps"], "frontend ABI8/CAM2/LIV1/OVL3/build mismatch")
        require(self.gr(0) == abi["graph_magic"] and self.gr(0x88) == abi["graph_extension"], "graph ABI mismatch")
        require(self.gr(0xDC) == sum(1 << model for model in {wire_id(m) for m in self.models.values()}),
                "wire model mask mismatch; logical model4 must map to wire3")
        self.clock_hz = self.gr(0xD8)
        require(self.clock_hz == 100000000, "npu100 requires matching 100 MHz NPU clock CSR")
        for model in self.models.values():
            features = model["required_features"]
            hardware_features = self.gr(0xD4) if self.gr(0xD0) == 0x4F505431 else 0
            require(bool(features & 2) == bool(hardware_features & 2),
                    "PS-predecoded hardware mode and bundle plan mode differ")
            if features:
                require(self.gr(0xD0) == 0x4F505431 and self.gr(0xD4) & features == features,
                        "plan requires matching OPT1 SiLU/predecoded-control bitstream")

    def wait(self, predicate, seconds, why):
        deadline = time.monotonic() + seconds
        while not predicate():
            if time.monotonic() >= deadline:
                raise TimeoutError(why)
            # Hooks pump controls only; draining accepted work never exits
            # early merely because stop/switch was requested again.
            if self.progress_hook: self.progress_hook()
            time.sleep(0.001)

    def quiet_graph(self):
        return not (self.gr(0x0C) & 0xB or self.gr(0x04) & 0xB or self.gr(0x78))

    def acknowledge_result(self):
        self.gw(0x04, 4)
        self.wait(self.quiet_graph, 5, "owned result did not retire")

    def owned_done(self, cancelling=False):
        if self.task is None:
            return False
        status = self.gr(0x0C)
        if status & 1 or not status & 2 or self.gr(0x04) & 1 or not self.gr(0x78):
            return False
        t = self.task
        require((self.gr(0x38), self.gr(0x40), self.gr(0x44)) ==
                (t.task, t.frame, t.generation), "foreign or mismatched terminal result; ownership retained")
        fault = self.gr(0x30)
        # A requested discard can terminate as task cancel 0x0301, sequencer
        # cancel 0x0405, or backend 0x0406 (detail not exposed by this ABI).
        # Record exact terminal fault without labelling backend faults benign.
        # Only matched, drained owned terminals are consumed; no output is used.
        if cancelling:
            self.discarded_graph_fault = fault
        if fault and not cancelling:
            # The terminal result is ours and already drained; record failure
            # then consume it. No automatic restart of the failed inference.
            self.acknowledge_result()
            self.task = None
            raise RuntimeError(f"graph fault 0x{fault:04x}")
        if not cancelling:
            require(self.gr(0x34) == t.model, "terminal model ID mismatch; ownership retained")
        return True

    def cancel_owned(self):
        if self.task is None:
            return
        if self.gr(0x0C) & 1 or self.gr(4) & 1:
            self.gw(4, 2)
        try:
            self.wait(lambda: self.owned_done(True), 60, "cancel timed out: graph/workspace/lease remain owned")
            self.acknowledge_result()
            self.task = None
        except BaseException:
            self.blocked = True
            raise

    def quiesce(self):
        require(not self.blocked, "runtime fault retains ownership; no DDR reuse permitted")
        # Global capture and live preview remain independent. Clear geometry,
        # stop processed acceptance, and drain only this PS owner's lease/job.
        self.fw(0x1A0, 0)
        self.fw(4, (self.fr(4) | 0x18) & ~4)
        if self.task is not None:
            self.cancel_owned()
        require(self.quiet_graph(), "foreign graph task/result/pending request; refusing to consume it")
        if self.lease is not None:
            self.release_frame()
        require(not self.fr(0x40), "foreign accepted frame lease; refusing to discard it")
        require(not self.fr(0x1C) and not self.fr(0x84), "frontend/scanout fault: memory remains held")
        self.wait(lambda: not self.fr(0x8C) & 4, 60, "PS frame lease did not retire")
        self.fw(0x90, 16)  # Clear overlay; preserve immutable live display refs.
        self.gw(8, 0)
        self.wait(lambda: self.gr(8) & 0x1F == 4, 5, "PS admission did not stop")
        self.hw.fence()

    def image_in_ddr(self, m):
        self.hw.fence()
        region = COCO if m["id"] == 4 else MODELS
        offset = m["model_base"] - WINDOWS[region][0]
        return self.hw.mapping(region)[offset:offset+m["image_bytes"]]

    def preload(self):
        # Preflight ALL immutable SD files before the first DDR write.
        images = {}
        for model in self.models.values():
            blob = child_file(self.root, model["file"]).read_bytes()
            check_image(blob, model)
            images[model["id"]] = blob
        self.quiesce()
        self.fw(0x1A0, 2)
        self.active = 0
        self.resident.clear()
        loaded = set()
        for model in self.models.values():
            # Every service start copies all three SD images and verifies real
            # DDR bytes. No resident-mask or previous receipt skips staging.
            blob = images[model["id"]]
            require(self.quiet_graph() and not self.fr(0x40), "hardware changed during preload")
            region = COCO if model["id"] == 4 else MODELS
            offset = model["model_base"] - WINDOWS[region][0]
            self.hw.mapping(region)[offset:offset+len(blob)] = blob
            self.hw.fence()
            current = self.image_in_ddr(model)
            require(sha(current) == model["image_sha256"] and crc(current) == model["image_crc"], "DDR readback integrity failure")
            loaded.add(model["id"])
        self.resident = loaded
        require(loaded == {1, 3, 4}, "all three models must be resident")
        self.fw(0x1A0, 0)
        return self.status()

    def switch(self, model_id):
        require(type(model_id) is int and model_id in (0, 1, 3, 4), "model ID must be 0, 1, 3 or 4")
        if model_id:
            require(model_id in self.resident, "model not resident")
        self.quiesce()
        self.active = 0
        if not model_id:
            return self.status()
        model = self.models[model_id]
        current = self.image_in_ddr(model)
        require(sha(current) == model["image_sha256"] and crc(current) == model["image_crc"], "resident DDR image changed")
        self.gw(4, 8)  # Invalidate package/cache only after the prior job drained.
        self.wait(lambda: not self.gr(4) & 8, 5, "package invalidation timed out")
        generation = (self.gr(0x2C) + 1) & 0xFFFFFFFF
        self.generation = generation or 1
        config = {0x10: model["model_base"], 0x14: model["image_bytes"],
                  0x18: WORKSPACE_BASE, 0x1C: model["workspace_bytes"],
                  0x20: model["model_base"] + model["plan_offset"], 0x24: model["plan_bytes"],
                  0x28: 0, 0x2C: self.generation,
                  0x60: WORKSPACE_BASE + model["output_offset"], 0x64: model["output_bytes"],
                  0x68: model["output_dtype"], 0x7C: WORKSPACE_BASE + model["input_offset"],
                  0x80: model["input_bytes"]}
        for offset, value in config.items(): self.gw(offset, value)
        require(all(self.gr(offset) == value for offset, value in config.items()), "graph configuration readback mismatch")
        self.gw(8, 1)  # Current raw PS-managed ABI: 1 admits manual graph jobs.
        self.wait(lambda: self.gr(8) & 7 == 7, 5, "PS graph admission did not enable")
        self.active = model_id
        self.last_completion = None
        self.result_fps_bcd = 0
        self.fw(0x1A0, 1)
        return self.status()

    def claim_frame(self, timeout=5):
        """Camera integration: returns a stable raw lease, never a stale pointer.
        The embedding app prepares workspace input, calls submit(), waits for
        completion, postprocesses, then publish_frame() or release_frame().
        Keep this sole Runtime instance alive for the entire ownership period.
        """
        require(self.active and self.task is None and self.lease is None and not self.blocked, "camera claim ownership")
        require(not self.fr(0x40), "foreign frame lease")
        self.fw(4, (self.fr(4) | 0x19) & ~4)  # Preserve configured matched-view bit.
        deadline = time.monotonic() + timeout
        while True:
            self.fw(8, 1)
            if self.fr(0x40):
                lease = {"address": self.fr(0x44), "bytes": self.fr(0x58),
                         "frame": self.fr(0x48), "generation": self.fr(0x4C),
                         "raw_address": self.fr(0x60),
                         "captured_cycles": self.fr(0x50) | self.fr(0x54) << 32}
                self.lease = lease  # Retain even if validation below fails.
                require(lease["address"] == lease["raw_address"] and lease["bytes"] == 1280*720*2 and
                        0x12000000 <= lease["address"] <= 0x13C00000 and
                        (lease["address"] - 0x12000000) % 0x400000 == 0, "raw lease extent")
                self.hw.fence()
                return dict(lease)
            if time.monotonic() >= deadline: raise TimeoutError("no camera snapshot")
            if self.progress_hook: self.progress_hook()
            if STOPPING or self.cancel_requested(): raise TimeoutError("camera claim cancelled before acceptance")
            time.sleep(0.002)

    def release_frame(self):
        require(self.task is None and self.lease is not None, "graph must drain before frame release")
        lease = self.lease
        require(self.fr(0x40) and (self.fr(0x48), self.fr(0x4C)) ==
                (lease["frame"], lease["generation"]), "frame release identity mismatch")
        self.hw.fence()
        self.fw(0x10, lease["frame"]); self.fw(0x14, lease["generation"]); self.fw(0x0C, 1)
        require(not self.fr(0x40), "frame release rejected; ownership retained")
        self.lease = None

    def publish_frame(self, classification, score, boxes=(), detection=False, *,
                      model_id=None, inference_ms_bcd=None, result_fps_bcd=None,
                      capture_delay_bcd=None):
        require(self.task is None and self.lease is not None, "graph must drain before publish")
        require(len(boxes) <= 8 and 0 <= classification <= 7 and (0 <= score <= 100 or score == 127), "result metadata")
        encoded = []
        for box in boxes:
            x0, y0, x1, y1, cls, confidence = box
            require(0 <= x0 < x1 <= 1280 and 0 <= y0 < y1 <= 720 and
                    0 <= cls <= 7 and (0 <= confidence <= 100 or confidence == 127), "display box bounds")
            encoded.append((x0 | y0 << 16, x1 | y1 << 16, cls | confidence << 8))
        lease = self.lease
        require(self.fr(0x40) and (self.fr(0x48), self.fr(0x4C)) ==
                (lease["frame"], lease["generation"]), "publish lease identity")
        self.fw(0x180, lease["frame"]); self.fw(0x184, lease["generation"])
        self.fw(0x188, classification | score << 8)
        self.fw(0x18C, len(boxes) | (16 if detection else 0))
        logical = self.active if model_id is None else model_id
        require(logical in (1, 3, 4) and logical == self.active, "published logical model")
        if inference_ms_bcd is None and self.last_result:
            inference_ms_bcd = packed_bcd(round(self.last_result["graph_seconds"]*1000), 5)
        if inference_ms_bcd is None: inference_ms_bcd = 0
        if result_fps_bcd is None: result_fps_bcd = self.result_fps_bcd
        if capture_delay_bcd is None:
            hi, lo, check = self.fr(0xB4), self.fr(0xB0), self.fr(0xB4)
            while hi != check:
                hi, lo, check = check, self.fr(0xB0), self.fr(0xB4)
            elapsed = ((hi << 32) | lo) - lease["captured_cycles"]
            capture_delay_bcd = packed_bcd(max(0, elapsed)//100000, 5)
        for value, digits in ((inference_ms_bcd, 5), (result_fps_bcd, 4), (capture_delay_bcd, 5)):
            require(valid_bcd(value, digits), "packed BCD metadata")
        self.fw(0x194, logical); self.fw(0x198, inference_ms_bcd)
        self.fw(0x19C, result_fps_bcd); self.fw(0x190, capture_delay_bcd)
        self.fw(0x1A0, 1)
        for i, words in enumerate(encoded):
            for word, value in enumerate(words): self.fw(0x200+i*16+word*4, value)
        self.hw.fence(); self.fw(0x120, 1)
        require(not self.fr(0x40), "publish rejected; ownership retained")
        self.lease = None
        self.fw(4, self.fr(4) | 4)

    def submit(self, timeout=900):
        """Submit the already prepared active input and return (bytes, receipt)."""
        require(self.active and self.task is None and not self.blocked, "no active model or task ownership conflict")
        require(self.quiet_graph() and self.gr(8) & 7 == 7, "graph is not ready for owned submission")
        model = self.models[self.active]
        diagnostic_features = self.gr(0xFC)
        hardware_cycles_valid = (diagnostic_features & 0xFFFFFF00) == 0x44494100 and bool(diagnostic_features & 4)
        self.frame = self.lease["frame"] if self.lease else (self.frame+1) & 0xFFFFFFFF
        self.gw(0x28, self.frame)
        self.task = OwnedTask(wire_id(model), (self.gr(0x50)+1) & 0xFFFFFFFF, self.frame, self.generation)
        owned = self.task
        start = time.monotonic()
        self.hw.fence(); self.gw(4, 1)
        try:
            while not self.owned_done():
                if self.progress_hook: self.progress_hook()
                if STOPPING or self.cancel_requested() or time.monotonic()-start >= timeout:
                    self.cancel_owned()
                    raise TimeoutError("owned inference cancelled and drained; no output returned")
                time.sleep(0.001)
            # Stop the host timer at our own completed descriptor, before
            # copying/hashing output, ACK, postprocessing or publication.
            completed_at = time.monotonic()
            require((self.gr(0x6C), self.gr(0x70), self.gr(0x74)) ==
                    (WORKSPACE_BASE+model["output_offset"], model["output_bytes"], model["output_dtype"]), "result address/length/dtype")
            cycles = (self.gr(0x48) | self.gr(0x4C) << 32) if hardware_cycles_valid else 0
            graph_elapsed_seconds = completed_at - start
            graph_seconds = cycles/self.clock_hz if hardware_cycles_valid else graph_elapsed_seconds
            self.hw.fence()
            off = model["output_offset"]
            result = self.hw.mapping(WORKSPACE)[off:off+model["output_bytes"]]
            receipt = dict(model=self.active, task=owned.task, frame=owned.frame, generation=owned.generation,
                           model_sha256=model["image_sha256"], result_sha256=sha(result), bytes=len(result),
                           cycles=cycles, elapsed_seconds=time.monotonic()-start,
                           graph_seconds=graph_seconds, clock_hz=self.clock_hz,
                           graph_elapsed_seconds=graph_elapsed_seconds,
                           hardware_cycles_valid=hardware_cycles_valid,
                           timing_source="hardware_cycles" if hardware_cycles_valid else "host_monotonic")
            self.acknowledge_result()
            self.task = None
            self.last_result = receipt
            completed = time.monotonic()
            self.result_fps_bcd = packed_bcd(round(100/max(1e-9, completed-self.last_completion)), 4) if self.last_completion else 0
            self.last_completion = completed
            return result, receipt
        except BaseException:
            # Identity/descriptor faults retain state. No foreign-result clear,
            # reset, lease release or speculative shared-workspace overwrite.
            if self.task is not None:
                self.blocked = True
            raise

    def run(self, model_id, input_path=None, output_path=None, timeout=900):
        require(0 < timeout <= 86400, "run timeout must be 0..86400 seconds")
        require(model_id in self.models, "run model ID")
        path = Path(output_path).absolute() if output_path else None
        if path is not None:
            require(path.parent.is_dir(), "output directory must exist")
            require(not path.resolve().is_relative_to(self.root) and
                    not Path(str(path)+".json").resolve().is_relative_to(self.root),
                    "output/receipt must be outside the immutable SD bundle")
        model = self.models[model_id]
        frozen = input_path is None
        inp = (child_file(self.root, model["golden_input"]) if frozen else Path(input_path)).read_bytes()
        require(len(inp) == model["input_bytes"], "prepared input tensor length")
        if frozen: require(sha(inp) == model["input_sha256"], "frozen input identity")
        self.switch(model_id)
        offset = model["input_offset"]
        self.hw.mapping(WORKSPACE)[offset:offset+len(inp)] = inp
        self.hw.fence()
        result, receipt = self.submit(timeout)
        receipt["input_sha256"] = sha(inp)
        if path is not None:
            temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
            with temporary.open("xb") as out:
                out.write(result); out.flush(); os.fsync(out.fileno())
            os.replace(temporary, path)
            receipt["output"] = str(path)
            receipt_path = Path(str(path)+".json")
            receipt_temp = receipt_path.with_name(receipt_path.name + f".tmp.{os.getpid()}")
            with receipt_temp.open("x", encoding="utf-8") as out:
                out.write(json.dumps(receipt, indent=2)+"\n"); out.flush(); os.fsync(out.fileno())
            os.replace(receipt_temp, receipt_path)
        return receipt

    def status(self):
        return dict(active_model=self.active, generation=self.generation, clock_hz=self.clock_hz,
                    resident_models=sorted(self.resident), blocked=self.blocked,
                    own_task=vars(self.task) if self.task else None, own_lease=self.lease,
                    graph_status=self.gr(0x0C), graph_control=self.gr(4), graph_mode=self.gr(8),
                    frontend_drain=self.fr(0x8C), frontend_fault=self.fr(0x1C),
                    display_fault=self.fr(0x84), discarded_graph_fault=self.discarded_graph_fault,
                    last_result=self.last_result)


def receive_json(connection):
    data = bytearray()
    while b"\n" not in data:
        block = connection.recv(4096)
        if not block: raise ValueError("incomplete request")
        data.extend(block)
        require(len(data) <= 65536, "request exceeds 64 KiB")
    require(data.endswith(b"\n") and data.count(b"\n") == 1, "one JSON request per connection")
    return json.loads(data)


def serve(args):
    global STOPPING
    def request_stop(signum, frame):
        global STOPPING
        STOPPING = True
    signal.signal(signal.SIGTERM, request_stop); signal.signal(signal.SIGINT, request_stop)
    hardware = Hardware(args.device)
    runtime = None
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    bound = False
    try:
        runtime = Runtime(hardware, args.root)
        runtime.preload()
        path = Path(args.socket)
        require(path.parent.is_dir() and not path.exists(), "socket parent missing or socket already exists")
        server.bind(str(path)); bound = True; os.chmod(path, 0o600)
        server.listen(8); server.settimeout(0.5)
        print(json.dumps({"ready": True, **runtime.status()}), flush=True)
        while not STOPPING:
            try: connection, _ = server.accept()
            except socket.timeout: continue
            with connection:
                connection.settimeout(5)
                try:
                    request = receive_json(connection)
                    operation = request["operation"]
                    if operation in ("status", "preload"):
                        # All three are resident for this service lifetime.
                        result = runtime.status()
                    elif operation == "switch": result = runtime.switch(request["model"])
                    elif operation == "run":
                        result = runtime.run(request["model"], request.get("input"), request.get("output"), request.get("timeout", 900))
                    else: raise ValueError("unsupported command")
                    response = {"ok": True, "result": result}
                except (ValueError, RuntimeError, TimeoutError, OSError, KeyError, TypeError) as error:
                    response = {"ok": False, "error": str(error), "state": runtime.status()}
                try: connection.sendall((json.dumps(response)+"\n").encode())
                except (BrokenPipeError, socket.timeout): pass
    finally:
        if runtime is not None and not runtime.blocked:
            try: runtime.quiesce()
            except BaseException as error:
                print(f"Shutdown retained hardware ownership: {error}", file=sys.stderr)
        server.close()
        if bound: Path(args.socket).unlink(missing_ok=True)
        hardware.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default="/run/unified-npu/control.sock")
    sub = parser.add_subparsers(dest="command", required=True)
    daemon = sub.add_parser("daemon")
    daemon.add_argument("--root", default="/media/models/npu")
    daemon.add_argument("--device", default="/dev/unified-npu")
    sub.add_parser("status"); sub.add_parser("preload")
    change = sub.add_parser("switch"); change.add_argument("model", type=int, choices=(0, 1, 3, 4))
    run = sub.add_parser("run"); run.add_argument("model", type=int, choices=(1, 3, 4))
    run.add_argument("--input", type=Path); run.add_argument("--output", type=Path, required=True)
    run.add_argument("--timeout", type=float, default=900)
    args = parser.parse_args()
    if args.command == "daemon":
        serve(args)
        return
    request = dict(operation=args.command)
    if hasattr(args, "model"): request["model"] = args.model
    if args.command == "run":
        request.update(input=str(args.input.absolute()) if args.input else None,
                       output=str(args.output.absolute()), timeout=args.timeout)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(getattr(args, "timeout", 900)+130)
        connection.connect(args.socket)
        connection.sendall((json.dumps(request)+"\n").encode())
        response = receive_json(connection)
    print(json.dumps(response, indent=2))
    if not response["ok"]: raise SystemExit(1)


if __name__ == "__main__":
    try: main()
    except (ValueError, RuntimeError, TimeoutError, OSError) as error:
        print(f"unified-npu: {error}", file=sys.stderr)
        raise SystemExit(1)
