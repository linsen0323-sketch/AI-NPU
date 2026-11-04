# YOLOX-S 六类模型量化与编译流程追溯报告

调查日期：2026-10-29（Asia/Shanghai）。调查对象为 Zynq-7020 自定义统一 NPU 的 YOLOX-S 六类工业缺陷模型，目标是确定 COCO 80 类模型应复用的既有流程。

## 1. 明确结论

**原始量化流程已经找回，且已找到 Codex 当时新增量化器和执行转换的会话记录。无需重新开发量化器。**

真正完成浮点权重整数化的是：

- 工作脚本：[D:/AI/fpga_ai/tools/mixed_precision_ptq.py](D:/AI/fpga_ai/tools/mixed_precision_ptq.py:273)，核心函数为 `weight_quant()`，模型包装与偏置整数化在 `QuantOp`，整数权重落盘在 `export_package()`。
- 与正式产物一同归档的脚本快照：[D:/AI/fpga_ai/quantized/mixed_precision_20261019/scripts/mixed_precision_ptq.py](D:/AI/fpga_ai/quantized/mixed_precision_20261019/scripts/mixed_precision_ptq.py)。两份文件当前 SHA256 完全一致。

原始输入是 `neu_seed2022_mosaic10_yolox_s/best_ckpt.pth`，不是依据别的 YOLOX 实验目录推测出来的。原 checkpoint、配置、量化产物、编译清单和最终包内元数据能够相互对应；本轮还逐字节核对了整数权重及包内各区段。

**COCO 80 类的起点应为上述 PTQ 脚本的 `Task` 输入适配层，保留现有 observer、权重量化、舍入、bias 规则和导出方法，再依次复用 ONNX 导出器、整数图编译器和 AIPKG/NPUPLN1 工具。现有命令不能不加适配直接运行 80 类。** 六类数据、评估、输出维度和显示接口存在硬编码；需要适配配置与接口，并重新产生 COCO 自己的校准参数。不能复制六类的 scale 或把六类检测头改个名称就当作 COCO 模型。

本轮仅阅读、解析、计算哈希及生成本报告；没有执行任何原 PTQ/导出/打包脚本，没有重新量化、生成运行包、运行综合、连接或操作开发板。

## 2. 调查范围与证据来源

按“当前工程 → Git/归档 → Codex 会话 → 上游转换链路”的顺序调查：

1. 检查 `D:/AI_acceleration/FPGA_Projects/dual_display/acceleration` 中工具、模型清单、输入清单、部署文档和已有构建记录；确认当前 NPU 工具主要处理已经量化的模型。
2. `build_yolo320.py` 暴露上游 `D:/AI/fpga_ai/deployment/host_v1`；其 `compiler.py` 又指向 `D:/AI/fpga_ai/quantized/mixed_precision_20261019`，最终定位原 PTQ 源码和归档快照。
3. 检查本地 `C:/Users/ii/.codex/sessions/2026` 与 `C:/Users/ii/.codex/archived_sessions`。本地 JSONL 能找到后续优化操作，但该文件搜索没有直接找到 10 月 19 日原量化器创建记录。
4. 继续通过 Codex 应用的 `list_threads`、`list_archived_threads`、`read_thread` 读取历史，成功取回原量化和上位机部署任务。这里不是“无法访问历史会话”的情况，也没有把本地文件搜索无命中误判成历史不存在。

### 2.1 Git 调查结果

- `D:/AI_acceleration/FPGA_Projects`、`dual_display` 和 `D:/AI/fpga_ai` 当前不是 Git 工作树，`git rev-parse --show-toplevel` 返回 `not a git repository`。不能从这些目录取得原量化器的提交、分支或未跟踪状态。
- 上游训练项目 `C:/Users/ii/Desktop/YoloX-S-1` 有 Git 仓库：当前 `main` 和 `origin/main` 指向 `6ddff48`，提交标题为 `fix: typo in index.rst (#1804)`。检索 quant/PTQ/ONNX 等提交，只找到上游通用 ONNX 相关历史，没有找到本地 PTQ 工具的提交。
- 该训练项目本轮状态为 1 个已跟踪文件修改（`yolox/evaluators/coco_evaluator.py`）及 3618 个未跟踪文件；所用 `exps/example/custom/neu_seed2022_mosaic10_yolox_s.py` 是未跟踪文件。没有修改这些文件或 Git 索引。
- 因此，原量化代码的创建/执行证据来自会话记录和保存的源码校验，而非虚构的 Git 提交。

