# IP 依赖

本项目无需额外自定义 IP 仓库。厂商 IP 由 `hardware/block_design/create_video_system.tcl` 在 Vivado 2025.2 中重新生成，包括 processing_system7、v_axi4s_vid_out、v_tc、axi_interconnect、axi_gpio、proc_sys_reset、xlconstant 及其内部 AXI 转换器。

`ai_camera_pipeline_bd` 是当前仓库 RTL 的 module reference，源文件在 `hardware/rtl/video/`，其共享 NPU 子模块在 `hardware/rtl/accelerator/`。不复制旧生成缓存，也不将厂商生成代码重新声明为自有开源代码。
