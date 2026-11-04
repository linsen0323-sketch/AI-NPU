# 硬件 RTL 模块中文说明

本表覆盖 `src/hardware/rtl/` 下的 **61 份 RTL 文件**，按功能分组说明。表中“主路径”表示从当前板级顶层、BD 模块引用及源码实例关系可追溯到的功能路径；具体算子按任务调度执行，不表示各模块同时运行，也不表示该文件的每个参数分支均保留在最终网表中。

当前工程顶层为 `camera_720p30_top`，通过 `video_system_wrapper` 接入 PS7 与 BD，BD 中的自定义模块引用为 `ai_camera_pipeline_bd`。最终配置以 [BD 创建脚本](../src/hardware/block_design/create_video_system.tcl) 为准：`ENABLE_PE_SPATIAL4=1`、`ENABLE_LUT_TDP=1`，性能计数、逐层轨迹和停顿诊断均关闭。集成层固定 `PS_PREDECODED=1`。文件头保留的历史生成说明不能替代本次源码核对或已归档的实现证据。

## 图任务与控制（13 份）

以下路径均位于 [`rtl/accelerator/`](../src/hardware/rtl/accelerator/)。

| RTL 文件 | 中文作用与使用边界 |
|---|---|
| `npu_graph_control_top.sv` | 集成模型任务控制与图执行后端，保持任务、帧和模型代次身份；主路径，PE 由外部统一提供。 |
| `npu_graph_registers.sv` | 实现图任务 AXI-Lite 寄存器、启动/取消/完成握手及能力与时钟信息；主路径，诊断寄存器受配置约束。 |
| `npu_graph_result_bridge.sv` | 在执行与访存排空后发布完成描述符，并保持到 PS 清除；主路径，用于避免丢失完成事件。 |
| `npu_model_control_top.sv` | 连接模型前端、任务拥有权、图调度和共享访存；主路径，不实例化第二套 PE。 |
| `npu_task_controller.sv` | 串行管理模型/工作区任务拥有权、能力准入、取消与排空；主路径，已接受的事务完成后才释放工作区。 |
| `npu_predecoded_frontend.sv` | 接收 PS 已校验并预解码的包元数据，保留 PL 地址范围和形状边界检查；当前 `PS_PREDECODED=1` 选用。 |
| `npu_graph_sequencer.sv` | 顺序调度图指令并核对执行器支持范围，把具体张量语义和运算交给后端；主路径。 |
| `npu_graph_plan_backend.sv` | 读取与缓存单条图指令对应的编译计划记录，组织执行及权限检查；主路径，缓存身份包含模型代次和物理范围。 |
| `npu_predecoded_iterator.sv` | 展开 PS/编译器预归一化的仿射循环与地址步进，等待每个内任务终止；当前预解码路径选用。 |
| `npu_plan_iterator.sv` | 在 PL 中解析通用计划的外层循环、地址重定位及跨度检查；`PS_PREDECODED=0` 的兼容分支，当前未选用。 |
| `npu_aipkg3_frontend.sv` | 从 DDR 逐字读取并校验 AIPKG3 头部、目录与 CRC；旧式 PL 校验分支，当前预解码配置未选用。 |
| `npu_package_cache.sv` | 缓存已验证模型包的元数据，按不可变模型代次合同命中并支持空闲失效；旧式包前端分支，当前未选用。 |
| `npu_axil_window_mux.sv` | 按 AXI-Lite 地址位分流摄像头与图控制窗口，并保持独立读写事务归属；兼容模块，当前双 AXI-Lite 接口集成未引用。 |

## 算子与整数算术（14 份）

以下路径均位于 [`rtl/accelerator/`](../src/hardware/rtl/accelerator/)。

