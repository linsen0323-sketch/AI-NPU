# Linux系统、部署与复现

## 状态与版本

维护者已确认最终工程及Linux系统完成上板验证。本包采用 `src/software/runtime/linux/` 生产源码，以及与其对应的最终启动文件、时钟舍入修复驱动、用户态运行环境和SysV自启动服务。

源工程、模型、PL bitstream和XSA均未修改。文件整理将自有部署前缀从带日期的名称改为 `/opt/npu100` 与 `/opt/npu100-autostart`，并重建校验表。该路径适配属于本次打包修改，不能把原板测结论直接作为新路径版本的板测记录。保留的历史JSON收据是其生成时的host/QEMU验证范围；它们不会被改写成板测结果。

| 项目 | 固定配置 |
|---|---|
| CPU/内核 | ARMv7，`6.12.40-xilinx-g31626ef92ff1` |
| 内核源码 | Xilinx `linux-xlnx` commit `31626ef92ff11f9d3dee01926720572666fcc65a` |
| init | SysV init，默认运行级5；最终流程不使用systemd模板 |
| PL时钟 | 两路标称100MHz；驱动容许±1Hz整数舍入 |
| 预留DDR | `[0x10000000,0x20000000)`，256MiB，`no-map` |
| 摄像头原始帧 | `0x12000000`开始，八个4MiB槽 |
| ResNet18/NEU6/工作区/COCO80 | `0x14000000` / `0x18000000` / `0x1a000000` / `0x1b000000` |
| 模型目录 | `/home/petalinux/npu100_models` |
| 用户态/服务 | `/opt/npu100` / `/opt/npu100-autostart` |

## 目录与文件用途

- `src/software/runtime/linux/`：Python生产运行时、固定DDR模型清单检查、驱动源码、C桥源码及原设备树片段。C桥依赖 `src/software/app/src/` 内共享C数值实现，不能单独复制 `app/` 后编译。
- `board/boot/`：最终 `BOOT.BIN`、`boot.scr`、`image.ub`；三文件必须成套使用。
- `board/linux/device_tree/system.dts` / `system.dtb`：最终完整设备树源及编译结果，已包含DDR预留和独占驱动节点。
- `board/linux/kernel/`：原内核配置、符号CRC表与精确源码标识。
- `board/linux/driver/`：最终ARM驱动、C桥、INFO检查工具及只读预检脚本。
- `board/linux/userspace/linux_userspace.tar.gz`：私有ARM Python 3.12和生产运行时归档，保留依赖库、符号链接及上游版权信息。
- `board/linux/userspace/python_packages.json`：私有Python的上游仓库、各包版本、下载地址和SHA256。
- `board/deploy/`：启动合同核对、用户态安装和SysV服务安装源码。
- `build/scripts/linux/`：源码构建、用户态重新打包和现有fixture适配验证工具。
- `evidence/linux/`：原始host/QEMU收据、板端驱动日志、本次整理的本地验证收据；`board/user_logs/`另保存维护者先前粘贴的BOOT_DT、PL_ABI、三模型DDR回读与自启动安装输出。
- `evidence/packaging/linux_files.json`：逐文件来源、用途、修改说明及原/目标SHA256。

## 历史板端证据与边界

`evidence/linux/board/user_logs/`归档的是维护者先前提供的真实终端输出，本次未直连板卡、重跑命令或确认当前状态：

- `BOOT_DT_PASS`支持当次启动文件与实时设备树合同检查通过。
- `PL_ABI_PASS`支持当次INFO与PL CSR读取检查通过，未装载模型、未测试推理。
- `MODEL_PRELOAD_PASS`支持三模型在指定DDR地址完成SHA256/CRC32回读；输出明确未启动推理或摄像头、未切换模型。
- `AUTOSTART_ENABLED`支持SysV链接安装完成；紧接安装的状态为`managed_process_alive=false`，不能据此声称服务已经运行或冷启动验收通过。

这些不同历史操作不拼接为一次连续冷启动。完整来源与命令见 [user_logs/README.md](../evidence/linux/board/user_logs/README.md)。最终同形状Golden对照、完整推理原始日志、逐次性能记录与无日期路径冷启动收据仍待补齐。

## 前置条件

需要具有上述匹配内核、SysV布局和1GiB DDR描述的SD Linux根文件系统。完整PetaLinux工程及可公开获取的基础根文件系统镜像尚未纳入本包，见 `docs/linux_gaps.md`。现有6GiB原始wic不是包含最终驱动、模型与自启动服务的一键最终镜像。本包不把任意发行版视为等价基线。

板卡设为SD启动，摄像头、HDMI和以太网连接正确。先离线部署匹配的三份启动文件与模型包，再冷启动。不要在活动推理时覆盖启动文件、卸载驱动或重载PL。

## 部署顺序

