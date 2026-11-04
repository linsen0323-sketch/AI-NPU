# 许可与协作公开范围核对

本文件只记录现有文件内容与需要维护者决定的发布事项，不替项目维护者选择许可证。

## 许可证事实

- 根目录license.md目前是授权状态说明，尚未授予项目自有代码的再分发许可，也未确定版权主体与署名。维护者需要明确许可证及其适用范围；本核对不代为选择许可。
- src/software/runtime/linux/driver/unified_npu.c 第一行是 `SPDX-License-Identifier: GPL-2.0-only`，并含 `MODULE_LICENSE("GPL")`。根目录未来的许可说明不应抹掉这一已有文件级标识。
- board/hardware/ps7_init.c 首部带 Xilinx 版权及 MIT SPDX；ps7_init_gpl.c 首部是 Xilinx 版权及 GPL v2-or-later 文字。二者不是同一种授权，保留原文件声明。
- src/third_party/yolox/neu6/license 和 coco80/license 保留 Apache-2.0 全文。第三方来源应给出处与快照身份，不用项目根目录说明覆盖原归属。
- board/linux/userspace/python_packages.json 给出 Ubuntu ports 包来源、版本、下载地址及 SHA256。归档内含上游版权文件的事实已有原材料描述，最终打包时继续保留，不把私有运行环境误写为本队自研解释器。
- data/ 中 NEU/COCO 标注、样例图像、模型权重的独立来源与授权范围尚待维护者确认；公开数据存在不自动代表可由本项目任意再许可。

## 协作公开范围

完整原始对话及其导出元数据不随公开仓库分发，由维护者保留。公开入口为 [report/collaboration/README.md](../report/collaboration/README.md)。

- `public_excerpts.jsonl`：从54条历史用户/助手可见记录中选取15条与本项目有关的真实消息；本机绝对路径用可见替换标记处理。
- `public_excerpts_metadata.json`：保留来源文件SHA256、角色、时间、原行号和替换计数，支持追溯；摘录不包含系统/开发者指令、内部推理、工具参数/结果或其他会话。
- `collaboration_record.md`：整理提示词、回答摘要、失败、自我纠错和Ross使用过程。摘要与逐字摘录分别标注；Ross历史过程摘要不作为本版综合、时序或板测证明。
- `privacy_review.json`：记录公开摘录的角色/元数据核对与凭据模式检查。模式未命中只说明未发现这些已知格式，不是全面隐私保证。

原始归档的独立模式扫描未发现私钥头、GitHub token格式、带凭据URL、邮箱或IPv4，但检出了本机Windows路径和会话UUID。该扫描只输出类别计数，不公开匹配值；公开摘录另按任务相关性和可追溯原则制作。

保留必要的失败与纠错内容，不把摘要标成逐字对话，不把历史助手声称“通过”当作最终验收证据。`tools/export_collaboration.py` 是辅助导出工具，其规则只覆盖可识别模式，新增公开记录仍需逐条审阅。