| RTL 文件 | 中文作用与使用边界 |
|---|---|
| `npu_plan_dispatch.sv` | 按计划记录选择复制、卷积、池化、逐元素或 GAP 引擎，并共享访存、宽整数算术和外部 PE；主路径。 |
| `npu_conv2d_stream_engine.sv` | 对普通 `groups=1` 的 NCHW/OIHW 卷积执行分块加载、共享 PE 计算及输出流水；主路径，输入/权重缓冲支持重叠调度。 |
| `npu_conv_epilogue.sv` | 将卷积部分和加偏置，执行精确重定标、舍入和结果范围检查，保留输出标签；主路径。 |
| `npu_conv_output_tile.sv` | 暂存 NCHW 卷积输出块，按元素宽度打包 AXI64 数据和字节使能，支持输出融合接口；主路径。 |
| `npu_copy_stream_engine.sv` | 将连续同类型复制合并为有界 DMA 数据块，兼容变步长与类型转换回退并处理错误排空；主路径。 |
| `npu_copy_engine.sv` | 执行逐元素精确仿射复制与数据类型转换，支持重复标量读取；作为流式复制引擎的检查与回退实现。 |
| `npu_maxpool_engine.sv` | 实现 NCHW 最大池化及填充边界，支持 I32 和标记的 ResNet I8 模式，缓存重叠窗口读取；主路径。 |
| `npu_q16_scalar_engine.sv` | 检查逐元素任务的几何、数据类型与别名合同，组织标量或向量执行并等待写响应；主路径。 |
| `npu_q16_elementwise.sv` | 实现量化、加/乘、ReLU、Sigmoid 和 Exp 的精确标量后端，复用宽整数算术与模型 LUT；用于标量回退。 |
| `npu_q16_vector_engine.sv` | 在已通过前置检查的任务中以 128 元素块组织批量读、计算和写回，并支持融合通道；当前流式配置可调度。 |
| `npu_q16_vector_pipe.sv` | 执行带标签的逐元素流水运算、LUT 激活与融合处理，由上游预留结果槽位；向量引擎子模块。 |
| `npu_resnet_gap_engine.sv` | 按 ResNet 数值合同执行全局求和及共享重定标，保持 signed40 累加回绕语义；按 ResNet 任务调度。 |
| `npu_resnet_quant.sv` | 提供 ResNet 精确重定标、残差合并及乘积/舍入流水；同文件含 `npu_resnet_product_pipe`、`npu_resnet_round_pipe`，集成时共享服务。 |
| `npu_wide_math.sv` | 封装共享精确加法、乘后右移和右移服务；同文件含算术端口适配器与仲裁器，集成路径复用同一算术核心。 |

## PE、缓存与访存（17 份）

以下路径均位于 [`rtl/accelerator/`](../src/hardware/rtl/accelerator/)。

| RTL 文件 | 中文作用与使用边界 |
|---|---|
| `npu_shared_pe.sv` | 管理唯一 PE 阵列从首拍到末拍结果的任务拥有权，防止不同任务交叉占用；当前集成为单客户端、32 物理输出、DSP 打包。 |
| `npu_pe_8x32.sv` | 实现可重映射的 256 路 A8×W8 乘积阵列及累加；当前支持四空间 `4×8×8` 映射，同一阵列也有单空间 `1×8×32` 数据映射。 |
| `npu_dsp48_pair.sv` | 在一个 DSP48E1 中利用共享激活计算两个 INT8 权重乘积，提供符号修正所需信息；PE 打包基础单元。 |
| `npu_wide_math_fast.sv` | 通过分阶段 DSP 部分积实现精确 INT64 算术，保留舍入所需 guard/sticky 位及溢出检查；共享宽算术核心。 |
| `npu_banked_buffer.sv` | 实现双页多 bank 权重缓冲，单 bank 写入、同地址并行读取并保持反压数据；主路径，内存实现形式由参数选择。 |
| `npu_stream_ibuf.sv` | 实现双页输入缓存和八通道 bank 读取，使一页 DMA 填充与另一页窗口取数重叠；主路径。 |
| `npu_input_tile_loader.sv` | 将 NCHW 输入的裁剪行及填充组织为通道 bank 数据块，合并邻近行 DMA 并丢弃间隙；卷积加载子模块。 |
| `npu_stream_weight_loader.sv` | 从 DDR 突发读取 OIHW 权重，仅在 WBUF 内完成布局转换，保持模型权重字节及数值不变；卷积加载子模块。 |
| `npu_lut_reader.sv` | 根据主机解析的描述符读取模型常量区 LUT，提供标量及流式激活查表服务；LUT 路径，当前启用双端口相关优化。 |
| `npu_scalar_fabric.sv` | 在多个标量请求者间保持单事务仲裁与响应归属，所有者持续到终端响应；共享标量访存路径。 |
| `npu_scalar_guard.sv` | 按两个只读窗口和一个可写窗口检查标量字节访问权限；执行后端安全边界，不负责 AXI 字节通道映射。 |
| `npu_stream_guard.sv` | 检查整个流式描述符及对齐总线拍范围，拒绝非法访问并完成必要错误排空；批量访存安全边界。 |
| `npu_stream_read_fabric.sv` | 仲裁读描述符并保持从请求、流数据到终端响应的拥有权；用于多个读客户端共享传输。 |
| `npu_stream_write_fabric.sv` | 轮转仲裁写描述符、数据流和终端响应，并在写响应完成后释放拥有权；用于多个写客户端共享传输。 |
| `npu_stream_axi_master.sv` | 将标量检查/回退与批量客户端接入有序 AXI64 DMA，写操作以 BRESP 为完成依据；主 NPU DDR 接口。 |
| `npu_stream_dma.sv` | 实现有界在途突发、读接收额度和顺序响应的 AXI4 批量传输，停止只阻止新描述符；已接受事务必须排空。 |
| `npu_layer_profiler.sv` | 保存被动逐层轨迹与停顿快照；同文件含 `npu_stall_snapshot`，当前 `ENABLE_PROFILE_TRACE=0`、`ENABLE_STALL_DIAG=0`，两项诊断均关闭。 |