### 2.2 Codex 原始任务定位

应用中原聊天标题为 **“评估 Zynq-7020 AI 加速平台难度”**，聊天 ID：

`01a120fa-f105-7541-8225-aa200af69585`

通过 `read_thread` 分页读取，找到两个直接相关回合：

| 回合 | 时间（上海） | 原请求及证据 |
|---|---|---|
| `01a15345-b7eb-7973-89c2-b6c436c8c1dc` | 2026-10-19 16:27:20–16:51:06 | 用户要求先做另两个模型混合精度量化，并选择验证指标下降不超过 1 个百分点；记录包括 PTQ 脚本新增、YOLOX baseline/quantize、精度筛选、ONNX 导出与完成回复 |
| `01a15364-a4c1-7962-bd54-e997d5da95db` | 2026-10-19 17:01:07 开始 | 用户要求先做好上位机部分；记录包括新增 `host_v1/compiler.py`、`integer_runtime.py`、`package.py`，以及编译 YOLOX 整数图 |

可复查的历史操作标识：

| 操作 ID | 记录内容 |
|---|---|
| `exec-1a0f4a19-3a24-4ea7-9599-abe0a67b6273` | `fileChange`：新增 `D:/AI/fpga_ai/tools/mixed_precision_ptq.py`，状态 completed |
| `exec-5e391f03-4708-4f1e-ab5c-a8743aceab62` | `mixed_precision_ptq.py --model yolox_s_a --stage baseline`，exitCode=0 |
| `exec-071cc38c-0a49-4e91-89fb-f196b1608307` | 后续修正后的 `mixed_precision_ptq.py --model yolox_s_a --stage quantize`，exitCode=0 |
| `exec-e6ff0ad2-e3ac-4b1f-ab95-e907fe1d9fb6` | 新增 `refine_yolox_precision.py` |
| `exec-574a3988-7964-4e02-877b-7f7cd592ef85` | 新增 `export_mixed_precision_onnx.py` |
| `exec-3aa72eac-a874-489d-9679-e05ba50e1acc` | 执行 `refine_yolox_precision.py`，exitCode=0 |
| `exec-7880d50c-707a-47a6-afd9-d6b2cda9a1f8` | 执行 `export_mixed_precision_onnx.py --model yolox_s_a --samples 12`，exitCode=0 |
| `exec-cb506827-f65f-4f7e-9a6c-23f3a566cb98` | 新增 `D:/AI/fpga_ai/deployment/host_v1/compiler.py` |
| `exec-7854d856-e3ff-421b-b81d-d13a060aec55` | 执行 `host_v1/compiler.py --model yolox_s_a`，exitCode=0 |
| `exec-40c872a0-4127-4c31-87f5-4335c8690bc4` | 新增 `host_v1/package.py` |

历史中也存在失败和修正重跑；本表没有把最初失败的试验当作最终验收。当前归档中的 `archive_stride_sampling`、`optional_int4` 等目录必须与正式结果区分。

后续融合编译的本地记录位于：

`C:/Users/ii/.codex/sessions/2026/10/25/rollout-2026-10-25T18-52-42-01a172b0-f7a1-7500-ae6d-0496054cc0d2.jsonl`

其中第 2462 行记录新增 `compile_conv_fused_plan.py`，第 2496 行记录新增并执行 `verification/fusion_display_20261025/build_models.py`。原 PTQ 创建证据则是通过应用历史接口取得，不能用这个后续 JSONL 冒充原 PTQ 会话。

## 3. 原模型来源与当前身份核对

原 PyTorch checkpoint：

[C:/Users/ii/Desktop/YoloX-S-1/YOLOX_outputs/neu_seed2022_mosaic10_yolox_s/best_ckpt.pth](C:/Users/ii/Desktop/YoloX-S-1/YOLOX_outputs/neu_seed2022_mosaic10_yolox_s/best_ckpt.pth)

原配置：

[C:/Users/ii/Desktop/YoloX-S-1/exps/example/custom/neu_seed2022_mosaic10_yolox_s.py](C:/Users/ii/Desktop/YoloX-S-1/exps/example/custom/neu_seed2022_mosaic10_yolox_s.py)

证据为 PTQ `Task.__init__` 的实际加载路径、`provenance.json.source_files`、`model_manifest.json.original_checkpoint_sha256`、编译后 AIPKG 的 META 四处交叉对应。本轮重新计算：

