# 复现步骤

本工程提供两条路线：**使用冻结产物部署**与**从源码重建可用环节**。最终应用功能已由维护者完成上板验证；基础 SD Linux 的公共获取方式和完整系统生成配置尚有缺口，见 [missing_materials.md](missing_materials.md)。当前不能将下面的分段流程等同于已独立完成的“空白 SD 卡到整机”复现。

## 1. 环境与文件完整性

硬件为 Zynq-7020 Navigator V2，器件 `xc7z020clg400-2`，连接 OV5640、HDMI、以太网并使用 SD 启动。硬件重建使用 Vivado 2025.2；Linux 为 ARMv7、SysV init、1 GiB DDR 描述，内核精确版本为 `6.12.40-xilinx-g31626ef92ff1`。

主机安装 Python 3.11+。发布校验主要使用标准库，模型构造/训练工具另按 [environment.md](environment.md) 和 [model_pipeline.md](model_pipeline.md) 准备依赖。若从 Git 克隆，先安装 Git LFS 并取得实体文件，然后在仓库根目录执行：

```sh
git lfs pull
python tools/release_manifest.py --check
python -B build/scripts/models/verify_models.py
```

预期完整性和模型二进制合同检查通过。任何实体缺失、LFS 指针未展开或哈希不一致都应先解决，不跳过检查。源码与产物的来源分别记录于 `manifests/`、`evidence/packaging/` 和 `evidence/hardware/artifact_identity.json`。

## 2. 路线 A：部署冻结产物

### 2.1 前置条件与 SD 文件

需要先获得**匹配的基础 SD Linux 根文件系统**。本仓库提供其来源元数据与精确内核身份，但目前没有可公开下载的匹配基础镜像，也没有完整 PetaLinux/rootfs 工程；任意其他 ARM Linux 不能视为等价替代。先完成此项前提，再进行以下部署。

1. SD 第一分区的根目录放置 `board/boot/` 中的 `BOOT.BIN`、`boot.scr`、`image.ub`，保持三者成套一致。离线修改并正常卸载存储设备后，再插卡上电。
2. 将仓库的 `board/` 目录复制到板端，保留其内部相对布局。以下板端命令均在包含 `board/` 的目录执行。
3. 将 `data/models/runtime/bundle/` 的**完整内容**放入板端 `/home/petalinux/npu100_models/`。例如该目录下应直接出现 `manifest.json`、`SHA256SUMS`、`models/` 与 `coco80/`，不要多嵌套一层 `bundle/`。
4. 板端先核对模型文件：

   ```sh
   cd /home/petalinux/npu100_models
   sha256sum -c SHA256SUMS
   ```

不要将新构建 XSA 或单个 bit 与冻结启动/模型/驱动任意混用。Linux 中 FPGA manager 显示 `operating` 只表示管理器状态，实际 PL 身份还需后面的寄存器合同检查。

### 2.2 设备树与驱动

通过以太网或串口登录后，返回板端仓库目录，执行：

```sh
uname -r
sh board/deploy/boot/verify_after_boot.sh
chmod +x board/linux/driver/npu_driver_info
sh board/linux/driver/check_driver.sh --check-only
sudo sh board/linux/driver/check_driver.sh --load
```

验收包括：内核身份和启动文件匹配；1 GiB DDR；`[0x10000000,0x20000000)` 的 256 MiB `no-map` 预留；NPU 设备树节点；驱动成功绑定并出现 `/dev/unified-npu`。`--check-only` 不加载模块。驱动已经加载时先确认当前身份，不反复运行 `--load`。

驱动源码包含标称100 MHz时钟±1 Hz舍入处理。遇到错误保留首次输出与 `dmesg`，按 [linux.md](linux.md) 和 [Linux验收技能](../skill/linux-npu-evidence/SKILL.md) 分层定位；不要仅凭设备节点存在判定推理通过。

### 2.3 安装运行环境并核对 PL

```sh
sh board/deploy/userspace/install_runtime.sh --check-only
sudo sh board/deploy/userspace/install_runtime.sh --install
sudo /opt/npu100/npu100.sh check-pl
```

安装器使用冻结 ARM Python/C 桥归档，不依赖板端安装 gcc、make 或系统 Python。出现 `PL_ABI_PASS` 后才能继续；此时只证明设备/ABI/寄存器读取合同，不代表模型已加载或网络已经执行。

已有 `/opt/npu100` 或不匹配服务时安装器拒绝覆盖。应先识别当前安装，不通过删除文件、改校验表或重复执行绕过身份检查。

### 2.4 SD 模型装入预留 DDR

```sh
sudo /opt/npu100/npu100.sh load-models
```

预期 `MODEL_PRELOAD_PASS`，三个模型的 DDR 回读均通过。固定槽位为：

| 模型/区域 | 地址 |
|---|---|
| ResNet18 / ID1 | `0x14000000` |
| YOLOX-S NEU6 / ID3 | `0x18000000` |
| 工作区 | `0x1a000000` |
| YOLOX-S COCO80 / ID4 | `0x1b000000` |

此命令只完成模型暂存和回读校验，不启动摄像头或推理。断电后 DDR 内容消失；下一步开机服务会重新从 SD 读取模型。

### 2.5 配置开机服务与四键验收

确认没有手工运行的 `linux_camera.py` 进程，再安装服务：

```sh
sh board/deploy/autostart/install_autostart.sh --check-only
sudo sh board/deploy/autostart/install_autostart.sh --install
```