## 视频、板级与时钟（17 份）

以下路径均位于 [`rtl/video/`](../src/hardware/rtl/video/)。

| RTL 文件 | 中文作用与使用边界 |
|---|---|
| `camera_720p30_top.v` | 板级顶层，连接 OV5640、时钟复位、DVP、PS/BD 与 HDMI TMDS；名称中的 30p 是保留名称，不单独定义实际帧率。 |
| `video_system_wrapper.v` | Vivado 生成的 BD 外层端口封装，连接 PS DDR/MIO 与自定义数据通路；仓库保留来源快照，重建脚本重新生成 wrapper。 |
| `ai_camera_pipeline_bd.v` | 将参数与 AXI/视频接口展开为 BD 可引用模块形式，并实例化统一摄像头/NPU流水；当前 BD 自定义模块入口。 |
| `ai_camera_pipeline.sv` | 集成摄像头前端、共享图执行、唯一 PE、结果桥、帧扫描与叠加；区分视频与 NPU 时钟复位及寄存器接口。 |
| `ai_preprocess_top.sv` | 管理 CAM2 原始 RGB565 帧槽、PS/显示独立引用与控制寄存器，并组织快照写入；当前不在该模块自动生成推理输入张量。 |
| `ai_snapshot.sv` | 被动截取获准的完整视频帧，不对相机主视频路径反压；溢出时丢弃该快照，已启动的写事务仍须排空。 |
| `ai_dma64.sv` | 将快照数据以单在途、16×64 位 INCR 突发写入 DDR；客户端保证对齐，软中止不能撤销已启动事务。 |
| `ai_frame_scanout.sv` | 读取拥有权保持不变的 RGB565 帧并输出 AXI 视频流，只在完整帧边界切换描述符；显示释放必须等待退休通知。 |
| `ai_result_overlay.sv` | 在与结果匹配的帧上叠加检测框、类别及状态文字，七级流水随反压一起停顿；仅错误/不可用置信度值按合同处理，不把分类 logits 当概率。 |
| `dvp_to_axis.v` | 将 OV5640 双字节 RGB565 DVP 转换为每拍一像素的 AXI 视频流，检查行宽、帧界及 FIFO 状态；传感器不能接受反压。 |
| `ov5640_sccb_ctrl.v` | 执行 SCCB 初始化、ACK 检查、有限重试与掩码读回验证；同文件含 `camera_sccb_master`，失败状态保持到复位。 |
| `ov5640_720p_rom.v` | 保存 OV5640 1280×720 RGB565 配置序列及快速/保守时序选项；寄存器目标帧率与实测采集帧率分别看待。 |
| `cam_xclk_gen.v` | 使用 7 系列时钟原语及 ODDR，将 50 MHz 参考时钟转换并转发为相机 24 MHz XCLK。 |
| `clock_gen_720p.v` | 通过同一 MMCM 生成约 74.21875 MHz 像素时钟和精确五倍串行时钟，服务固定 720p TMDS 输出。 |
| `dvi_transmitter_top.v` | 将 RGB565 与 HS/VS/DE 转为三路 TMDS 数据及转发时钟，经 HDMI 接口输出 DVI 兼容视频；不提供音频、EDID 或 HDCP。 |
| `dvi_encoder.v` | 对单个颜色通道执行 TMDS 8b/10b 编码与控制字符选择；发射器分别实例化 R/G/B 通道。 |
| `serializer_10_to_1.v` | 使用主从 OSERDESE2 将 10 位 TMDS 并行数据转换为 DDR 串行输出，要求串行时钟为像素时钟的五倍。 |

## 理解与复现边界

- **一套物理阵列、多种数据映射：**`4×8×8` 与 `1×8×32` 是同一共享 PE 中的映射方式，不是两个并行存在的独立 NPU；具体命令是否请求四空间模式由调度与几何决定。
- **源文件存在不等于逻辑启用：**旧式包扫描、旧式计划迭代、单窗口 AXI-Lite 复用器和诊断模块均保留源码，但当前参数或实例关系不选用相应逻辑。
- **厂商 IP 单独生成：**PS7、AXI 互连、复位及视频输出等厂商 IP 由 BD/IP 生成流程提供，不包含在上述 61 份自有/封装 RTL 文件的统计中。
- **本次为静态核对：**作用说明依据文件头、端口、内部实例及 BD 参数，不代替新一轮 elaboration、综合资源或时序验证。最终历史实现及本次整理验证范围见 [硬件设计与重建](hardware.md)。
