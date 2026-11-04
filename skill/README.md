# 可复用技能包

本目录收录从 NPU100 实际开发问题中提炼的两项技能，说明适用范围、调用方法、失败来源、失效条件与已验证效果。脚本只依赖 Python 3 标准库，均可在主机离线运行。

| 技能 | 作用 | 用法 |
|---|---|---|
| `fpga-release-integrity` | 工程身份与文件完整性核对 | `python skill/fpga-release-integrity/scripts/verify_manifest.py --root . --manifest manifests/files.sha256` |
| `linux-npu-evidence` | 保存的 Linux NPU 日志分层复核 | `python skill/linux-npu-evidence/scripts/classify_log.py --log evidence/linux/board/driver_load.txt` |

每项的适用范围、工作流、失效条件和经验来源见对应 `SKILL.md`。验证收据位于 `report/collaboration/skill_validation.json`；协作过程见 `report/collaboration/collaboration_record.md`。读取历史日志和文件校验不会证明当前硬件已经运行。

## 适用范围与失效条件

- 完整性技能适用于已有可信 SHA256 清单的软硬件交付。清单不覆盖全部关键文件、活动工程入口不明确或部署产物缺失时，只能给出实际取得材料的核对结果；不能证明算法或时序正确。
- Linux 日志技能适用于已经保存的 NPU100 风格验收输出。日志被截断、来源不明、标记仅为说明示例或格式改变时，分类不能用作验收结论；它也不判断当前启动状态、视频正确性或推理精度。

## 已验证效果与实际失败来源

本次共完成 17 项主机检查，包含两份技能入口格式校验。正常清单通过，内容篡改、缺失、重复、目录越界、盘符路径和空清单均被拒绝；真实驱动日志只被分类为驱动层成功，未被误写为 PL、DDR 或推理成功。检验在隔离文件样例和归档日志上完成，没有访问板卡。

完整性技能来自同名旧工程记录混用和换行符转换改变哈希的问题；日志技能来自“Linux 已启动”“驱动已加载”“模型已写入 DDR”被混为“整机已经推理”的问题。两项技能将这些具体失误沉淀为可重用的检查步骤，未给出未经测量的开发提效比例。

如需让支持 Codex Skills 的环境自动发现，可将选中的技能文件夹复制到本地技能目录，保留其 `SKILL.md` 与 `scripts/` 相对位置。`SKILL.md` 是该工具要求的固定入口名；目录和普通自有文件使用英文小写，`README.md` 用于目录说明。

这些技能不依赖 PYNQ，本工程未使用 PYNQ 作为运行框架。
