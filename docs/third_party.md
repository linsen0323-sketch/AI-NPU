# 第三方来源与授权材料

| 项目 | 用途 | 材料位置与状态 |
|---|---|---|
| YOLOX | NEU6 训练与 COCO 模型定义、导出依赖 | src/third_party/yolox 下保留实际来源快照及原始许可证，细节见 model_pipeline.md |
| ResNet / PyTorch / TorchVision | 分类模型训练与导出 | 实际代码与 checkpoint 来源见模型文档；应保留对应依赖授权 |
| AMD/Xilinx IP 与工具生成支持文件 | PS、AXI、时钟、视频接口及初始化 | 依赖 Vivado/Vitis 2025.2；保留已有文件声明，公共 IP 从合法工具安装中重建 |
| Linux / linux-xlnx | ARM Linux 内核与驱动构建 ABI | 精确版本、commit、配置及符号信息见 linux.md；通用内核源码由原来源获取 |
| NEU 数据集 | 分类/缺陷检测训练、校准与评估 | data/ 下保存使用方法与划分清单，原始数据按发布方条款获取和使用 |
| COCO 数据集与预训练权重 | COCO80 模型导入、校准与评估 | 数据与模型分别注明来源；本项目不把预训练导入表述为自行训练 |

项目作者拥有版权且未另行标注许可证的原创代码采用 MIT，完整条款见根目录 LICENSE，适用范围见 license.md。第三方源码、模型权重、数据集及工具生成文件分别遵循其原有授权；已有来源、版权声明和许可证予以保留。

