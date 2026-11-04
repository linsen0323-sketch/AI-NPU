# AIPKG3：三模型软件/硬件部署合同 v1

本文件冻结主机编译输出的数值规则和 DDR 格式，供后续统一电路设计使用。它不声称现有比特流支持新格式。`aipkg3_abi.h` 提供 C 字段定义；`package.py` 是已运行验证的编码器/解码器；`integer_runtime.py` 是 profile 2 数值参考。

## 1. 两种执行 profile，共用一个外层格式

| 模型 ID | 模型 | Profile | 输出 |
|---:|---|---:|---|
| 1 | 原 ResNet18 | 1：保留旧 R18 ABI1 | 6 个 INT8 logit |
| 2 | MobileViT-XXS | 2：INTEGER_GRAPH | `[1,6]` INT32 Q16 logit |
| 3 | YOLOX-S A | 2：INTEGER_GRAPH | `[1,8400,11]` INT64 Q16，已完成 xywh 解码与 sigmoid |

外层包统一不等于旧 ResNet 和新图的算子编码相同。Profile 1 保留旧 48 条描述符和打包权重，不能按 profile 2 的 opcode 解读。后续统一硬件需要 profile 前端分派/转换，并可复用计算与 DMA 后端。旧 ResNet 的 40-bit 累加、宽重定标、Add 系数和 -128 饱和边界保持原协议，未为了统一格式重新量化。

## 2. 文件头与分区

所有整数、张量和结构均为 little endian。模型不绑定物理 DDR 地址。包首地址及独立工作区地址由加载器指定，均要求 4096 字节对齐。

| 字节偏移 | 字段 | 类型/值 |
|---:|---|---|
| 0 | magic | 8 bytes：`AIPKG3\0\0` |
| 8 | version | U32，3 |
| 12 | header_bytes | U32，256 |
| 16 / 20 | model_id / engine_profile | U32 |
| 24 / 28 | section_count / directory_crc32 | U32 |
| 32 / 40 | image_bytes / workspace_bytes | U64 |
| 48 / 52 | input_tensor_id / output_tensor_id | U32；profile 1 为 0xFFFFFFFF |
| 56 | header_crc32 | U32；计算时此字段置 0，覆盖 256 字节头 |
| 60 | flags | U32，当前为 0 |
| 64 | body_crc32 | U32，覆盖文件从 256 字节至末尾，包括填充 |
| 68 | input_lut_tensor_id | U32；MobileViT U8→Q16 查表 ID，否则 0xFFFFFFFF |
| 72..255 | reserved | 0 |

目录从文件偏移 256 开始，每条 64 字节：16 字节 ASCII 名称、U64 文件偏移、U64 长度、U32 CRC、U32 alignment、24 字节保留。各 section 起始 4096 对齐。所有 section 的 CRC、头 CRC、目录 CRC 和 body CRC 必须通过。当前目录：

- Profile 2：`META`、`TENSORS`、`INSTRUCTIONS`、`ATTRIBUTES`、`CONSTANTS`。
- Profile 1：`META`、`LEGACY_IMAGE`。后者逐字节等于原 `generated/ddr.bin`。

`META` 是供主机审计、名称/类别/预处理与验证使用的 JSON；算子参数与指令另有完整二进制表示。执行参数 `CONSTANTS` 中无浮点 tensor。原始尺度可在之前量化文件中审计，运行时重定标使用包内整数 multiplier/shift。

## 3. Profile 2 张量记录

每条 128 字节，32 个 U32。

| word | 意义 |
|---:|---|
| 0 | tensor ID |
| 1 | constant 标志：1=CONSTANTS，0=工作区 |
| 2 / 3 | dtype（I8=1/I16=2/I32=3/I64=4） / fractional_bits |
| 4 / 5 | rank（≤8） / section selector（常量=1，工作区=0） |
| 6..7 | 字节偏移 U64，分别相对于 CONSTANTS 或 workspace_base |
| 8..9 | 有效字节数 U64 |
| 10..11 | first_op / last_op，输入 first_op=-1 编码为 0xFFFFFFFF |
| 12..19 | 最多八维 shape，不使用维度置 0 |
| 20 | alignment=64 |
| 21..31 | 保留 0 |

常量张量按完整顺序存储；Conv 权重 OIHW，Linear 权重 OC×IC。动态 reshape/transpose 在语义上有独立目的张量；当前工作区计划采用保守复制语义，不假定硬件支持零拷贝。不同生命期的张量可复用地址，同一操作正在读写的张量不会重叠。运行时只允许一个任务使用这份共享工作区。

## 4. 指令与属性

每条指令 128 字节：word 0=opcode、1=flags(0)、2/3=输入/输出个数，word 4..7=输入 ID，8..11=输出 ID，12/13=ATTRIBUTES 字节偏移/长度，14=首输出元素数，15..31=0。未用 ID 填 0xFFFFFFFF，最多四个输入/四个输出。

属性区按字段 ID 升序存放 16 字节 TLV：`U32 field_id, U16 kind, U16 count, I64 payload`。kind=1 是有符号标量，kind=2 是常量 tensor ID，kind=3 是 I64 向量，payload 是该向量在整个 ATTRIBUTES 内的偏移。TLV 之后紧接向量数据，首个向量偏移界定 TLV 表末端；整段长度由指令给出。纯标量属性没有尾部向量。

Opcode 和属性 ID 均见 C 头文件，不随模型重新编号。Conv/Linear 使用 `weight/bias/multiplier/shift` 四个参数 tensor。其余属性记录 stride/pad、axis、shape、slice、分块长度等；LayerNorm gamma/beta 是 Q16 整数参数，epsilon 为 Q48 标量。

## 5. 数值定义

