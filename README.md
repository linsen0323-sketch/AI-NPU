# NPU100 多模型嵌入式 AI 加速平台

基于 **AMD Zynq-7020** 的共享神经网络加速器与 Linux 视觉系统，支持 **ResNet18 六分类、YOLOX-S NEU6 检测和 YOLOX-S COCO80 检测**。摄像头采集、模型推理、HDMI 叠加显示和四键控制组成完整的板端运行链路。

本仓库提供硬件与软件源码、模型工具、冻结部署产物、验证记录、设计文档和大模型协作工作流。材料入口见 [项目材料索引](docs/submission_requirements.md)，证据范围见 [验证覆盖矩阵](docs/requirement_matrix.md)。

## 系统与工程身份

- **PL**：自研 RTL 图执行后端，共享 PE 阵列、片上缓存与流式 DDR 访问；同一物理阵列支持 `4×8×8` 和 `1×8×32` 两种映射。最终配置启用四空间映射，不是两套独立的 PE 电路。
- **PS / Linux**：负责模型管理、任务提交、固定点后处理、摄像头/显示控制及 SysV 启动服务。
- **板端交互**：OV5640 摄像头、HDMI 显示；KEY0 / KEY1 / KEY2 分别选择 ResNet18 / NEU6 / COCO80，KEY3 控制推理启动与停止。上电加载模型并进入预览，默认选择 NEU6，推理等待按键启动。
- **唯一硬件入口**：重建工程名为 `npu100`，生成 `npu100.xpr`；器件为 `xc7z020clg400-2`，工具为 Vivado 2025.2，PL 两路 FCLK 标称均为 100 MHz。
- **固定内存合同**：Linux 将 `[0x10000000,0x20000000)` 预留为 256 MiB `no-map` 区域。模型、图像和工作区的地址由设备树、驱动和运行时共同约束。

源代码、最终 bit/XSA、模型与运行环境的身份记录位于 [evidence](evidence/) 和 [manifests](manifests/)。既有功能已由维护者完成上板验证；归档中的原始日志、历史主机检查和此次整理校验分别标明范围。

历史板端BOOT_DT、PL_ABI、三模型DDR回读及自启动安装输出已整理到[user_logs](evidence/linux/board/user_logs/README.md)。这些命令未在本次重跑：DDR回读没有执行推理，自启动安装后状态为`managed_process_alive=false`，不能据此声称当时服务已运行。完整推理/同形状Golden、连续冷启动和原始逐次性能记录仍待补档。

## 目录

| 目录 | 内容 |
|---|---|
| [src/hardware](src/hardware/) | PL RTL、引脚/时钟/CDC 约束、BD 与 IP 配置 |
| [src/software](src/software/) | PS 共享算法、裸机运行时、Linux 驱动与生产运行时 |
| [src/host](src/host/) | 训练、PTQ、ONNX 导出、整数图编译与执行计划工具 |
| [src/third_party](src/third_party/) | YOLOX 等第三方源码及原许可证 |
| [data/models](data/models/) | 冻结 checkpoint、ONNX、量化参数、中间输入与最终 DDR 模型包 |
| [data](data/) | 数据来源/划分/校准清单、精度记录、参考数据与测量汇总 |
| [sim](sim/) | 模块 testbench、仿真入口及系统级验证位置 |
| [build](build/) | 重建脚本及综合、实现、资源与时序报告 |
| [board](board/) | 匹配 bit/XSA、启动文件、设备树、驱动、用户态归档与部署工具 |
| [skill](skill/) | 发布完整性与 Linux NPU 分层验收两项可复用技能 |
| [report](report/) | 设计报告、技术报告、技术原理图和协作记录 |
| [evidence](evidence/) | 原始验证收据、硬件身份、源码核对与整理检查记录 |
| [docs](docs/) | 架构、环境、构建、部署、模型流程、授权及材料缺口说明 |
| [manifests](manifests/) / [tools](tools/) | 文件用途、来源与 SHA256 清单，以及发布校验工具 |

`build/work/` 是可再生目录，不作为源码交付。`README.md`、`SKILL.md`、`Makefile`、`BOOT.BIN`、`SHA256SUMS` 等保留工具或格式规定的名称。

公开报告统一提供PDF：[设计报告](report/design/design_report.pdf)和[技术报告](report/technical/technical_report.pdf)；技术原理图见[figures](report/figures/README.md)。两项技能与真实协作记录分别见[skill](skill/README.md)和[report/collaboration](report/collaboration/README.md)。

## 性能与资源

以下为维护者确认的**同平台板端单图整网推理约值**。软件两列分别为无 SIMD 标量 C、NEON 优化加双核并行；不包含模型切换时间。

| 模型 | 无 SIMD 标量 C | NEON 双核 | 本系统 |
|---|---:|---:|---:|
| ResNet18 | 12 s | 1.3 s | 0.5 s |
| YOLOX-S NEU6 | 50 s | 4.6 s | 1.4 s |
| YOLOX-S COCO80 | 55 s | 5.1 s | 1.6 s |
| 各推理一张的合计 | 117 s | 11.0 s | 3.5 s |

