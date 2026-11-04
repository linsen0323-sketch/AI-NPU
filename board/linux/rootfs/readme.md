# 基础 Linux 系统

本目录保存基础系统来源元数据 base_os_image.json，未分发 6 GiB WIC 镜像。该元数据中的 SHA256 是既有登记值，本次材料整理没有重新读取原镜像计算。

既有系统由 Windows 主机上的 VirtualBox / Ubuntu 环境使用 PetaLinux 2025.2 构建，工程名 navigator_linux。原 WIC 是基础系统，不包含最终 NPU 应用更新，不是本项目最终一键整卡镜像。

当前还需提供匹配基础镜像的公开下载入口与核验记录，或者完整 PetaLinux/Yocto 工程、rootfs/BSP 配置。现有内核配置和启动文件不能代替完整根文件系统的重建信息。工具官方入口见 base_os_image.json，具体缺口见 ../../../docs/linux_gaps.md 及 ../../../docs/missing_materials.md。
