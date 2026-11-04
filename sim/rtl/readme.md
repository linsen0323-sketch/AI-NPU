# 现有 RTL 测试入口

- `tb_ai_result_overlay.sv`：当前 npu100 的 `sim_1` 入口，覆盖检测框边界、裁剪、标签与信息区优先级、分类分数及AXI反压。源文件明确注明该修订尚未仿真；未附带伪造的 PASS 日志。
- `tb_ov5640_profile.sv`：当前工程的 `sim_camera_profile` 入口，核对 OV5640 配置表、几何、时钟配置和读回期望。
- `setup_simulations.tcl`：在重建的 npu100 工程中配置上述文件集，不启动仿真。

在 Vivado 打开重建工程后，执行 `source <仓库>/sim/rtl/setup_simulations.tcl`，选择相应 simulation set 后再显式运行。相机测试支持 `FAST_720P` 两种参数配置，不能把单个参数结果替代两种配置覆盖。

本次整理未运行 XSim。全 NPU 算子、三模型 Golden 回归、完整流水线仿真、波形和最终版本覆盖率仍待补充。旧候选目录中的定向测试与日志没有作为最终版本成果混入本目录。
