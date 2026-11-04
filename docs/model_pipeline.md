# 模型训练、量化与部署链路

本目录整理以最终 npu100 三模型 SD 清单及其 execution_manifest 为入口追溯。旧目录中的主机代码只在其源码哈希、输入包或派生链能与最终模型对应时收录。没有导入旧 PL 电路、旧 PS 工程、MobileViT 或其他实验模型。

## 三份实际部署配置

| PS选择ID | 任务 | 板端输入 | 最终模型文件 |
|---|---|---|---|
| 1 | ResNet18 NEU六分类 | INT8 NCHW 1x3x160x160 | data/models/runtime/bundle/models/m1/model.bin |
| 3 | YOLOX-S NEU六类检测 | INT32 Q16 NCHW 1x3x256x256 | data/models/runtime/bundle/models/m3/model.bin |
| 4 | YOLOX-S COCO八十类检测 | INT32 Q16 NCHW 1x3x256x256 | data/models/runtime/bundle/coco80/model.bin |

这是两种网络架构、三份模型配置。COCO选择ID4沿用检测计算图硬件family/wire ID3；它与PS菜单ID不是同一字段。

## 来源与命名

- `data/models/checkpoints/resnet18_neu6.pth`：本项目六分类训练checkpoint；原名resnet18_neu_best.pth。
- `data/models/checkpoints/yolox_s_neu6.pth`：PTQ provenance实际绑定的 `neu_seed2022_mosaic10_yolox_s/best_ckpt.pth`。没有用另一个no_mixup目录的best冒充。
- `data/models/checkpoints/yolox_s_coco80.pth`：已有COCO预训练权重，SHA256以f55ded7181e1开头；本项目导入、量化和部署，不能表述为本项目从零训练。NEU训练日志所用初始化文件yolox_s.pth与它逐字节相同，因此只收录一份。
- `data/models/onnx`：ResNet FP32/QDQ、NEU QDQ、COCO QDQ原件。NEU ONNX为640输入，ResNet ONNX为224输入；板端160/256来自后续整数图空间尺寸特化。COCO QDQ本身已为256输入。
- `data/models/quantization`：选中的量化策略、统计、量化参考权重、物理权重载荷及数值验证证据；没有复制候选搜索缓存和全部预测JSON。
- `data/models/intermediate`：最终模型派生链实际需要的冻结编译中间产物；它们不是待部署的第四套模型。
- `data/models/runtime/bundle`：最终SD加载包。内部m1/m3/coco80属于现有ABI约定，按原运行契约保留。

原件日期、源机器绝对路径和旧状态字段保留在历史provenance正文中；可执行入口按当前发布包相对路径解析。`evidence/packaging/models_files.json`逐文件记录原路径、现路径、用途、原/现SHA256和修改标志。

## 训练

主机依赖参考`src/host/requirements.txt`；原运行环境见`data/models/quantization/coco80/environment.json`。该JSON记录了当时的CUDA/PyTorch具体构建，不能把未锁定requirements当作已复现的二进制环境。先安装与机器匹配的PyTorch，再安装其余依赖。

ResNet：将原NEU分类集按`data/datasets/neu_cls/files.json`放置到`data/datasets/neu_cls/{train,val,test}/<class>/`。本次生成的是现有数据集文件指纹，不伪称训练时原始拆分收据。执行：

```powershell
python src/host/training/train_resnet18.py
```

训练仍使用原224尺寸流程；新checkpoint写到`work/training/resnet18`，不覆盖冻结checkpoint。

NEU检测：`data/datasets/neu_det`保留实际split_manifest和COCO标注；图像需另外获取。需要从原VOC XML整理时执行原转换器：

```powershell
python src/host/training/prepare_neu_det.py --src <neu-voc-directory> --dest <new-data-directory> --seed 2022 --accept-xml-labels
```

正式训练配置使用seed2022、640输入、100epochs、batch16、关闭MixUp及Mosaic1.0，与选中运行日志对应。为使工具能找到YOLOX源码，从项目根执行：

```powershell
$env:PYTHONPATH = (Resolve-Path src/third_party/yolox/neu6).Path
python src/third_party/yolox/neu6/tools/train.py -f src/host/training/yolox_neu6.py -b 16 -d 1 --fp16 -c data/models/checkpoints/yolox_s_coco80.pth
```

新输出写到`work/training`。旧日志保留在`data/metrics/training_neu6`。原数据加载器的随机种子行为限制应在报告中保留，不能承诺重训checkpoint逐字节相同。