输入预处理是独立边界：MobileViT RGB 256×256，以包内 256 项像素表转 INT32 Q16；YOLOX BGR 640×640，等比例左上补 114，U8 像素左移 16 转 Q16。模型图内只有整数语义。正式权重全部 W8；输入 QUANT 根据冻结层策略选 A8 或 A16。MobileViT 的表精确匹配本次 GPU 校准采用的 float32 归一化（乘 reciprocal 位模式 0x3B808081，再 RNE 转 Q16）；不能换成 CPU float 除法或整数有理数 `/255` 后假定最低位相同。编译测试覆盖全部 256 个像素。

- **RNE**：对完整有符号分子执行 nearest/ties-to-even；负值按绝对值舍入再恢复符号。不可用简单加半后算术右移替代。
- **QUANT**：`RNE(x_q16 * M / 2^shift)`，随后饱和到 [-127,127] 或 [-32767,32767]。
- **Conv/Linear**：整数点积＋包内 INT32 bias，再按输出通道 multiplier/shift 转 Q16。中间参考为 INT64；冻结 profile 2 的重定标输入被检查为 INT32 范围。A16 以 `x = ((x&255)-128) + 128 + 256*(x>>8)` 分解，乘法无截位近似。
- **Add**：Q16 精确相加；**Mul**：INT64 乘积，RNE 右移 16。
- **SiLU**：图中为 `x * sigmoid(x)` 两个整数操作。Sigmoid 表域 [-16,16]、步长 1/256、Q16 值，整数线性插值；域外夹到端点。
- **Exp**：相同表域/步长，表值 INT64 Q16，域外夹到端点。检测框解码与 stride 相乘采用 INT64 Q16，不以 INT32 的坐标上限截断框。NMS 属于图外 PS/上位机后处理。
- **LayerNorm**：最后一维的整数均值；中心化平方和求总体方差；epsilon 为 Q48；整数平方根得到 Q24 分母，再做 RNE 整数除法、gamma/beta Q16 仿射。不调用 float sqrt/rsqrt。
- **Softmax**：减最后维最大值；负指数查表域 [-16,0]、步长 1/256、值 Q30；分别 `RNE(exp_i*65536/sum_exp)` 输出 Q16。各分量独立舍入，不额外重新分配概率和的余数。
- **Attention MatMul**：INT64 点积，RNE 右移 16 回 Q16。
- **GAP**：整数求和、RNE 除以空间元素数。
- **Resize**：nearest/asymmetric/floor，按 `floor(out_index*input_size/output_size)` 取点。其余切片/拼接/重排不做额外量化。

Q16 普通结果若超出 INT32，参考直接报错而非隐藏饱和；本次完整验证未触发。硬件应设置数值故障标志并停止接受结果。Dot、方差、乘积和 LUT 的宽度必须按本合同实现，不能直接全部缩成 16 位。

## 6. 严格参考与加速参考

`--strict-attention` 使用 NumPy CPU INT64 Attention 点积，其余 Conv/Linear 是精确 CUDA INT8 GEMM（A16 两字节分解）。F.unfold 临时以 FP32 容器复制整数输入/填 0，不执行浮点乘加。

可选加速 Attention 以 FP64 作为整数载体。每次点积先检查 `max(abs(A))*max(abs(B))*K < 2^53`，从而乘积及所有部分和均为精确整数，再转回 INT64。它不是浮点近似算法；仍提供严格后端作独立比对。最终 MobileViT 完整验证使用严格后端，不能仅凭局部测试宣称严格全网已验证。

## 7. 加载、初始化与切换

1. 主机验证包结构、CRC、模型 profile 和容量，选定不与 Linux、ELF、视频 DMA、其他模型任务重叠的预留 DDR 区域。
2. 将不可变包写入 model_base；实际 DDR 回读并验证 CRC。Profile 2 常量指向包内 CONSTANTS，不需要再次搬运全部权重。
3. 单独分配 workspace_base。Profile 1 先将 LEGACY_IMAGE 复制至工作区，再写输入；profile 2 的各操作会完整写目的张量，无需依赖初始工作区内容。
4. 写输入并管理 PS cache；后续匹配硬件接收一次任务描述（profile、model_base、workspace_base、frame/model generation），在 PL 内读取指令调度。
5. 完成或故障都需等所有读写、DMA、FIFO 真正退出后，才释放工作区或切换模型。下一模型不得覆盖正在执行的共享工作区。

提供的 `load_ddr.tcl` / `load_input.tcl` 只完成显式预留地址的下载与回读校验，不写 MODEL_READY，不访问当前 PL 寄存器，也不证明新模型已在 FPGA 上执行。后续硬件的任务寄存器/中断接口尚需设计；不能将这些包交给原 ResNet 加载脚本后期待自动推理。

输入脚本会先校验全部本地输入/初始化文件，并回读整包模型 CRC，确认 DDR 中的模型与输入版本配对后才写工作区。Profile 2 即使输出目录残留旧 ResNet 初始化文件，也不会加载。输入范围必须在声明的工作区内。现阶段这些脚本经过 Tcl 模拟验证，实际 XSDB API/硬件回读仍需板测。

## 8. 可复现发布证据

`run_all.ps1` 从冻结 ONNX 编译并打包，随后从最终二进制包重建执行图做完整验证。每张验证图的主机定点输入均与原量化预处理对齐；MobileViT 使用严格 INT64 Attention。验收报告绑定包、源码/合同、输入图像/标注、checkpoint、基线指标和实际输出报告的 SHA256。`release.py` 拒绝部分数据集验证、精度失败、过期证据、包版本差异或缓存规划差异，并生成最终发布清单。`release.py --verify` 复核当前文件与发布证据，不代替重新运行全量网络。
