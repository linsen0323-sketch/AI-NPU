# 用户提供的历史板端输出

这些文件摘录自用户在本项目对话中粘贴的实际终端输出，仅保存完整 JSON 块或相关原始输出行。来源、原命令与证据范围见 `metadata.json`。确切执行时间未知，本次材料整理没有直连开发板、重跑命令或确认其当前状态。

| 文件 | 原历史操作 | 可以支持的结论 | 不支持的结论 |
|---|---|---|---|
| `boot_dt_pass.txt` | `sh verify_after_boot.sh` | 当次启动文件/设备树检查报告通过，256 MiB 预留节点生效 | 驱动绑定、PL 寄存器、模型装载或推理 |
| `pl_abi_pass.json` | `sudo /opt/npu100-20261102/npu100.sh check-pl` | 当次 INFO 与 PL CSR 读取报告通过；保留全部寄存器数值 | 该阶段未装载模型，未测试推理 |
| `model_preload_pass.json` | `sudo /opt/npu100-20261102/npu100.sh load-models` | 三模型在指定 DDR 地址完成 SHA256/CRC32 回读报告 | 该操作未启动推理或摄像头，未切换模型 |
| `autostart_enabled.json` | `sudo sh install_autostart.sh --install` | SysV 自启链接安装报告完成，设置下次启动先预览、推理停止 | 当前进程已启动或冷启动验证已通过 |
| `autostart_status_after_install.json` | `sudo /etc/init.d/npu100 status` | 紧接安装之后的历史状态为 `managed_process_alive=false` | 不能用安装成功标记声称当时服务正在运行 |

JSON 中保留当时带日期的安装前缀与 `models/m1`、`models/m3` 包内部路径，它们是历史输出数据，不替换成整理后路径。自动启动输出中的 `enabled_at_epoch` 也是原值；不能据此认定真实公历时间。

本归档与上级目录的 [`driver_load.txt`](../driver_load.txt) 分别覆盖不同阶段。原驱动日志仍保留 `-34` 及后续成功加载信息；不能将多条历史输出拼接成同一次冷启动的连续证据。维护者后来确认整机上板验证通过属于作者确认，不能改变这些单次操作自身的验证范围。