安装生效于下一次启动或显式服务启动。本路线使用正常重启验收：

```sh
sudo reboot
```

重新登录后：

```sh
sudo /etc/init.d/npu100 status
sudo tail -n 60 /var/log/npu100/camera.log
```

预期模型加载完成，托管进程进入 `stage=ready`，HDMI 显示摄像头预览；默认NEU6且推理停止。依次按 KEY0 / KEY1 / KEY2 选择 ResNet18 / NEU6 / COCO80，按 KEY3 启停推理。验证分类及置信度、检测框及类别、模型切换和停止后继续预览。停机使用正常服务退出或系统关机，不在活动推理期间覆盖模型或卸载驱动。

保存启动串口、驱动/模型回读、服务状态、三模型结果和按键过程日志，并记录启动文件、驱动、模型哈希。无日期部署前缀属于整理后的布局，需要本路线取得独立冷启动收据，不能直接沿用原日期路径的历史收据。

## 3. 路线 B：从源码重建

### 3.1 创建硬件工程

在配置好 Vivado 2025.2 的终端进入仓库根目录。仅创建工程及生成 BD/IP：

```powershell
vivado -mode batch -source build/scripts/vivado/create_project.tcl
```

默认生成 `build/work/vivado/npu100.xpr`。输出目录已存在工程时脚本拒绝覆盖。`create_project.tcl` 不运行综合或实现。

如需完整构建，使用一个新的输出目录；下面的路径由复现者自行选定：

```powershell
$env:NPU_BUILD_DIR = 'C:/work/npu100_build'
$env:NPU_BUILD_JOBS = '4'
vivado -mode batch -source build/scripts/vivado/build_bitstream.tcl
vivado -mode batch -source build/scripts/vivado/export_hardware.tcl
```

新 XSA 输出为 `build/work/hardware/npu100.xsa`，新报告输出为 `build/work/reports/`。核查最终 routed 的 setup、hold、总负裕量、路由和约束提示；新构建结果不覆盖 `board/hardware/` 冻结产物。Vivado 完成运行不等于设计已在新 bit 下通过整机验收。

### 3.2 模型文件重建与训练分支

使用冻结编译输入构造最终三个 DDR 模型文件：

```sh
python -B build/scripts/models/rebuild_runtime_models.py --output work/model_rebuild
```

输出目录必须为空。预期 `rebuild_verification.json` 中三项 `matches=true`，表示与最终模型包逐字节一致。该检查不执行训练、量化、网络推理、RTL 或硬件访问。

若需要从训练开始，按 [model_pipeline.md](model_pipeline.md) 准备真实 NEU/COCO 数据与环境，使用 `src/host/training/`、`src/host/quantization/` 和 `src/host/compiler/`。ResNet18 训练为224输入、最终板端为160；NEU6原QDQ为640、最终板端为256。COCO80使用导入的预训练权重并独立执行256量化/编译。ResNet首次FP32→QDQ原脚本尚缺，因此当前完整模型重建以已归档的冻结中间输入为起点。

### 3.3 Linux 自有软件构建

使用 `board/linux/kernel/source.json` 指定的精确 `linux-xlnx` commit、`kernel.config` 和适用 ARM 交叉工具链。该内核启用 `CONFIG_MODVERSIONS=y`，需要完整构建匹配内核得到 `Module.symvers`；单独执行 `modules_prepare` 不足以生成所需符号 CRC。

```sh
export CROSS_COMPILE=arm-linux-gnueabihf-
export CC=arm-linux-gnueabihf-gcc-13
export KERNEL_SRC=/path/to/exact/linux-xlnx
export KERNEL_OUT=/path/to/matching/kernel-output
sh build/scripts/linux/build_software.sh
```

脚本只构建驱动、C 桥和 INFO 工具，不安装、不加载、不访问板卡。重建二进制的哈希改变后，应重新生成自己的部署合同并做 ABI/数值/板测验证，不能修改冻结收据来绕过检查。

用户态重新打包、QEMU/fixture验证与完整设备树构建见 [linux.md](linux.md)。当前尚缺基础rootfs、BSP/FSBL/U-Boot/BIF的完整构建输入，所以此步骤不生成完整可烧写SD系统。

### 3.4 定向仿真与重新验收

定向仿真入口见 `sim/rtl/unit/README.md`；历史日志/波形及当前DUT身份见 `evidence/sim/unit/`。重跑时保存新输出，不改写历史记录。最终三模型整网 RTL/Golden 回归仍需补齐。

使用新硬件或新驱动前，应重新检查设备树/DDR/时钟/寄存器 ABI/模型合同，并按路线A完成冷启动、三模型和按键验收。新增测试结论只关联本次实际执行的源码与产物哈希。

## 4. 比较方法

- 性能采用同平台、同输入和相同计时范围的整网单图耗时，分别记录标量C、NEON双核和本系统；三模型合计加速比分母均为3.5秒，33.4倍仅对应标量C对照。
- 分类精度与检测精度使用最终160/256/256配置；保留原始输入、输出和模型身份。640/224主机精度不得替代最终板端精度。
- 区分模型文件回读、主机数值验证、RTL仿真、综合/实现、板端推理和HDMI新结果显示；每一级保留自己的原始收据。
- 现有时序报告只对当前约束给出结论；不得把未建模的外部 I/O 当作已完整验证。