| 文件 | 当前 SHA256 | 与保存记录比较 |
|---|---|---|
| `best_ckpt.pth` | `cf7ae18a0d0eed5847ceb0108b8562b3d6adbaebbe254017749bc2050d095f4c` | 一致 |
| `neu_seed2022_mosaic10_yolox_s.py` | `8e684a950f7200d7979babcbf40a92f697eaee9dfc6732d7d0e832dc2a99b819` | 一致 |
| `instances_val2017.json` | `cab22d0890bb58d2b2da2ebf786d64d7a90bfef5965423a5ecec99066792b41a` | 一致 |

六类顺序为 `crazing, inclusion, patches, pitted_surface, rolled-in_scale, scratches`。原数据集为 `C:/Users/ii/Desktop/YoloX-S-1/datasets/NEU_PAPER80_CLEAN`，保存记录为 1439 张 train、360 张 val。`NEU_PAPER80_CLEAN` 名称中的 80 不表示 COCO 80 类。

## 4. 完整转换链路

```text
原 best_ckpt.pth + 自定义 YOLOX exp + NEU train/val
  │
  ├─ mixed_precision_ptq.py
  │    加载 PyTorch 模型 → eval Conv/BN 折叠 → train 校准
  │    → per-channel W8/W4 整数化 → A8/A16 策略试验 → 验证门槛
  │
  ├─ refine_yolox_precision.py
  │    A16 敏感度策略筛选、W4 对照、最终精度优先 W8+A8/A16
  │
  │    保存 calibration.json / selected_policy.json / model_manifest.json
  │         weights_packed.bin / quantized_reference.pth / layer_precision.csv
  │
  ├─ export_mixed_precision_onnx.py
  │    读取已保存量化张量和策略 → 标准 Q/DQ ONNX，opset 21
  │    → model_mixed_qdq.onnx（640，输出 [1,8400,11]）
  │
  ├─ host_v1/compiler.py
  │    QDQ ONNX → AIGRAPH_INTEGER_V1，Q31 multiplier/shift、整数 LUT
  │    → program.json + parameters.npz
  │
  ├─ host_v1/package.py
  │    整数图/参数 → AIPKG3：model.aipkg（原 640 release）
  │
  ├─ unified_npu/tools/build_yolo320.py --size 256
  │    读取冻结 640 包 → 修改几何/解码网格及 stride 常量
  │    → 256 model.aipkg；不重新量化权重
  │    同时调用 compile_graph_plan.py --fuse-silu（performance profile）
  │
  ├─ compile_conv_fused_plan.py
  │    使用 performance/yolox_s_a_256 → Conv/SiLU/Quant 融合计划
  │    → verification/fusion_display_20261025/fused_source/yolox_s_a_256
  │
  └─ verification/fusion_display_20261025/build_models.py
       调用 prepare_predecoded_control.prepare_model(..., coalesce_inner=True)
       → models/fusion_display_20261025/yolox_s_a_256/
          model.aipkg + execution_plan.bin + ddr.bin + input.bin
          execution_manifest.json + model_config.tcl + model_config.h
```

`weights_packed.bin` 并非直接拼到最终 `ddr.bin`：正式上位机链路通过量化参考包导出 QDQ ONNX，编译器读取 ONNX 中的整数权重初始化器与 scale，重新组织为 `parameters.npz`，然后由 `package.py` 序列化。`weights_packed.bin` 是同一整数权重的独立导出与核对证据。

`host_v1/run_all.ps1` 是上位机整数编译、打包、验证和发布的编排入口，并不执行最前面的 PTQ 校准；直接运行它不能完成一个新的浮点 COCO checkpoint 的量化。

## 5. 量化和定点参数如何生成

### 5.1 原始浮点权重整数化

[mixed_precision_ptq.py:273](D:/AI/fpga_ai/tools/mixed_precision_ptq.py:273) 的 `weight_quant(w, bits)`：

- Conv 权重按输出通道展开，取每通道绝对最大值。
- W8 的 `qmax=127`，裁剪比例候选为 `1.0、0.99、0.98`；各输出通道独立按重建 MSE 选 scale。
- `sw[channel] = max_abs[channel] × chosen_ratio / qmax`。
- `qw = clamp(round(w/sw), -qmax, qmax)`，保存 `torch.int8`；零点为 0，舍入为最近偶数（ties-to-even）。
- W4 也有真实量化及双半字节打包，但正式六类发布全部 W8；不能把 optional INT4 对照当成板端正式模型。

