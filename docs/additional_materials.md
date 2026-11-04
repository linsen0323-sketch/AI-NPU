# 补充检索结果

## 范围

本次检查维护者已有的模型训练、量化、硬件工程和历史模型对照目录。文件名索引共77512项，随后定向检查量化生成、训练记录、系统构建与仿真证据。原机器位置仅保留在来源收据中，复现入口均为本仓库相对路径。

## 已补入

- 原YOLOX量化链追溯报告：evidence/models/quantization_trace.md。报告中找到的mixed_precision_ptq.py已在首次发布包收录，此次补充其来源证明，不另写量化器。
- ResNet选中训练checkpoint的原始元数据：data/metrics/training_resnet18/checkpoint_metadata.json。其224输入历史验证值不代替最终160精度。
- 四组当前DUT哈希相符的WBUF、DMA、舍入和MaxPool测试、参考模块及历史日志：sim/rtl/unit、evidence/sim/unit。
- YOLOv8n与YOLO12n历史选型实验：data/metrics/model_selection。它们不是最终部署模型，未混入额外checkpoint。
- 当前主机依赖快照与环境比较：data/environments/host。
- YOLOX量化源码身份核对：evidence/models/quantization_source_identity.json。

逐文件来源与SHA256见evidence/packaging/additional_files.json。生产RTL和最终三模型文件未被新搜索结果替换。

## 来源与采用边界

- 较早的10/31硬件归档，其README、资源/时序及SOURCE ONLY软件状态不代表最终npu100；未将其RTL、BSP、bit/XSA复制进生产文件。
- 检索到的display_fps boot.bif引用裸机fsbl/bit/elf，不能代替当前Linux BOOT.BIN构建链。
- Copy桥和时间戳旧候选与当前DUT哈希不一致，其PASS没有列为本版仿真证据。
- 当前pip快照是新采集的环境记录，不能回填成过去训练/量化时的锁定回执。

## 提交目录适配

发现硬件目录已移动到src/hardware，且全部原内容哈希仍一致。本次沿用该布局，修正重建入口、文档与逐文件目标路径；board/hardware产物目录及历史验证记录保持原义。适配记录见evidence/packaging/layout_sync.json。