按合计时间计算，相对标量 C 约加速 **33.4 倍**，相对 NEON 双核约加速 **3.14 倍**。这些数值不等同于摄像头到 HDMI 的链路时延或新检测结果更新率。原始逐次计时日志尚未随包归档，详见 [材料缺口](docs/missing_materials.md)。

最终 routed 报告为 LUT **46,278 / 53,200**、FF **45,385 / 106,400**、BRAM Tile **91 / 140**、DSP **148 / 220**、Slice **13,299 / 13,300**；100 MHz 下 WNS **+0.047 ns**、WHS **+0.033 ns**，TNS / THS 为零。结论限于归档约束；报告仍列出 5 个无 input-delay 的输入与 8 个无 output-delay 的输出，详见 [硬件说明](docs/hardware.md)。

主机精度结果保留在 [data/metrics](data/metrics/)。NEU6 的 640 输入精度和 ResNet18 的原 224 输入验证结果不能代替最终板端 256 / 160 输入精度。

## 复现流程

可选择使用`board/`中的冻结产物部署，或先从源码重建硬件/自有软件。**基础系统仍有前置缺口：**完整PetaLinux/rootfs工程、匹配基础SD镜像的公共获取方式及BOOT启动组件生成配置尚未补齐，当前不能承诺仅凭空白SD卡从源码构建整机。基础镜像来源只归档元数据，详见[缺失材料](docs/missing_materials.md)。

### 1. 环境与完整性检查

- 硬件：Zynq-7020 Navigator V2，`xc7z020clg400-2`、1GiB DDR、OV5640、HDMI、四键、以太网和SD卡。
- 主机：Python3.11+、Git与Git LFS；重建硬件需要Vivado2025.2及xc7z020器件支持。
- 板端：ARMv7、SysV init、精确内核`6.12.40-xilinx-g31626ef92ff1`；已有冻结ARM Python运行环境，无须在板端安装编译器。

从Git克隆后先获取LFS实体，在仓库根目录执行：

```sh
git lfs pull
python tools/release_manifest.py --check
python -B build/scripts/models/verify_models.py
```

预期文件与模型合同检查通过。若文件缺失、内容是LFS指针或哈希不一致，先解决完整性问题再部署。[环境要求](docs/environment.md)记录各开发阶段的依赖。

### 2. 硬件工程、bit与XSA

使用冻结`board/hardware/`和`board/boot/`部署时，可以跳至第3步。需要检查源码工程时，在配置好Vivado的终端执行：

```powershell
vivado -mode batch -source build/scripts/vivado/create_project.tcl
```

仅创建工程并生成BD/IP，默认入口为`build/work/vivado/npu100.xpr`，不运行综合实现。已有同名工程会拒绝覆盖。

需要完整生成新bit时，另选全新的输出目录，再显式执行：

```powershell
$env:NPU_BUILD_DIR = [System.IO.Path]::GetFullPath('build/work/vivado_full')
$env:NPU_BUILD_JOBS = '4'
vivado -mode batch -source build/scripts/vivado/build_bitstream.tcl
vivado -mode batch -source build/scripts/vivado/export_hardware.tcl
```

新XSA位于`build/work/hardware/npu100.xsa`，新报告位于`build/work/reports/`；检查最终routed的setup、hold、路由和约束提示。新产物不覆盖归档产物。**XSA不是可直接复制到SD启动分区的启动文件。**新硬件需重新生成匹配启动链、核对设备树/驱动/模型合同并建立新板测收据；当前缺失的BOOT生成环节见[硬件说明](docs/hardware.md)与[Linux说明](docs/linux.md)。下面部署步骤使用冻结的匹配整套产物。

### 3. 准备匹配SD Linux、启动文件与模型

先获得匹配基础rootfs，满足第1步内核与SysV布局；不能把任意ARM Linux视为等价基线。SD设为启动设备，离线将`board/boot/BOOT.BIN`、`boot.scr`、`image.ub`成套复制至SD第一分区根目录，保持`BOOT.BIN`大小写。正常卸载SD后插卡上电，连接以太网或串口登录。

将仓库的完整`board/`复制到板端，保留内部目录。以下部署命令在**板端包含`board/`的目录**运行。将`data/models/runtime/bundle/`的完整内容放入板端`/home/petalinux/npu100_models/`；目标目录下直接有`manifest.json`、`SHA256SUMS`、`models/`和`coco80/`，不要额外嵌套`bundle/`。

板端核对模型文件：

```sh
(cd /home/petalinux/npu100_models && sha256sum -c SHA256SUMS)
uname -r
```

需要验证模型文件构造时，可在主机另一个空目录重建：

```sh
python -B build/scripts/models/rebuild_runtime_models.py --output work/model_rebuild
```

三份输出应与冻结DDR模型SHA256相同；此步骤不执行网络。训练、量化和编译分支见[模型流程](docs/model_pipeline.md)。

### 4. 实时设备树与驱动