1. 将 `board/boot/` 内三个文件复制到SD启动分区根目录；`BOOT.BIN`大小写为启动协议固定要求。
2. 将本仓库完整的 `board/` 和模型包复制到板端，保持 `board/` 相对目录；模型包安装到 `/home/petalinux/npu100_models`。模型包位于 `data/models/runtime/bundle/`，需将该目录完整内容复制到板端目录。
3. 重启进入匹配的Linux，执行以下核对与显式安装步骤（示例先将当前目录切到板端仓库根目录）：

```sh
sh board/deploy/boot/verify_after_boot.sh
chmod +x board/linux/driver/npu_driver_info
sh board/linux/driver/check_driver.sh --check-only
sudo sh board/linux/driver/check_driver.sh --load
sh board/deploy/userspace/install_runtime.sh --check-only
sudo sh board/deploy/userspace/install_runtime.sh --install
sudo /opt/npu100/npu100.sh check-pl
sudo /opt/npu100/npu100.sh load-models
sh board/deploy/autostart/install_autostart.sh --check-only
sudo sh board/deploy/autostart/install_autostart.sh --install
```

驱动已加载时，不重复运行 `--load`。先核对成功绑定及INFO结果。已存在 `/opt/npu100` 或不匹配的服务时安装器拒绝覆盖，需要维护者处理现有安装，不能靠重复执行绕过检查。上述脚本在本次整理中没有在板端执行。

4. 确认没有手工运行的摄像头进程，再正常重启；核对开机预览和四键：KEY0选择ResNet18，KEY1选择NEU6，KEY2选择COCO80，KEY3启动/停止。默认NEU6，上电先预览、推理停止。

```sh
sudo /etc/init.d/npu100 status
sudo tail -n 60 /var/log/npu100/camera.log
```

预期管理状态 `stage=ready`、HDMI有画面；按键后分别验证三模型结果和正常停止。服务最多等待200秒正常退出；故障保留、不自动反复复位或强杀。

## 源码构建

在Linux/WSL安装适用的ARM交叉编译器、make、编译内核所需工具。原内核使用GCC13.4；已有驱动和C桥使用GCC13.3，CRC/ABI比较报告位于 `evidence/linux/driver/`。

```sh
export CROSS_COMPILE=arm-linux-gnueabihf-
export CC=arm-linux-gnueabihf-gcc-13
export KERNEL_SRC=/absolute/path/to/linux-xlnx
export KERNEL_OUT=/absolute/path/to/kernel-output
sh build/scripts/linux/build_software.sh
```

首次准备精确内核：下载 `board/linux/kernel/source.json` 中commit归档并核对SHA256，解压至 `KERNEL_SRC`；将 `board/linux/kernel/kernel.config` 复制为 `$KERNEL_OUT/.config`，运行 `make ARCH=arm CROSS_COMPILE=... CC=... O=... olddefconfig`，检查变化仅涉及已记录的编译器元数据，再构建 `vmlinux modules` 生成匹配的headers和符号表。仅 `modules_prepare` 不能生成启用MODVERSIONS所需的完整符号CRC。不要把本包的符号表直接配给其他内核。

`build_software.sh`只构建驱动、共享库和INFO检查器，不安装、不加载驱动、不访问板卡。生成的新二进制如改变SHA，须重新构建自己的部署校验合同并重新做板测；现成部署服务对驱动SHA和内核配置采用严格匹配。

完整设备树可用 `dtc -I dts -O dtb -o system.dtb board/linux/device_tree/system.dts` 编译。它是从最终DTB反编译而来的完整源，dtc可能保留原始板级警告；语义对照应基于节点/属性而非源文本排序。完整BOOT.BIN、U-Boot和根文件系统的源码重建仍需补齐对应工程，见缺口清单。

## 私有运行环境重新打包与验证

`repack_userspace.py`使用已提供归档中的冻结第三方Python层，替换仓库内自有运行时源码、辅助脚本及指定C桥，不访问网络或板卡；它不宣称重新从源码构建Python解释器。原始归档保留上游版权和包来源。可用以下命令生成独立输出：

```sh
python3 build/scripts/linux/repack_userspace.py --bridge /absolute/path/to/rebuilt/libnpu_camera.so --output /absolute/path/to/new_linux_userspace.tar.gz
python3 build/scripts/linux/verify_userspace.py --archive /absolute/path/to/new_linux_userspace.tar.gz
```

默认验证要求C桥字节与冻结板测版本相同；若自行修改C桥，实现者应重新建立数值/ABI与板测验证。QEMU验证还需 `--qemu /usr/bin/qemu-arm-static --sysroot /path/to/exact_board_libc_root`，使用 `data/models/runtime/bundle/` 做只读文件检查。板端基础镜像尚待补齐，因此该sysroot不随本包分发。

私有fixture：`python3 build/scripts/linux/verify_autostart_install.py`；服务fixture使用真实私有进程、flock和信号，需要在独立Linux测试环境以root运行 `python3 build/scripts/linux/verify_service.py`。它们不访问板卡、/boot或真实/opt安装路径。
