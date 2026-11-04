# 项目材料与验证覆盖矩阵

本表描述归档材料能够支持的结论及未覆盖的环节。“文件存在”“历史验证通过”“维护者确认上板”不合并为一种证明。本次整理未执行综合、实现、RTL仿真或板端验证。

## 源码、构建与运行

| 范围 | 材料入口 | 当前证据 | 尚未覆盖 |
|---|---|---|---|
| 硬件与软件源码 | `src/hardware/`、`src/software/`、`src/host/`、`src/third_party/` | 当前npu100 RTL、约束、BD、PS算法、Linux运行时及模型工具已归档 | ResNet首次FP32→QDQ生成器与基础系统完整工程 |
| 模块验证 | `sim/rtl/unit/`、`evidence/sim/unit/` | 缓存、DMA、舍入、MaxPool历史定向XSim记录，DUT/helper哈希与现存源码一致 | 最终三模型整网RTL/Golden回归 |
| 模型构造 | `data/models/`、`evidence/models/` | 冻结输入到三份最终DDR文件的重建SHA256一致 | 重新训练、重新量化、网络执行及最终板端精度 |
| 综合与实现 | `build/reports/`、`evidence/hardware/` | 最终routed资源、时序、路由及方法学报告；XSA内嵌bit与归档bit一致 | 同工程/特性/工具/阶段的成对优化前后原始报告 |
| Linux接入 | `board/`、`evidence/linux/board/` | 驱动日志和历史BOOT_DT、PL_ABI、三模型DDR回读、自启动安装输出 | 完整连续冷启动、最终推理和整理后无日期路径的独立板测 |
| 软件精度 | `data/metrics/`、`data/models/quantization/` | 主机参考、量化参考和QDQ/ORT结果及输入尺寸标签 | 最终160/256/256配置的完整板端精度与同输入Golden对照 |
| 性能 | `data/metrics/board/` | 维护者确认的同平台标量C、NEON双核及本系统近似单图时间 | 原始逐次计时、起止点、样本数与时延分布 |
| 构建入口 | `build/scripts/{vivado,models,linux,baremetal}/` | 硬件工程重建、冻结模型构造、自有Linux软件构建/打包入口 | 完整rootfs、BSP、FSBL/U-Boot/BIF生成链 |

## 文档、协作与工作流

| 内容 | 已有材料 | 使用边界 |
|---|---|---|
| 架构与接口 | `docs/architecture.md`、`docs/hardware_modules.md`、`report/design/` | 说明PS/PL分工、DDR/AXI-Lite/帧引用/按键合同；物理PE支持两种映射 |
| 优化决策 | `docs/optimization_decisions.md`、实现报告与性能表 | 记录措施及代价；缺匹配资源基线时不推算节省百分比 |
| 大模型协作 | `report/collaboration/` | 真实提示词/回答摘录与摘要分别标识，保留纠错；Ross历史摘要不证明本版工具流程已执行 |
| 发布完整性技能 | `skill/fpga-release-integrity/` | 检查可信清单、文件内容与安全相对路径，不证明算法或时序 |
| Linux证据技能 | `skill/linux-npu-evidence/` | 离线识别日志阶段及失败，不接触设备，也不证明当前状态 |
| 技能验证 | `report/collaboration/skill_validation.json` | 两项技能共17项主机检查通过，不等于板端功能或RTL测试数量 |
| 复现说明 | `docs/reproduction.md`、`docs/linux.md`、`docs/model_pipeline.md` | 区分冻结产物部署与源码分段重建；基础系统获取仍有前置缺口 |

## 指标口径

维护者确认的同平台单图推理约值如下：

| 模型 | 无SIMD标量C | NEON双核 | 本系统 |
|---|---:|---:|---:|
| ResNet18 | 12 s | 1.3 s | 0.5 s |
| YOLOX-S NEU6 | 50 s | 4.6 s | 1.4 s |
| YOLOX-S COCO80 | 55 s | 5.1 s | 1.6 s |
| 各一张合计 | 117 s | 11.0 s | 3.5 s |

合计加速比为`117/3.5≈33.4`和`11/3.5≈3.14`；不含模型切换，不等于摄像头到HDMI时延或检测结果更新率。原始逐次日志未归档，不补造样本数、均值或标准差。

NEU6主机精度记录对应640输入，最终板端为256；ResNet checkpoint中的100%对应原224输入验证，最终板端为160。COCO80主机精度为256输入、5000张验证图。主机评估不能直接替代最终硬件评估。

最终routed资源为LUT46,278、FF45,385、BRAM Tile91、DSP148、Slice13,299/13,300。100MHz下WNS+0.047ns、WHS+0.033ns、TNS/THS为0。报告仍有5个no_input_delay输入与8个no_output_delay输出，结论限于现有约束。Vivado的低置信度功耗估计不作为整机实测功耗。

## 历史板端日志

来源和命令见[user_logs说明](../evidence/linux/board/user_logs/README.md)。BOOT_DT、PL_ABI、DDR回读和自启动安装输出来自不同历史操作，本次未重跑，也不拼接成同一次冷启动。DDR回读没有执行推理；安装后`managed_process_alive=false`原样保留，安装成功不能当作服务运行成功。

## 文档与说明素材

- [设计文档](../report/design/design_report.pdf)以PDF提供，说明架构、优化、验证、协作及复现。
- [技术文档](../report/technical/)展开模型、RTL与Linux实现细节。
- [技术原理图](../report/figures/)说明系统结构、计算映射、缓存、帧引用与Linux分层。

图示用于说明设计关系，不能代替原始精度、性能或版本验证记录。

## 基础系统与命名

[基础系统元数据](../board/linux/rootfs/base_os_image.json)记录PetaLinux2025.2、VirtualBox/Ubuntu构建来源、WIC大小6,442,455,040字节及SHA256。仓库不分发该WIC；它也不含最终应用更新。完整PetaLinux/rootfs与启动链配置、公开可取得的匹配基础镜像仍需补齐，详见[missing_materials.md](missing_materials.md)。

源码归入`src/`，模型归入`data/models/`；`docs/`、`evidence/`、`manifests/`和`tools/`提供操作、证据与校验入口。普通新增文件使用小写英文、数字、下划线或连字符；`README.md`、`SKILL.md`、`Makefile`、`CMakeLists.txt`、`BOOT.BIN`、`SHA256SUMS`等保留工具或格式规定的名称。
