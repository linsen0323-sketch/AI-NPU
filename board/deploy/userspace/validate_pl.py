#!/usr/bin/env python3
"""Validate PL through the deployed runtime's read-only constructor path.

The parent package checker must validate boot/kernel/live-DT contracts first.
The first driver READ verifies PL identity. No mmap, DDR write, reset, preload,
inference, GPIO-key ioctl or fence occurs here. Missing AXI targets cannot be
made safe by a userspace timeout; the boot readiness contract is a prerequisite.
"""
import argparse
import json
from pathlib import Path
import sys
from npu_runtime import Hardware, Runtime, FRONTEND, GRAPH, CONTROL, STATS

OBSERVATIONS = (("frontend_magic", FRONTEND, 0x000),
                ("frontend_version", FRONTEND, 0x05C),
                ("camera_feature", FRONTEND, 0x088),
                ("live_feature", FRONTEND, 0x094),
                ("overlay_feature", FRONTEND, 0x0AC),
                ("build_id", FRONTEND, 0x1A4),
                ("caps", FRONTEND, 0x1A8),
                ("keys_feature", FRONTEND, 0x340),
                ("graph_magic", GRAPH, 0),
                ("graph_extension", GRAPH, 0x88),
                ("graph_clock_hz", GRAPH, 0xD8),
                ("wire_model_mask", GRAPH, 0xDC),
                ("graph_opt_magic", GRAPH, 0xD0),
                ("graph_opt_features", GRAPH, 0xD4),
                ("graph_dia_features", GRAPH, 0xFC),
                ("graph_status", GRAPH, 0x0C),
                ("graph_control", GRAPH, 0x04),
                ("graph_mode", GRAPH, 0x08),
                ("graph_result_pending", GRAPH, 0x78),
                ("frontend_fault", FRONTEND, 0x1C),
                ("display_fault", FRONTEND, 0x84),
                ("camera_control", CONTROL, 0),
                ("camera_status", CONTROL, 8),
                ("sensor_frames", STATS, 0),
                ("complete_frames", STATS, 8))

def validate(bundle, device="/dev/unified-npu"):
    hardware = Hardware(device)
    try:
        # Constructor verifies manifest receipt/contracts, PL ABI and every
        # model's required features. It does not call preload/quiesce/switch.
        runtime = Runtime(hardware, bundle)
        values = {name:hardware.read(region, offset)
                  for name, region, offset in OBSERVATIONS}
        return {"scope":"READ_ONLY_INFO_AND_PL_CSR_READS_NO_DDR_MAPPING",
                "result":"PL_ABI_PASS", "registers":values,
                "required_features":{str(model):record["required_features"]
                                     for model, record in runtime.models.items()},
                "models_loaded":False, "inference_tested":False}
    finally:
        hardware.close()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path,
                        default=Path("/home/petalinux/npu100_models"))
    parser.add_argument("--boot-contract-checked", action="store_true",
                        help="Required: parent package/boot/kernel/DT checker passed")
    args = parser.parse_args()
    if not args.boot_contract_checked:
        parser.error("Run the parent contract checker first; --boot-contract-checked is required")
    print(json.dumps(validate(args.bundle), indent=2))

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print("PL_ABI_FAIL: " + str(error), file=sys.stderr)
        raise SystemExit(1)
