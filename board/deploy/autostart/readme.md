# SysV startup service

从仓库根目录执行安装步骤见 `docs/linux.md`。本目录安装到 `/opt/npu100-autostart`，运行环境在 `/opt/npu100`。

- `configure_autostart.py`：严格校验内核、启动文件、SysV布局及所有权，再安装七个启动/停止链接。
- `service.py`：单所有者摄像头进程管理、日志轮转、故障保留及正常停止。
- `npu100.init`：安装为 `/etc/init.d/npu100` 的SysV入口。
- `install_autostart.sh`：显式 `--check-only`、`--install` 或 `--disable` 操作。
- `module/`：字节未修改的最终驱动与INFO检查器。
- `files.sha256`、`sha256sums`：整理后文件校验表。
- `validation.json`：原打包阶段的host/QEMU收据，正文声明的测试范围保持不变。

本提交包只规范部署路径和校验文件名；原板测路径带有日期。本次整理的路径适配须与原板测身份区分，见 `evidence/linux/packaging/`。上电先预览，KEY3启动推理；默认选择NEU6。
