# npu100 Linux 6.12 source integration

This directory targets **npu100/project/npu100.xpr** and Linux **6.12**. Sources
were adapted locally from the historical runtime; the historical project is
unchanged. Delivery is source and static checks only: no kernel/module, DTB,
userspace executable, boot image, bitstream, SD write, Ethernet deployment or
board inference has been built or performed by this change.

The OSD `NPU ... MS` selects its time source from graph `DIA` CSR `0xFC`, bit2.
With that bit set, it uses the latched PL task cycles and hardware clock rate.
With counters disabled, it uses monotonic host time from submission to the owned
DONE descriptor, before result copying/hashing, ACK, postprocessing or display.
This host measurement includes ioctl/polling/scheduling latency; it is not an
exact count of PL busy cycles. JSON receipts identify `timing_source` and
`hardware_cycles_valid`; disabled raw `cycles` stay zero, not fabricated.
The OSD is integer milliseconds. FPS remains the successful-publication rate.
This software timing fallback does not enable PL diagnostic counters or change
the bitstream/XSA contract. Build the updated driver too: its read-only CSR
allowlist now includes the graph DIA feature word.

## Required boot contract

The bootloader must load the matching PL and initialize PS DDR/FCLK0/FCLK1 and
fabric resets before Linux accesses any PL MMIO. A software timeout cannot
recover a read from an absent AXI slave. Do not reprogram the FPGA, apply/remove
its overlay, unbind its driver, or change FCLK rates while this runtime is open.
The driver does not program PL and has no background reload operation. Probe
maps resources without PL reads; the first MMIO operation verifies the hardware.

The current BD configures 1 GiB DDR and both FCLK0/FCLK1 at 100 MHz. The kernel
driver acquires both clocks, checks those rates and holds enable references;
`clk_ignore_unused` is not its clock-ownership mechanism. No PL interrupt is
connected in this design. Operations use polling, including cancellable graph
completion and stable frame leases.

Before the camera service, provide `npu100-fpga-check.service` for the board's
boot process. It must verify the installed boot/XSA/PL identity and readiness
without reloading live fabric. The supplied camera service requires and starts
after it. A hardware ABI read is meaningful only after PL is known ready.

## Device tree and memory

Merge `dts/unified-npu-reserved.dtsi` into the **base DT before boot**. It reserves
`[0x10000000,0x20000000)` with `no-map`, preventing Linux from allocating or
creating a cached linear alias of shared DDR. A live overlay cannot safely
reserve memory Linux already used. `unified-npu-runtime.dtso` is an optional
boot-time device overlay and assumes that base reservation already exists.
Use either the complete include or the device overlay, never duplicate nodes.

DT resources are frontend `0x43c10000/0x8000`, graph `0x43c18000/0x8000`,
control AXI GPIO `0x41200000/0x10000`, stats AXI GPIO `0x41210000/0x10000`.
The custom driver owns all four. Disable generated AXI GPIO/CSR nodes at the
same addresses; source comments show the expected `&control_gpio` and
`&stats_gpio` overrides, whose actual labels must be matched to generated
`pl.dtsi`. `request_mem_region` refuses overlapping live owners. PS MIO keys
use kernel GPIO descriptors: `resnet-gpios=<&gpio0 12 1>` and
`neu-gpios=<&gpio0 11 1>` (`1` is GPIO_ACTIVE_LOW). Match `gpio0` and `clkc`
labels to the actual base DT. The exported XSA/PS pinmux must leave MIO12/11 as
GPIO. No raw PS GPIO/SLCR writes are used. PL keys are read through KEY1 CSRs.

HP0 scanout, HP2 capture and HP1 NPU DDR accesses are noncoherent. Do not add
`dma-coherent`. DDR mmap uses Normal noncache/write-combine attributes; CPU/PL
ownership handoffs use `dma_wmb/dma_rmb` and CSR readback. A barrier does not
clean a cached alias. Linux must not call standalone MMU/cache functions or
reuse its low-DDR diagnostics/mailbox addresses. Do not expose `/dev/mem`.

| Region index | mmap physical window | Purpose |
|---|---|---|
| 0, 1 | no mmap | frontend and graph CSR ioctls |
| 2 RAW | `0x12000000/0x02000000` | eight 4 MiB slots; each raw image 1,843,200 bytes |
| 3 MODELS | `0x14000000/0x06000000` | immutable ResNet at 0x14000000, NEU at 0x18000000 |
| 4 WORKSPACE | `0x1a000000/0x01000000` | shared workspace; actual maximum 0x7c0000 |
| 5 COCO | `0x1b000000/0x01000000` | immutable COCO80 image |
| 6, 7 | no mmap | control and stats GPIO ioctls |

No retired UI framebuffer or tensor alias is mapped. RAW is writable only
because the portable C bridge obtains an address using a writable buffer view;
the application treats raw pixels as immutable while any capture/PS/display
lease exists. Root/CAP_SYS_RAWIO is trusted: mmap writes cannot be intercepted
per byte by the kernel, so the sole daemon must enforce these ownership rules.

## ABI and ownership API