Conv/BN 在校准前以 eval 模式折叠。原记录为 YOLOX 折叠 74 对，保存 `bn_fold_parity.json`。因此部署整数权重来自折叠后的参数，不是直接对训练 checkpoint 原始 Conv 张量逐项取整。

### 5.2 激活校准与位宽

[mixed_precision_ptq.py:236](D:/AI/fpga_ai/tools/mixed_precision_ptq.py:236) 的 `Observer` 观测各 Conv/Linear 的输入：

- 固定 seed `20261019`，每个调用对扁平激活用 `torch.randint` 随机采样最多 8192 个值，记录完整张量的最大绝对值；汇总后最多保留约 262144 个采样值。
- A8 候选阈值为 max，以及 0.999、0.9995、0.9999 绝对值分位数；后者不小于 max 的 25%。按采样重建 MSE 选择阈值，`sx = threshold/127`。
- A16 使用 max 范围，`sx = max/32767`。
- 均为 per-tensor 对称有符号窄范围，zero_point=0；越界 clamp；`torch.round` 最近偶数舍入。
- 校准和策略选择是两步：train 决定统计范围；完整 val 比较候选策略的 mAP。`refine_yolox_precision.py` 比较 predictors/head/sensitive_quarter 等 A16 配置，并保存可选 W4 试验。

保存的正式 `selected_policy.json` 标签是 `accuracy_first_w8_mixed_a8_a16`，逐层 policy 与 `candidates.json` 的 `mixed_a16_sensitive_quarter` 一致：83 个卷积中 63 个 W8A8、20 个 W8A16。不要将这个六类验证结果直接作为 COCO 的位宽选择结论。

### 5.3 bias、scale、舍入与重定点

PTQ 偏置规则是 `qb = round(bias_fp32 / (sx × sw[channel]))`，要求不超过 INT32，不能静默饱和。量化参考 Conv 使用量化反量化后的浮点值执行 FP32 卷积；这一步本身不是完整整数运行时。

[host_v1/compiler.py:28](D:/AI/fpga_ai/deployment/host_v1/compiler.py:28) 才把 QDQ scale 变成整数执行所需的 Q31 参数：

1. `frexp(real) → mantissa, exponent`。
2. `m = rint(mantissa × 2^31)`，处理取整到 `2^31` 的边界。
3. `shift = 31 - exponent`，要求 0–62。
4. Q16 输入到 A8/A16 的 QUANT 使用 `real = 1/(sx × 65536)`。
5. Conv 累加结果到 Q16 使用每输出通道 `real = sx × sw × 65536`；保存 `requant_m`、`requant_s` INT32 数组，并将 ONNX bias 重新取整到累加尺度。

[integer_runtime.py:21](D:/AI/fpga_ai/deployment/host_v1/integer_runtime.py:21) 的 `rdiv/rshift/requant` 定义有符号最近偶数整数舍入。`program.json` 的 QUANT attrs 保存标量 multiplier/shift；卷积 attrs 指向 `parameters.npz` 中逐通道 multiplier/shift。最终这些整数参数进入 AIPKG 的 CONSTANTS 和属性记录，再进入 NPUPLN1 计划引用。

运行图采用混合整数表示：卷积输入 INT8/INT16，一般连接算子 INT32 Q16，检测 exp/decode 使用 INT64 Q16；并不是整图所有数据都为 INT8。compiler 在离线用 `np.rint` 生成 sigmoid/exp/softmax LUT；原 SiLU 的 Sigmoid+Mul 结构随后可做等价融合。NMS 在图外，由主机/PS 完成。

## 6. 校准数据和参数保存位置

正式量化结果目录：

[D:/AI/fpga_ai/quantized/mixed_precision_20261019/yolox_s_a](D:/AI/fpga_ai/quantized/mixed_precision_20261019/yolox_s_a)

