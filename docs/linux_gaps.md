# Linux材料待补清单

本表描述提交材料缺口，不否定维护者已经完成的板测功能。

| 待补材料 | 当前已有 | 缺口影响 |
|---|---|---|
| 完整PetaLinux工程或等价Yocto配方、BSP、rootfs配置与构建说明 | 精确内核commit、原kernel.config、最终启动文件 | 尚不能从源码完整重建基础SD系统 |
| 可公开获取的基础SD镜像、下载地址与SHA256，或最终可分发镜像 | board/linux/rootfs/base_os_image.json记录基础WIC来源、大小与哈希，镜像未分发且未合入最终更新 | 新用户需先获得完全匹配的根文件系统 |
| BOOT.BIN的BIF、FSBL/U-Boot源码版本、配置及生成步骤 | 已匹配PL配置数据的最终BOOT.BIN | 只能使用冻结启动产物，不能完整重建启动链 |
| 最终冷启动/开机自启动的连续串口与服务运行日志 | host/QEMU验证、用户确认整机完成，另有user_logs历史自启动安装输出及安装后服务false状态 | 安装完成不证明服务已运行；仍缺一次完整冷启动与stage=ready的原始连续证据 |
| 最终三模型推理、摄像头/HDMI与四键的完整输出及同形状Golden | 已有驱动日志和历史BOOT_DT/PL_ABI/三模型DDR SHA256/CRC回读输出 | DDR装载未执行推理，仍需逐模型原始输出、Golden比较与原始计时 |
| 本次去日期部署路径的板测记录 | 原实现板测结论；本次适配只做本地fixture/QEMU检查 | 新路径版本尚不能继承原路径板测身份 |

历史用户输出位于 [evidence/linux/board/user_logs/](../evidence/linux/board/user_logs/README.md)，本次整理未直连开发板或重跑命令，不能将不同历史操作拼成同一次冷启动证据。

后续原始日志可补入 `evidence/linux/board/`；基础系统工程可补入 `board/linux/rootfs/` 和 `board/linux/petalinux/`。已有来源元数据不代表已具备完整基础系统或启动链构建配置。
