# 模型链路待补材料

本页区分“当前材料缺口”和“系统功能未完成”。用户已确认最终Linux整机上板通过；以下缺口不否定该运行状态。

| 项目 | 当前已收录 | 仍需补充 |
|---|---|---|
| ResNet训练 | 实际checkpoint、原训练脚本、原FP32/QDQ ONNX，以及从checkpoint提取的epoch/seed/验证元数据 | 逐轮训练日志/曲线、训练时原始split生成脚本及收据（现有数据集指纹另存） |
| ResNet首次量化 | QDQ ONNX、原重定点CSV、原整数Golden、描述符导出器 | 首次FP32→QDQ量化脚本、校准选择及当时环境记录 |
| NEU训练 | seed2022实际配置/选中checkpoint/训练日志、真实split标注及manifest | 原始数据获取地址与许可证明；重训的完整环境锁定/安装包 |
| NEU量化与部署 | 原PTQ核心、策略与统计、640 QDQ、最终256派生包 | 对最终256部署配置的完整数据集精度表，不能用640结果替代 |
| ResNet160部署 | 完整字节匹配DDR模型与尺寸特化脚本 | 对最终160配置的分类精度统计，不能用224结果替代 |
| COCO模型 | 预训练checkpoint、500张校准manifest、5000张验证指纹、独立256 QDQ精度结果 | 预训练权重原下载来源/再分发说明，完整数据获取与存储说明 |
| 完整数据 | 拆分/校准manifest、标注及必要固定样本 | NEU分类/检测图像、COCO训练标注与val2017图像需按来源另行获取，未复制数据集 |
| 主机环境 | 原实测环境JSON、基础requirements、当前pip完整版本快照；关键库版本与原COCO256记录一致 | 可公开获取且与原CUDA/PyTorch构建匹配的安装源或镜像；当前快照不伪称历史训练锁定回执 |
| 最终板端模型精度 | 最终三模型二进制及所有哈希 | 原始输入、板端原始输出、Golden对比及精度统计，按最终相同模型身份归档 |

数据准备说明：

- NEU检测的`data/datasets/neu_det/split_manifest.json`与两个COCO标注文件来自最终训练所用NEU_PAPER80_CLEAN；按manifest恢复train2017/val2017图像并核对SHA256。原始VOC转换脚本含已知重复处理及XML标签显式确认开关。
- NEU分类按`data/datasets/neu_cls/files.json`恢复train/val/test及大小写敏感类别目录。该文件是整理时现有数据快照，不是历史训练时的收据。
- COCO数据放在`data/datasets/coco80/{annotations,val2017}`。`annotations`需含instances_train2017.json和instances_val2017.json；使用COCO官方数据获取渠道，依据保存的manifest/fingerprints核对。校准manifest正文保存每张train2017 JPEG的source_url；不拿val图做校准，不复用640统计。
- 本次保留历史软件精度结果；没有新训练、新量化、新模型评估或新上板测试。