| 文件或目录 | 保存内容 |
|---|---|
| `provenance.json` | 原 checkpoint/config/val 标注路径和 SHA256、seed、预处理、类别、train/val 数量、96 张校准样本的实际路径与顺序 |
| `calibration.json` | 83 层输入激活的 max、采样数量、A8/A16 scale、clip、MSE |
| `dataset_fingerprints.json` | 原 train/val 图片哈希与跨 split 精确重复检查记录 |
| `selected_policy.json` / `layer_precision.csv` | 最终每层权重/激活位宽、scale 与权重区间信息 |
| `model_manifest.json` | 每层整数权重偏移/形状、per-channel scales、INT32 bias、累加器范围需求、输入预处理、原权重哈希和数值合同 |
| `quantized_reference.pth` | 量化算子整数张量和尺度，以及复现所需 reference_state；不是原始训练 checkpoint，也不是紧凑板端模型包 |
| `weights_packed.bin` | 64 字节对齐、按清单排列的整数权重载荷，正式版本 8,916,480 字节 |
| `model_mixed_qdq.onnx` | 携带整数权重、激活/权重 scale 和 Q/DQ 结构的中间模型 |
| `candidates.json`、`weight_sensitivity.json` | 策略选择过程和评估依据 |
| `golden_sample_*.npz` / `integer_tile_goldens` | QDQ/ORT 输入输出样例，以及少量算子整数点积样例；与后续整图整数 Golden 区分 |
| `onnx_verification.json` / `release_acceptance.json` | 已保存 ONNX 的结构和任务指标验证记录 |

校准图像仍在原 `NEU_PAPER80_CLEAN/train2017`，没有发现独立复制出的“校准图片目录”。96 张是 6 类各 16 张，只从 train 抽取；本轮验证这 96 张均存在，且全部与 `dataset_fingerprints.json` 的 SHA256 一致。`input.bin` 对应的 `val2017/scratches_105.jpg` 是部署示例输入，不能当作整套校准数据。

observer 的原始随机采样张量没有作为独立样本缓冲文件找到；保存的是统计结果和输入样本身份。重新校准可以复用算法与样本选取逻辑，不能声称有一份保存了所有原始激活的校准缓存。

脚本快照、旧环境记录和校验和在父目录：

- [scripts](D:/AI/fpga_ai/quantized/mixed_precision_20261019/scripts)
- [environment.json](D:/AI/fpga_ai/quantized/mixed_precision_20261019/environment.json)
- [checksums.json](D:/AI/fpga_ai/quantized/mixed_precision_20261019/checksums.json)
- [原量化报告](D:/AI/fpga_ai/quantized/mixed_precision_20261019/量化报告.md)

`refine_yolox_precision.py` 的归档快照存在，是应复用的完整流程组成部分；只找主 PTQ 脚本而漏掉此策略筛选环节，不能复原原来精度优先的正式选择。

## 7. 哪个工具生成哪些产物

| 工具及当前路径 | 真实职责 | 是否浮点量化器 |
|---|---|---|
| `D:/AI/fpga_ai/tools/mixed_precision_ptq.py` | BN 折叠、激活统计、W4/W8 整数化、A8/A16 候选及参数/权重导出 | **是，原 PTQ 核心** |
| `D:/AI/fpga_ai/quantized/mixed_precision_20261019/scripts/refine_yolox_precision.py` | 用同一量化核心做 YOLOX 策略筛选、保存 W4 对照和精度优先结果 | 策略编排，调用原量化实现 |
| `D:/AI/fpga_ai/tools/export_mixed_precision_onnx.py` | 读取已量化张量/策略，生成 QDQ ONNX；不做新的校准或位宽搜索 | 否 |
| `D:/AI/fpga_ai/tools/validate_mixed_onnx.py` | 对保存 ONNX 做完整 val 指标验证 | 否 |
| `D:/AI/fpga_ai/deployment/host_v1/compiler.py` | QDQ ONNX 算子转换、固定点参数/LUT 生成，输出 `program.json`、`parameters.npz` | 整数图编译器；不是原权重 PTQ 器 |
| `D:/AI/fpga_ai/deployment/host_v1/package.py` | 编码 META/TENSORS/INSTRUCTIONS/ATTRIBUTES/CONSTANTS、工作区分配和 CRC，生成原 `model.aipkg` | 否，打包器 |
| `D:/AI/fpga_ai/deployment/host_v1/integer_runtime.py` | AIGRAPH_INTEGER_V1 整数 Golden 执行 | 否 |
| `D:/AI/fpga_ai/deployment/host_v1/validate_integer.py` | 从最终包恢复并验证整网整数结果 | 否 |
| `D:/AI_acceleration/FPGA_Projects/dual_display/acceleration/unified_npu/tools/build_yolo320.py` | 冻结 640 模型尺寸专化；名字虽为 320，也支持 `--size 256`；生成派生包和输入，调用计划编译 | 否 |
| 同一 `tools` 目录的 `compile_graph_plan.py` | AIPKG3 → NPUPLN1；生成 `execution_plan.bin`，将包+对齐填充+计划组成 `ddr.bin`，生成配置和输入副本 | 否 |
| `compile_optimized_plan.py` | 精确 SiLU/可选 Quant 融合，复用基础 lowerer 和写出逻辑 | 否 |
| `compile_conv_fused_plan.py` | 增加精确 Conv→SiLU/Quant 融合；当前 fusion profile 用此编译 | 否 |
| `prepare_predecoded_control.py` | NPUPRE1 描述、AFF1 迭代信息预解码与合并；更新包/计划/DDR/配置校验 | 否 |
| `D:/AI_acceleration/FPGA_Projects/dual_display/acceleration/verification/fusion_display_20261025/build_models.py` | 调用预解码工具，生成用户指定的最终 fusion profile | 否，批次构建入口 |
| `unified_npu/tools/pack_runtime_weights.py` | WPK1 权重重排；为 3×3 生成 `[OC][ceil(IC/8)][9][8]` 附加副本并改写运行计划 | **否；不进行浮点到整数转换** |

