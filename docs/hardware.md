# 硬件设计与重建

## 工程身份

唯一设计来源是原工程 `npu100/project/npu100.xpr`，器件 `xc7z020clg400-2`，工具 Vivado 2025.2。发布包由 `build/scripts/vivado/create_project.tcl` 重建 **npu100.xpr**。未采用其他旧工程的 RTL、约束、BD 或硬件产物。源路径及逐文件 SHA256 见 `evidence/packaging/hardware_files.json`。

板上使用的导出文件原名为 `AI_NPU.xsa`，发布包改名为 `board/hardware/npu100.xsa`；文件内容未变。它与 Linux 部署源 XSA 字节一致，内嵌 bit 与 `board/hardware/npu100.bit` 字节一致。身份核对见 `evidence/hardware/artifact_identity.json`。历史实现 run 名保留在这份来源收据中；新构建使用 `impl_100mhz`，实际 FCLK0/FCLK1 均为 100 MHz。

## 文件布局

| 路径 | 用途 |
|---|---|
| `src/hardware/rtl/accelerator/` | 当前 XPR 引用的共享 NPU、图执行、算子、PE、缓存与流式访存 RTL |
| `src/hardware/rtl/video/` | 当前 XPR 引用的摄像头、预处理、DMA、扫描输出、OSD、时钟与板级顶层 |
| `src/hardware/constraints/navigator_720p.xdc` | 板级引脚、电气与时钟约束 |
| `src/hardware/constraints/camera_cdc_late.xdc` | 实现阶段 LATE CDC 约束；综合阶段禁用 |
| `src/hardware/block_design/create_video_system.tcl` | 从当前 npu100 只读导出的 BD，含 PS7、AXI、复位、视频与 NPU 接口 |
| `src/hardware/ip/` | 为未来自定义打包 IP 预留；本工程无额外自定义 IP 仓库 |
| `build/scripts/vivado/create_project.tcl` | 在干净目录建立 npu100 工程，生成 BD/IP 和 wrapper，不启动综合实现 |
| `build/scripts/vivado/build_bitstream.tcl` | 明确启动综合、实现、bitstream；结果写入 `build/work/` |
| `build/scripts/vivado/export_hardware.tcl` | 从新实现工程导出 XSA，不覆盖已验证板端产物 |
| `board/hardware/` | 最终 bit/XSA，以及从同一 XSA 提取的 PS7 初始化代码 |
| `build/reports/` | 原最终构建报告，以及从同一 routed DCP 只读补出的资源报告 |
| `evidence/hardware/` | 身份收据、原始 BD 快照、整理阶段重建验证证据 |

## 系统配置

各 RTL 文件的中文作用、当前主路径与兼容/诊断边界见 [硬件 RTL 模块中文说明](hardware_modules.md)，覆盖 `src/hardware/rtl/` 下全部 61 份文件。

PS 为 Cortex-A9，PL 共享计算阵列支持模型包与执行计划切换。相机通过 OV5640 DVP 输入，视频链路输出 HDMI，结果由 PL 叠加。PS 与 PL 的共享内存及最终 Linux 启动细节见 Linux 文档。

主要 AXI-Lite 地址：视频/预处理控制 `0x43c10000`（32 KiB）；图执行控制 `0x43c18000`（32 KiB）；控制 GPIO `0x41200000`；统计 GPIO `0x41210000`。PS 三个 HP 端口分别承接扫描、NPU 与视频访存。

最终 BD 保持 `ENABLE_PE_SPATIAL4=1`、`ENABLE_LUT_TDP=1`，`ENABLE_PERF_COUNTERS=0`、`ENABLE_PROFILE_TRACE=0`、`ENABLE_STALL_DIAG=0`。软件在计数器关闭时应遵循自身计时来源标注。保留 RTL 模块名称、接口信号与 ABI 标识，避免仅为统一命名破坏硬件合同。

## 从零重建

1. 安装 Vivado 2025.2 及 Zynq-7000/xc7z020 器件支持。
2. 将仓库放在较短的英文路径，打开已配置 Vivado 的终端，进入仓库根目录。
3. 仅创建并检查工程：

```powershell
vivado -mode batch -source build/scripts/vivado/create_project.tcl
```

默认生成 `build/work/vivado/npu100.xpr`。可通过环境变量 `NPU_BUILD_DIR` 指定另一个全新的输出目录；已有工程会被拒绝覆盖。此步骤生成厂商 IP，不需要复制原 `.gen`、`.cache` 或 `.runs`。

4. 需要从源码完整构建时，使用另一个全新输出目录：

```powershell
$env:NPU_BUILD_DIR = 'C:/work/npu100_build'
$env:NPU_BUILD_JOBS = '4'
vivado -mode batch -source build/scripts/vivado/build_bitstream.tcl
vivado -mode batch -source build/scripts/vivado/export_hardware.tcl
```

新的 XSA 位于 `build/work/hardware/npu100.xsa`。对新产物重新检查时序、DDR/设备树合同和驱动匹配关系后再部署。既有 `board/hardware` 是本次归档的最终已用产物，新构建不会覆盖它。

## 最终实现数据与证据边界

最终 routed 时序报告：WNS `+0.047 ns`、TNS `0`、WHS `+0.033 ns`、THS `0`，用户指定的时序约束通过。报告仍列出 5 个带 false-path 的输入和 8 个无 output-delay 的输出；报告正文与方法学信息完整保留，不将这一结果扩展为所有外部 IO 时序已完整建模。

从同一最终 routed DCP 重新提取的资源为 LUT 46,278、FF 45,385、BRAM Tile 91、DSP 148、Slice 13,299/13,300。`utilization_placed.rpt` 是布局阶段数据，与 routed 数据分开；顶层综合报告包含 OOC 黑盒，不作为完整系统资源总量。

本次整理已验证可在临时干净目录重建 npu100、解析模块引用、生成 BD/IP/wrapper；并比对原 BD 与重建 BD 的组件参数、端口、连接组与地址分配。未重跑综合、布局布线或上板。源文件当前哈希已记录；原构建没有同期逐源文件哈希清单，因此不声称已证明重新综合可生成逐字节相同的 bitstream。

## 尚需补充

- 从本发布包执行一次完整综合、实现及重新上板的独立复现收据。
- 最终版本覆盖全部算子和三份模型的 RTL/Golden 回归及波形材料。
- 性能汇总见 `data/metrics/`；尚缺逐次原始计时和最终逐模型输出对照。

