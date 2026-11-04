#!/usr/bin/env python3
"""Stage and verify three frozen SD models, then leave NPU admission stopped.

Run only after the package shell has checked the boot identity and live DT.
Uses the unchanged production Runtime; never switches a model or starts a task.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_once(bundle, device, *, check_bundle, hardware_type, runtime_type):
    """Dependency arguments permit host fixtures without any device operations."""
    bundle = Path(bundle).resolve()
    # Complete SD image and frozen-input verification precedes opening hardware.
    files = check_bundle(bundle)
    require(files.get("integrity") == "PASS" and sorted(files.get("models", [])) == [1, 3, 4],
            "preflight must validate all three frozen models")
    hardware = None
    runtime = None
    operation_error = None
    receipt = None
    try:
        hardware = hardware_type(device)
        # Constructor performs matched frontend/graph/build/capability checks
        # through READ only, before preload can stage any model bytes.
        runtime = runtime_type(hardware, bundle)
        status = runtime.preload()
        require(runtime.resident == {1, 3, 4}, "preload did not verify all three DDR images")
        require(runtime.active == 0 and runtime.task is None and runtime.lease is None
                and not runtime.blocked, "preload left unexpected active/owned work")
        require(status.get("active_model") == 0 and status.get("resident_models") == [1, 3, 4],
                "production preload status disagrees with resident state")
        models = []
        for model_id in (1, 3, 4):
            model = runtime.models[model_id]
            # Runtime.preload adds a resident ID only after actual DDR readback
            # SHA256 AND CRC checks. These are its verified expected identities;
            # do not manufacture a second readback hash from the source files.
            models.append({
                "id": model_id, "name": model["name"], "file": model["file"],
                "address": model["model_base"], "address_hex": "0x%08x" % model["model_base"],
                "bytes": model["image_bytes"], "sha256": model["image_sha256"],
                "crc32": model["image_crc"], "crc32_hex": "0x%08x" % model["image_crc"],
                "ddr_readback": "PASS",
                "verification": "production_Runtime.preload_DDR_SHA256_and_CRC32",
            })
        receipt = {
            "scope": "SD_TO_RESERVED_DDR_MODEL_STAGING_NO_INFERENCE",
            "result": "MODEL_PRELOAD_PASS", "bundle": str(bundle),
            "active_model": 0, "resident_models": [1, 3, 4], "models": models,
            "sd_preflight": files,
            "inference_started": False, "model_switch_called": False,
            "camera_start_requested": False, "keys_read": False,
        }
    except BaseException as error:
        operation_error = error
        raise
    finally:
        cleanup_error = None
        if runtime is not None and not runtime.blocked and runtime.task is None and runtime.lease is None:
            try:
                runtime.quiesce()
            except BaseException as error:
                cleanup_error = error
        if hardware is not None:
            try:
                hardware.close()
            except BaseException as error:
                if cleanup_error is None:
                    cleanup_error = error
        if cleanup_error is not None:
            if operation_error is None:
                raise RuntimeError("Model loader cleanup failed; no success receipt: " + str(cleanup_error)) from cleanup_error
            print("MODEL_PRELOAD_CLEANUP_ERROR: " + str(cleanup_error), file=sys.stderr)
    # No success output is emitted until quiesce and device close succeeded.
    require(receipt is not None, "model loader produced no completion receipt")
    receipt["admission_stopped"] = True
    receipt["device_closed"] = True
    return receipt


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=Path("/home/petalinux/npu100_models"))
    parser.add_argument("--device", default="/dev/unified-npu")
    parser.add_argument("--load-models", action="store_true", required=True,
                        help="explicitly stage model bytes into the reserved DDR slots")
    parser.add_argument("--boot-contract-checked", action="store_true", required=True,
                        help="caller has checked matching boot files, live DT, PL readiness and loaded driver")
    args = parser.parse_args(argv)
    require(args.bundle.is_absolute() and Path(args.device).is_absolute(), "bundle and device paths must be absolute")
    runtime_dir = Path(__file__).resolve().parent / "runtime"
    require(runtime_dir.is_dir(), "package runtime directory missing")
    sys.path.insert(0, str(runtime_dir))
    from preflight import check_bundle
    from npu_runtime import Hardware, Runtime
    receipt = load_once(args.bundle, args.device, check_bundle=check_bundle,
                        hardware_type=Hardware, runtime_type=Runtime)
    print(json.dumps(receipt, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print("MODEL_PRELOAD_FAIL: " + str(error), file=sys.stderr)
        raise SystemExit(1)