用户指定 fusion 包 `plan_feature_bits=7`，包含 SiLU、预解码、Conv 融合；WPK1 工具使用 feature bit3，值为 8。**当前指定包没有启用 WPK1；不能把后续权重重排工具认作它最初的量化来源。**

## 8. ONNX 导出器与中间格式

确实存在专门的 [export_mixed_precision_onnx.py](D:/AI/fpga_ai/tools/export_mixed_precision_onnx.py:71)。它恢复已保存 `quantized_reference.pth`，以自定义 symbolic 输出 `QuantizeLinear/DequantizeLinear`，权重 DQ 为输出通道 axis=0，激活使用标量 scale；A16 需要 opset 21。源码先以 legacy tracer 的 opset 20 导出，再将模型声明更新为 21，并运行 ONNX checker 和 ORT 样例比较。

不是“从一个浮点 ONNX 调用某个未知量化库”的路径，也没有证据表明此自定义 NPU 流程使用 AMD Quark、Vitis AI quantizer、TensorRT 或标准 ORT 静态量化 API 完成 PTQ。这里实际使用的是保存下来的自定义 PyTorch/NumPy PTQ 实现。

中间格式依次为：

1. `NEU_PTQ_REFERENCE_V1` 清单、`quantized_reference.pth` 与整数权重载荷。
2. 标准 QDQ ONNX：`model_mixed_qdq.onnx`。
3. `AIGRAPH_INTEGER_V1`：`program.json` + `parameters.npz`。
4. `AIPKG3`：可重定位模型包。
5. `NPUPLN1` 执行计划；生产派生再包含 `NPUPRE1/AFF1` 信息。

## 9. 本轮只读核对结果

### 9.1 参数与来源核对

- PTQ 父目录 `checksums.json` 的 **18 项全部匹配当前文件**，包含正式 YOLOX 量化 ONNX、整数权重、清单、策略及脚本快照。
- 工作 `mixed_precision_ptq.py` SHA256：`d6b0226bdbe7686a6a2de27a8e69a23f3713327572794824870bed0a3e96c7ac`，与归档快照相同。
- 工作 `export_mixed_precision_onnx.py` SHA256：`297333266537f2bf64add9cadb5932dac01a3a9a76bff7f31505780857a82a04`，与归档快照相同。
- `host_v1/artifacts/yolox_s_a/compile_manifest.json` 绑定的全部源码及输入文件哈希均匹配；`integer_acceptance.json` 绑定的输入哈希也匹配。
- 读取 `weights_packed.bin` 和每层清单，核对其 83 组权重的形状和原始整数字节：与 640 AIPKG 的 83 个 CONV 权重形成完全相同的多重集合。这个核对证明权重集合对应，不冒充新做的整图数值推理。
- `parameters.npz` 全部 338 个参数与 640 AIPKG CONSTANTS 中对应数组字节相同。
- 640→256 共有 **335 个参数数组的 dtype、shape、内容保持一致**；只有 `p0332_constant`、`p0333_constant`、`p0334_constant` 的解码网格/stride 数组变化。不能比较分配 offset 来判断数值变化，因为后续 LUT 的打包 offset 会随前面数组尺寸变化而移动。
- performance 256 包与最终 fusion 256 包的五个内容区 META/TENSORS/INSTRUCTIONS/ATTRIBUTES/CONSTANTS **全部逐字节相同**；包总哈希变化来自预解码描述及其相关校验字节。
- 最终 `ddr.bin` 的包前缀与 `model.aipkg` 完全相同；在 plan_offset 处切出的计划与 `execution_plan.bin` 完全相同。

### 9.2 关键文件身份