`driver/unified_npu_uapi.h` ABI=3 uses one 32-byte `<8I` structure:
`abi,region,offset,value,phys,size,flags,reserved`. `_IOWR('N',1..5)` operations
are INFO, READ, WRITE, FENCE and KEYS. mmap offset is `region*4096`, with the
exact declared region size. Registers are accessible only through aligned
whitelisted ioctls. KEYS returns pressed bits: 0 ResNet/MIO12, 1 NEU/MIO11,
2 COCO/PL L14, 3 start-stop/PL K16. Userland implements debounce.

One file owner is allowed, protected by a kernel mutex; inherited mappings
retain that file owner. Accepted graph task/frame/generation and raw lease
identity are tracked by the driver as well as `Runtime`. Release/cancel/result
clear require the caller's accepted identity. Closing a process with accepted
work does not cancel it or overwrite DDR: the driver records an orphan and
rejects subsequent mutation/mapping until explicit board recovery establishes a
fresh boot. Timeouts never authorize reuse. Threads embedding Runtime must use
one serialized caller; progress hooks may read keys/socket and update desired
state, but must not reenter submit/switch.

Both driver and Runtime require frontend PRP1/8, CAM2, LIV1, **OVL3**, build
`0x26110104`, caps `0x00080307`, graph NGP1/extension2, wire mask `0xA` and a
valid clock CSR. Caps encode 8 slots, 3 logical models, metadata, live status
and strict matched geometry. Logical models are 1 ResNet, 3 NEU6, 4 COCO80;
logical 4 uses unchanged package/plan wire family 3. Generation/base identify
the selected weights. Three models do not imply a new graph wire mask bit4.

Result metadata: `0x190` captured-frame delay BCD5, `0x194` logical model,
`0x198` graph milliseconds BCD5, `0x19c` completed-result FPS x100 BCD4,
`0x1a0` status 0 idle/1 run/2 load/3 error; `0x1a4` build and `0x1a8` caps are
read-only. Runtime publishes metadata with matching frame/generation/boxes.

## Three model SD bundle

`manifest.py` pins model addresses, bytes, CRC, SHA256, shapes and tensor/plan
offsets to the current local app catalog. It validates AIPKG3 section checksums,
NPUPLN1 graph control, record spans, tensor contracts and logical/wire identity.
`pack_sd.py` consumes **existing** artifact folders, never trains/quantizes or
changes frozen files. All three inputs must be present; no fallback dataset or
alternate shape is substituted. Stage to a new ordinary host directory:

```sh
python3 pack_sd.py --model1 /path/resnet18_unified_160 \
  --model3 /path/yolox_s_a_256 --model4 /path/yolox_s_coco80_256 \
  --output /path/new_npu_bundle
```

Each input folder needs `ddr.bin` and `input.bin`; optional provenance manifests
are copied and, when present, input manifests are verified. JSON schema2 carries
all three records. Paths are `models/m1/model.bin`, `models/m3/model.bin` and
`coco80/model.bin`. The separate `manifest.bin` retains standalone's two-record
NPUSDM1 format and COCO remains its separate file. Linux requires ALL THREE;
unlike the old optional standalone COCO path, absence is a startup failure.

At every service start Runtime preflights all SD files before DDR writes, stops
graph admission, drains only its accepted jobs/PS lease, copies all three files
to their fixed slots and verifies CRC/SHA over real DDR readback. Only then can
switch/submit enable inference. Live camera display has independent immutable
raw references and remains available during model loading/switching.

## Build and application integration

Use the board's exact configured Linux **6.12** kernel tree and matching
toolchain. No generic kernel headers substitute for that build. Future build
commands, deliberately not executed as part of source delivery:

```sh
make -C driver KDIR=/path/to/matching/kernel ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
make app CROSS_COMPILE=arm-linux-gnueabihf-
make install DESTDIR=/path/to/staging-root PREFIX=/opt/npu100
```

The install target requires already built `app/libnpu_camera.so`. The root app
`linux_camera.py --config /etc/npu100/camera.json serve` embeds Runtime, the local
C math/detector bridge, physical keys and local socket control. Do not also run
the prepared-tensor `npu_runtime.py daemon`; driver exclusivity rejects it.
`Runtime.progress_hook` and `cancel_requested` keep cooperative controls active
during graph polling. Accepted jobs drain before switching or stopping.

Systemd installs no automatic FPGA programming. The service runs one camera
owner, reads `/home/petalinux/npu100_models`, and uses `/run/npu100`. Review the
board-specific `npu100-fpga-check.service`, base DT labels, boot image identity
and config before later deployment. Ethernet transfer/deployment is an explicit
future operator action; copy versioned staging outputs and verify hashes at
destination before enabling the service. See the adjacent deployment/preflight
sources supplied by the main integration for the complete board workflow.

Linux primary API references used: kernel v6.12 `include/linux/platform_device.h`
(`void .remove`), `include/linux/clk.h` (bulk clock ownership), DMA API HOWTO,
and Devicetree reserved-memory binding. This source adapts those APIs but does
not claim module compilation, DT compilation or board compatibility proof.