```sh
sh board/deploy/boot/verify_after_boot.sh
chmod +x board/linux/driver/npu_driver_info
sh board/linux/driver/check_driver.sh --check-only
sudo sh board/linux/driver/check_driver.sh --load
```

预期`BOOT_DT_PASS`，256MiB `no-map`区域`[0x10000000,0x20000000)`生效，驱动绑定并出现`/dev/unified-npu`。已加载驱动时先核对身份，不重复`--load`。启动文件、内核或设备树不匹配时保留输出并处理差异，不跳过检查。

### 5. 安装用户态、核对PL并加载DDR模型

```sh
sh board/deploy/userspace/install_runtime.sh --check-only
sudo sh board/deploy/userspace/install_runtime.sh --install
sudo /opt/npu100/npu100.sh check-pl
sudo /opt/npu100/npu100.sh load-models
```

预期依次出现安装检查通过、`PL_ABI_PASS`、`MODEL_PRELOAD_PASS`和三个模型DDR回读通过。`check-pl`只检查INFO/PL寄存器；`load-models`只将SD模型暂存到预留DDR并回读，不启动摄像头或推理。DDR断电失效，开机服务会重新装载。

安装器拒绝覆盖已存在的`/opt/npu100`；识别并处理既有安装后再继续，不通过修改校验文件绕过检查。自有Linux源码交叉构建及精确内核`Module.symvers`要求见[Linux说明](docs/linux.md)。

### 6. 前台运行摄像头服务

首次调试可在一个SSH终端前台运行。确认没有其他NPU/摄像头进程、已有SysV服务或遗留socket持有资源，再创建本地socket目录：

```sh
sudo mkdir -p /run/npu100
sudo chmod 700 /run/npu100
sudo /opt/npu100/python-runtime/python3 -u /opt/npu100/runtime/linux_camera.py --config /opt/npu100/camera.json serve
```

`serve`持续运行，默认先预览、推理关闭，不会立即返回shell。使用实体键控制，或在第二个SSH终端发送本地控制命令：

```sh
sudo /opt/npu100/python-runtime/python3 /opt/npu100/runtime/linux_camera.py --config /opt/npu100/camera.json status
sudo /opt/npu100/python-runtime/python3 /opt/npu100/runtime/linux_camera.py --config /opt/npu100/camera.json select 3
sudo /opt/npu100/python-runtime/python3 /opt/npu100/runtime/linux_camera.py --config /opt/npu100/camera.json start
sudo /opt/npu100/python-runtime/python3 /opt/npu100/runtime/linux_camera.py --config /opt/npu100/camera.json stop
```

`select`支持1、3、4，分别为ResNet18、NEU6、COCO80。`stop`停止推理并保留摄像头预览。完成前台调试后，在运行`serve`的终端按Ctrl+C，等待任务排空、进程退出和socket释放，再配置SysV托管；不要同时启动两份服务。

### 7. 安装SysV开机服务

在板端包含`board/`的目录执行：

```sh
sh board/deploy/autostart/install_autostart.sh --check-only
sudo sh board/deploy/autostart/install_autostart.sh --install
sudo /etc/init.d/npu100 start
sudo /etc/init.d/npu100 status
sudo tail -n 60 /var/log/npu100/camera.log
```

安装只配置服务与运行级链接，不能单凭`AUTOSTART_ENABLED`判定进程运行。显式`start`后检查托管进程和`stage=ready`；服务已运行时不再启动前台`serve`。正常重启以验证开机流程：

```sh
sudo reboot
```

重新登录后再次执行`status`和日志检查。服务应重新从SD装载模型，进入摄像头预览，默认NEU6且推理关闭。

### 8. 四键与结果验收

| 按键 | 功能 |
|---|---|
| KEY0 | 选择ResNet18六分类 |
| KEY1 | 选择YOLOX-S NEU6 |
| KEY2 | 选择YOLOX-S COCO80 |
| KEY3 | 启动/停止当前模型推理 |

依次验证模型选择、分类及置信度、检测框、模型/耗时/结果更新率、停止后继续预览和再启动。COCO80完整类别保留在软件结果JSON；冻结PL的标签位宽有限，HDMI标签显示范围不等于80类检测头的计算范围。

保存启动、驱动、PL ABI、DDR回读、三模型输出及按键过程的原始日志，并记录启动文件/驱动/模型哈希。用最终160/256/256相同输入配置进行Golden比较；性能分别记录标量C、NEON双核和本系统的相同计时范围。新路径`/opt/npu100`仍需独立冷启动收据，历史日期路径日志不能替代。更细的验证与未闭合环节见[复现文档](docs/reproduction.md)和[材料缺口](docs/missing_materials.md)。

## 授权与来源

文件级许可证和第三方归属见 [license.md](license.md) 与 [第三方说明](docs/third_party.md)。项目自有代码的统一许可证尚待维护者确定；GPL 驱动、Xilinx 初始化文件、YOLOX 源码、模型权重和数据集分别遵循其原有授权，不能由一个仓库许可证替代。

大文件由 `.gitattributes` 指定 Git LFS 管理；本仓库中的 SHA256 用于核对实体文件内容。