| 产物 | 字节数 | 当前 SHA256 |
|---|---:|---|
| PTQ `weights_packed.bin` | 8,916,480 | `04a2896d28f0dfc45df41624e2d76de4f0331fd8d1c7ad082b357f45a78a9ea5` |
| PTQ `model_mixed_qdq.onnx` | 9,384,257 | `fb01d96c081215c515d847b7723d29ca521dbece36fd77023fff15bc460b38d9` |
| host_v1 640 `model.aipkg` | 9,703,424 | `a2ecbf2cd72a1360bff172686674d6957c8233407b5dec1eecf2ca20502a1cc0` |
| performance 256 `model.aipkg` | 9,588,736 | `1e7e522b891c6365753d343f09f367e8f5300aad3befaf6e371f1902f74fd813` |
| fusion 256 `model.aipkg` | 9,588,736 | `7e266f6dd4141d7ecc9f368f8331bdababf81fe92814db9b17a878b503a92477` |
| fusion `execution_plan.bin` | 147,456 | `5959b76ad69cf6241a032ad7ca5f2bd2a24558862f0c3e373c3b0164dc011fe5` |
| fusion `ddr.bin` | 9,736,192 | `f63b4cbfc16e72031392a61b1c14f08a32b911b183a8f59c0d7ae7ae67d4a99a` |
| fusion `input.bin` | 786,432 | `6a8985b572b98669907ea2e7c66538d124e67a40fc21ac5f977755167b5eed53` |

本表 PTQ 路径为第 6 节目录；host_v1 包在 `D:/AI/fpga_ai/deployment/host_v1/artifacts/yolox_s_a/model.aipkg`；performance/fusion 包在 `D:/AI_acceleration/FPGA_Projects/dual_display/acceleration/unified_npu/models` 对应子目录。

当前 fusion 清单记录输入 `[1,3,256,256]`、INT32 Q16；输出 `[1,1344,11]`、INT64 Q16；原图 368 操作、执行计划 270 records；plan_offset=9,588,736；工作区 8,126,464 字节。上述数值来自本轮读取的生成物，不是运行速度或板端实测结论。

### 9.3 旧精度验证的适用边界

保存的原 QDQ ONNX 640 验证约为 mAP50=79.4595%、mAP50–95=44.8130%。后续 640 整数 AIPKG 的 `integer_val_metrics.json` 为 mAP50=79.7157684%、mAP50–95=44.9886755%，360 张 val；`integer_acceptance.json` 记录从二进制包执行、预处理逐张一致、通过 1pp 预算。

这两套指标对应不同的数值参考阶段，不能混写。旧 640 软件整网精度也不能自动证明缩小到 256 后的精度或 COCO 80 类精度。最终 fusion 清单仍有 `accuracy_validated=false`、`integer_reference_executed=false` 等构建状态字段；本轮没有执行新的 Golden 比较，也未核验后续板测状态。

## 10. COCO 80 类的复用与适配边界

