# 项目材料索引

本仓库按源码、构建、部署、数据、验证和文档组织。下表说明现有材料及其职责；文件存在、历史验证和当前运行状态分别记录。

| 材料 | 路径 | 内容与边界 |
|---|---|---|
| 硬件源码 | `src/hardware/` | 当前npu100引用的RTL、约束与BD；完整模块说明见hardware_modules.md |
| 板端软件 | `src/software/` | PS共享算法、裸机支持、Linux驱动与生产运行时 |
| 主机工具 | `src/host/`、`src/third_party/` | 训练、量化、编译与模型计划工具，以及保留原许可的第三方源码 |
| 模型与数据合同 | `data/models/`、`data/` | 冻结权重/ONNX/DDR模型包、校准与划分清单、主机精度及性能汇总 |
| 构建与实现 | `build/scripts/`、`build/reports/` | 硬件重建入口及最终资源、布线和时序报告 |
| 部署产物 | `board/` | 匹配bit/XSA、启动文件、设备树、驱动、用户态与SysV服务 |
| 仿真与验证 | `sim/`、`evidence/` | 已归档定向仿真、模型构造、Linux与文件身份记录；各记录保留对应验证范围 |
| 设计与技术文档 | `report/design/`、`report/technical/`、`docs/` | 设计决策、软硬件分工、实现细节、验证范围及复现步骤 |
| 协作与技能 | `report/collaboration/`、`skill/` | 真实公开摘录、纠错、Ross经验及两项可运行技能 |
| 技术图示 | `report/figures/` | 系统结构、训练部署、计算映射、缓存、帧引用与Linux分层原理图 |
| 文件清单 | `manifests/`、`tools/` | 用途、来源与SHA256目录，以及本地完整性校验工具 |

## 现有验证材料

- **硬件构建：**Vivado 2025.2最终routed资源和时序报告、BD/IP重建与身份检查；未把重新创建工程当作完成新综合实现。
- **模型：**三份最终DDR文件及重建SHA256一致性记录；主机精度与最终板端精度分别标注。
- **Linux：**驱动加载日志，以及`evidence/linux/board/user_logs/`中的历史BOOT_DT、PL_ABI、三模型DDR回读和自启动安装输出。
- **技能：**`fpga-release-integrity`与`linux-npu-evidence`均包含用法、失效条件、示例和验证结果。

历史用户日志未在本次重跑。DDR回读未执行推理；自启动安装仅证明链接配置完成，紧接安装的状态为`managed_process_alive=false`，不能据此声称当时服务正在运行。完整范围见[user_logs说明](../evidence/linux/board/user_logs/README.md)。

## 复现与维护

使用冻结产物上板验证的入口见[reproduction.md](reproduction.md)，验证阶段对照见[requirement_matrix.md](requirement_matrix.md)。

硬件使用Vivado/Vitis 2025.2。板端采用自定义Linux驱动与RTL NPU，未使用PYNQ框架。根README提供目录职责对照；稳定文件名与相对路径用于跨平台构建。
