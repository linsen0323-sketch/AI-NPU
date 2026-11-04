# Linux 部署入口

当前整机采用自定义 Linux 驱动与 SysV init 服务。部署顺序、精确内核与设备树合同、三模型装载以及已有安装处理条件统一见 [Linux 系统与部署](../../../../docs/linux.md)。从零复现范围见 [复现总览](../../../../docs/reproduction.md)。

本目录保留生产运行时、内核驱动、设备树片段及共享算法接口源码。完整部署文件在 board/linux 和 board/deploy；不要使用其他历史工程的 systemd 示例或本机绝对路径替代本版说明。