| 环节 | 可复用部分 | 必须适配或重新确认 |
|---|---|---|
| PyTorch 模型加载 | 原 YOLOX exp/get_model/load_state_dict 流程 | `Task` 固定 NEU exp、checkpoint 和输出目录；需提供真正 80 类 YOLOX-S checkpoint 与匹配配置，不能加载到六类 head |
| 数据与校准 | observer、量化公式、seed 和记录机制 | 改为 COCO 图片/标注及独立输出；现有采样按单个 `label` 分组，取每图第一个标注类别；对多标签/无标注图片不通用，固定 n=96 再按 80 类整除也不再意味着得到原设计的 96 张代表性样本 |
| 精度策略 | W8+A8/A16、敏感度排序及完整 val 筛选方法 | 重新生成 COCO 范围和位宽策略，不能沿用六类 20 层 A16 清单或六类 metrics 缓存 |
| ONNX 导出 | ActivationQDQ、WeightDQ、opset21 和已量化权重导出 | `q.Task`、模型名字和路径绑定需适配；输出应为 `5+80=85`，并核查实际导出算子、静态尺寸及解码行为 |
| 整数算子转换器 | `compiler.py` 的 Conv、QDQ、SiLU 分解、Resize/Concat/Reshape、Q31/LUT 等 | 构造器/CLI/目录绑定 `yolox_s_a`；标准同结构 YOLOX-S 类别变化主要改变张量形状，从源码看不必预先重写算子实现，但须对实际 COCO 图逐项核对，遇到新算子或变体再适配 |
| 检测头 | 三尺度 YOLOX-S 的计算结构和现有 Conv 后端 | cls_preds 每尺度输出由 6 变 80，需使用新权重并重建图形状、切片/reshape 和所有计划；不能只改类别字符串 |
| 尺寸专化 | `build_yolo320.py` 的静态形状传播、网格/stride 生成 | 第 108 行硬编码输出最后维 11；还依赖原图常量名 `p0332/333/334`、冻结 640 源、3 个解码常量和旧模型路径，不能原样宣称支持 80 类 |
| 包与执行计划 | AIPKG3、NPUPLN1、融合与预解码框架 | 根据新图重算 workspace、偏移、shape、校验、计划和模型目录；验证累加/乘积范围及硬件支持，不能套旧地址和包身份 |
| 主机后处理 | `host_v1/host.py` 使用 `pred[:,5:].max(1)` 和 `program['classes']`，类别维处理较通用 | 配置、元数据和验证路径需要新模型；PTQ 的 `Task.evaluate` 明确 `postprocess(...,6,...)` 必须改为模型类别数；COCO category_id 映射与类名须来自标注，不能假设连续数据集 ID |
| 板端 PS 后处理 | class-aware NMS 算法和坐标还原流程 | `dual_display_app/src/ai_camera_math.c:165` 遍历 6 类，284 行每预测步长 `11u`，203 行 `overlay_class[6]`；均需适配 80 类 |
| 摄像头 catalog | 由包清单生成参数的方法 | `generate_camera_catalog.py:113` 要求 output_bytes=`predictions*11*8`；需改为实际输出契约，并更新 model/config/catalog 身份 |
| HDMI 显示 | 框绘制、分数和帧匹配流程 | `ai_preprocess_top.sv:296` 仅接收类别 `w_data[2:0]`；`ai_result_overlay.sv:19` 类别输入也是 3 位，类名字形/颜色仅定义 6 类。完整 80 类显示需要至少 7 位类别与相应协议/标签支持；不能声称只换包即可保持完整 COCO 标签显示 |

若保持 256 输入、INT64 Q16 解码输出，输出将由 `[1,1344,11]` 的 118,272 字节变为 `[1,1344,85]` 的 **913,920 字节**。这是按现有表示计算的尺寸，不是已生成 COCO 包的实测结果；实际 allocator 必须重新运行和验证。

**判断：量化数值核心和编译/打包框架可复用；数据/模型配置、shape 契约和后处理必须适配。是否需要新增算子不能仅凭“80 类”判定；应以实际导出图为准。现有六类显示协议确有容量不足，属于明确要处理的接口限制。**

## 11. 已找回、尚缺与下一步入口

已找回：原 checkpoint 与 exp 身份、原 PTQ 代码和可校验快照、校准样本清单及统计、逐层 scale/bias/位宽、YOLOX 策略筛选器、专门 QDQ ONNX 导出器、整数图编译器、整数 Golden、AIPKG 打包器、NPUPLN1 编译器，以及当前 fusion 包的派生构建入口；同时找到了 Codex 原创建/执行记录。

尚未在本轮建立的内容：

- 一个已经配置好并验证通过的 COCO 80 类端到端转换入口和运行包。
- 这次新增模型将使用的 COCO YOLOX-S `.pth`、exp、数据路径和期望输入分辨率；本报告没有把其它 YOLO 架构的 COCO 权重认作 YOLOX-S 权重。
- 原 observer 随机抽出的全部激活张量缓存；已有的是统计和图片身份。
- 量化器的 Git 提交历史；相应目录无 Git 元数据。不过这不影响已由会话和哈希确认的代码来源。
- 在新 COCO 权重上执行过的算子兼容性、整数范围、精度、运行时内存和板端显示验收。

下一轮应从 **`D:/AI/fpga_ai/tools/mixed_precision_ptq.py` 的 `Task`（第 79 行）开始做 COCO 输入配置适配，保留第 236/273/291 行的校准和整数化核心**；以归档 `scripts` 快照和当前核对过的数值合同为基准。在独立新输出目录完成新模型校准与策略评估后，沿用 `export_mixed_precision_onnx.py → host_v1/compiler.py → package.py → compile_graph_plan.py`，再按目标硬件需要使用融合和预解码步骤。

本轮没有执行上述下一步。不要直接启动旧脚本现成命令：其输出目录、数据、模型和 calibration/metrics 缓存都绑定旧六类项目。找到原流程的结论是确定的；“COCO 80 类可原样一键生成并在当前六类显示系统运行”的结论不成立。