## 量化与ONNX

`src/host/quantization/neu6`及`coco80`来自原PTQ数值核心和原256任务适配器。重命名和迁移只改文件查找、输出位置、源码溯源及CLI支持范围；没有另写量化器或改舍入规则。运行前需完整训练/校准/验证数据及CUDA环境：

```powershell
python build/scripts/models/run_quantization.py --model neu6
python build/scripts/models/run_quantization.py --model coco80
```

NEU输出位于`work/quantization/yolox_s_a`；COCO输出位于`work/quantization/coco80`。COCO数据默认放在`data/datasets/coco80`，也可设置`NPU_COCO_DATA`。校准采用原manifest的500张train2017图像、固定选取规则并与5000张val2017分离；原脚本可按来源URL下载校准JPEG。数据未齐时入口停止，不替换数据集。

ResNet原FP32导出、重定点参数生成、QDQ转描述符工具已收录。但**最初FP32到QDQ的量化生成器未找到**，因此该一步保留现有QDQ和参数原件并列为待补，不用新算法替代。

## 编译和硬件布局

`src/host/compiler/compiler.py`原始SHA256为`ca2312f9d99d2f59d9ea867472ccc9c02a2de6d106fd6114ab3db4f59e1e509f`，同时被NEU编译manifest与最终COCO编译报告绑定；当前副本做了相对路径适配，原/现哈希见复制清单。

- QDQ ONNX由现有compiler转为整数program及AIPKG3；这一步与PTQ不同。
- ResNet保留原LEGACY_R18 40位累加及72/73位重定点/残差语义，再进行统一图适配与160空间尺寸特化。
- NEU由冻结640整数图进行256尺寸特化、SiLU/Quant和Conv融合、PS控制预解码。
- COCO从独立256 QDQ重新编译，经相同控制预解码与WPK1布局。
- `pack_runtime_weights.py`仅追加WPK1权重排列副本，不能称为量化器。
- 最终`model.bin`为AIPKG3镜像加NPUPLN1计划；`weights_packed.bin`不是可直接加载DDR的完整模型包。

`plan_manifest.py`是离线派生工具使用的结构检查合同；`runtime_manifest.py`是最终Linux加载使用的严格三模型合同。两者分开命名，避免同名manifest导入到不同接口。

## 已实际执行的可移植重建验证

从发布包根目录执行：

```powershell
python -B build/scripts/models/verify_models.py
python -B build/scripts/models/rebuild_runtime_models.py --output <new-empty-directory>
```

第一条只核对文件、CRC、描述符、地址边界和模型身份。第二条从包内冻结中间输入和COCO QDQ构造三个DDR文件。整理过程中已经在发布包外的新空目录执行第二条，三个结果与最终SD包的model.bin全部逐字节一致，见`evidence/models/runtime_rebuild.json`。没有重新训练、量化、执行网络、运行RTL或访问硬件。

重建只证明冻结输入到最终模型包的文件构造闭环；不替代重训精度、整网Golden、时序及整机上板证据。最终Linux整机上板通过的状态按用户最新确认记录，实测原始材料由主工程证据目录承接。

## 部署与历史文档

将`data/models/runtime/bundle`复制为板端`/home/petalinux/npu100_models`，然后使用本发布包Linux部分的安装与启动说明。只复制模型不会安装驱动或启动推理。

原bundle说明文件README_CN.txt改为README.md，SHA256SUMS仅同步了这一文档路径。模型、输入、manifest.json/bin和固定协议文件内容未改。原生成manifest里的source_only_unverified等标志表示当时打包阶段的检查范围，未擅自回填为现在的上板结论。

## 第三方与数据

YOLOX两个本地源码快照分别对应NEU训练和COCO任务provenance，位于`src/third_party/yolox/{neu6,coco80}`，保留上游Apache-2.0许可证。第三方模型权重及NEU/COCO数据的再分发条件需结合原来源说明核对，不能由本项目许可证覆盖。完整数据集未复制；下载、授权和缺失说明见`docs/model_gaps.md`。

## 旧主机参考CLI的边界

`src/host/compiler/integer_runtime.py`保留整数参考库的Runtime及数学实现，旧直接运行CLI已停止使用。`src/host/compiler/host.py`只保留离线list/inspect可用；其历史prepare-input/run在CLI与函数入口均明确拒绝执行，避免用224/640预处理误生成最终160/256输入。最终摄像头预处理和后处理以本包Linux/PS运行时为准。
