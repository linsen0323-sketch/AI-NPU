# Linux发布包路径适配清单

维护者确认原系统已经完成上板验证。本次材料整理保持当前npu100生产逻辑、模型、PL与已编译驱动/C桥/启动产物字节不变，仅在独立副本中规范部署路径和文件命名。

| 原名称或路径 | 发布包规范形式 | 涉及内容 |
|---|---|---|
| `/opt/npu100-20261102` | `/opt/npu100` | 用户态安装器、camera.json桥路径、SysV配置器、服务与init入口 |
| `/opt/npu100-autostart-20261102` | `/opt/npu100-autostart` | SysV配置器、服务与init入口 |
| `npu100-userspace.tar.gz` | `board/linux/userspace/linux_userspace.tar.gz` | 归档名及安装器相对路径 |
| `FILES.sha256` / `SHA256SUMS` | `files.sha256` / `sha256sums` | 自有部署校验引用与重新生成的校验表 |
| `README_CN.txt` / `VALIDATION.json` | `readme.md` / `validation.json` | 自启动包安装复制列表；历史验证JSON内容不改 |
| `DEPLOY_CN.md` | `src/software/runtime/linux/deploy.md` | 源部署文档名及README链接 |

运行时归档中仅自有 `camera.json` 和 `npu100.sh` 发生内容变化，另将校验表改名并重新生成。四个生产Python模块和ARM C桥与当前源码/冻结二进制逐字节一致；vendor Python层及其内部版权、模式和相对符号链接保持原样。原始 `DEPLOYMENT_PROVENANCE.json` 保留其原生成时的host/QEMU范围。

所有新旧来源、文件用途、原/目标SHA256和实际修改记在 `evidence/packaging/linux_files.json`。归档逐成员变化见 `evidence/linux/packaging/archive_changes.json`。

本次适配验证结果在 `evidence/linux/packaging/`：1208个归档文件checksum、QEMU ARM模块导入与三模型C桥、三模型包文件预检、已有SysV私有安装及进程生命周期fixture。它们不代替板端冷启动和摄像头/推理验证；新前缀版本的板测记录仍需在最终交付前补归档。
