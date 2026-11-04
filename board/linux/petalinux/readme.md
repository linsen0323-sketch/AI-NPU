# PetaLinux基础系统开发说明

现有SD系统由Windows上的VirtualBox Ubuntu环境使用**PetaLinux 2025.2**构建。只验证已有冻结产物时，使用匹配且能够启动、联网的SD系统，并按[复现步骤](../../../docs/reproduction.md)安装即可。本页面向需要自行构建基础系统的开发者。

工具获取入口、基础系统来源和镜像指纹记录于[base_os_image.json](../rootfs/base_os_image.json)。宿主Ubuntu版本及安装依赖按PetaLinux 2025.2官方UG1144准备。

## 1. 加载工具并导入硬件

在Ubuntu中加载实际安装位置的环境脚本，进入自己的`navigator_linux`工程：

```sh
source "$HOME/tools/petalinux/2025.2/settings.sh"
cd "$HOME/FPGA_Projects/navigator_linux"
petalinux-config --get-hw-description=/path/to/xsa_directory
```

`/path/to/xsa_directory`是待使用XSA所在目录。仓库冻结硬件为`board/hardware/npu100.xsa`；自建硬件应使用同次构建导出的XSA。保留原工程配置；如自行新建Zynq工程，可使用工具入口：

```sh
petalinux-create project --template zynq --name navigator_linux
```

新工程需根据实际板卡配置DDR、内核、设备树、根文件系统、SD根分区、网络、SSH用户和SysV服务。创建工程和导入XSA本身不等于已得到与冻结部署包匹配的系统。

## 2. 配置、构建与SD启动

参考`board/linux/device_tree/system.dts`落实1 GiB DDR、`[0x10000000,0x20000000)`的256 MiB `no-map`预留、NPU寄存器节点与时钟。使用冻结驱动时，内核身份、配置及符号版本应匹配`board/linux/kernel/`中的记录。

```sh
petalinux-build
petalinux-package boot --fsbl images/linux/zynq_fsbl.elf --fpga /path/to/design.bit --u-boot
petalinux-package wic
```

将`/path/to/design.bit`替换为与XSA对应的bitstream。构建和打包参数以本地2025.2工具帮助及UG1144为准，输出沿用自己的PetaLinux工程配置。将生成WIC写入SD并正常弹出，设置SD启动，连接串口、摄像头、HDMI和以太网，确认可启动及登录。

## 3. 接入NPU应用

使用仓库冻结`board/boot/`、驱动、模型和服务时，按[Linux部署说明](../../../docs/linux.md)成套安装并执行BOOT_DT、PL ABI、DDR回读、预览及四键验收。若自行重建改变了内核、启动文件或应用二进制，按新版本重建配套校验合同并重新验证，不修改冻结校验值来绕过安装器检查。
