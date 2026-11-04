# 历史模型选型与对照资料

本目录收录作者指定模型目录中已有的YOLOv8n对照实验及YOLO12n训练/测试曲线，用于报告中的选型背景和研发过程，不加入NPU最终三模型清单。

- `yolov8n/{baseline,scale03,mosaic05}`：同一对照脚本的seed42实验，原配置为416输入，100轮、batch16；完整参数以各arguments.yaml为准。
- `yolo12n/baseline`：原100轮训练记录及曲线。
- `yolo12n/test`：原独立测试逐类指标、PR/F1曲线及归一化混淆矩阵。
- 原训练方法和数据配置在 `evidence/models/model_selection/` 归档；其中源机器路径仅作为历史参数记录。

这些记录使用的数据划分、模型、精度格式、推理设备和输入尺寸不同，不能据此直接给当前160/256 NPU配置作同条件性能或精度排名。YOLOX-S最终来源仍按 `docs/model_pipeline.md` 的checkpoint与provenance确定。

