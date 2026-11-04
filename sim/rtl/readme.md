# 现有 RTL 测试入口

- `tb_ai_result_overlay.sv`：当前 npu100 的 `sim_1` 入口，覆盖检测框边界、裁剪、标签与信息区优先级、分类分数及AXI反压。源文件明确注明该修订尚未仿真；未附带伪造的 PASS 日志。
- `tb_ov5640_profile.sv`：当前工程的 `sim_camera_profile` 入口，核对 OV5640 配置表、几何、时钟配置和读回期望。
- `setup_simulations.tcl`：在重建的 npu100 工程中配置上述文件集，不启动仿真。

在 Vivado 打开重建工程后，执行 `source <仓库>/sim/rtl/setup_simulations.tcl`，选择相应 simulation set 后再显式运行。相机测试支持 `FAST_720P` 两种参数配置，不能把单个参数结果替代两种配置覆盖。

现有冻结产物的上板部署不依赖重新运行仿真。已归档的权重缓存、DMA、舍入与 MaxPool 定向测试及历史日志见 `unit/README.md` 和 `evidence/sim/unit/`；它们分别说明对应模块的测试范围。新增绘框测试尚无本次重新执行的通过记录，现有材料不标注为完整三模型整网 RTL 回归。
