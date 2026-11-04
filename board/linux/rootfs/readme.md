# 基础 Linux 系统

上板部署以**已能从SD卡启动、通过串口或以太网登录的匹配Linux系统**为前提。基础系统由Windows主机上的VirtualBox / Ubuntu环境使用PetaLinux 2025.2构建，工程名为`navigator_linux`。

系统生成与部署顺序为：Windows安装VirtualBox → Ubuntu安装并加载PetaLinux 2025.2 → 导入匹配XSA并构建系统 → 将生成的WIC写入SD卡 → 启动并登录 → 安装本仓库提供的NPU启动文件、驱动、运行时、模型与服务。

本目录的[base_os_image.json](base_os_image.json)记录基础WIC的名称、6,442,455,040字节容量、既有SHA256及VirtualBox/PetaLinux官方获取入口。仓库不重复分发整卡镜像；该基础WIC也不包含后续NPU应用安装内容。元数据中的SHA256为既有登记值，本次整理未重新读取原镜像计算。

配套部署要求ARMv7、SysV init、1 GiB DDR描述和内核`6.12.40-xilinx-g31626ef92ff1`。使用现有匹配SD系统时，按[复现步骤](../../../docs/reproduction.md)继续；重新构建基础系统时，按[PetaLinux开发说明](../petalinux/readme.md)在自己的匹配工程中操作。
