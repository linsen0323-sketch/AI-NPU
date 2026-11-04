# 裸机软件源码说明

最终系统采用 Linux；本目录保留当前 npu100 工程对应的 Cortex-A9 裸机应用与共享算法来源，用于追溯软硬件分工和可选 standalone 复现。Linux 的驱动、加载器及服务请使用 `src/software/runtime/linux/` 与 Linux 部署文档。

## 文件含义

| 文件或文件组 | 用途 |
|---|---|
| `src/software/app/src/main.c`、`runtime.c` | 裸机入口、运行循环、MMIO、任务及缓存管理 |
| `ai_camera_models.*`、`ai_camera_catalog.h`、`ai_coco80_config.h` | 模型目录、加载配置、执行与切换 |
| `ai_preprocess.*`、`ai_camera_geometry.h`、`ai_camera_luts.h` | 图像几何变换、像素转换及输入组织 |
| `ai_camera_math.*`、`ai_camera_math_tables.h` | 可移植定点数学、检测解码与 NMS 支撑 |
| `ai_detector.*`、`ai_result.h` | 推理任务与结果结构 |
| `ai_display.*`、`ai_resnet_score_lut.h` | 结果发布、OSD 信息及分类分数换算 |
| `ai_board_keys.*` | 实体按键读取 |
| `ai_camera_memory.*` | 原始帧和模型/工作区 DDR 组织 |
| `ai_ps_timing.*` | PS 分阶段计时与日志 |
| `ai_sd_boot.*` | 可选裸机 SD 冷启动入口 |
| `src/software/runtime/baremetal/npu_sd_loader.*` | SD 模型包读取与配置 |
| `npu_sd_hash.*`、`npu_sd_predecoded.h` | 校验与预解码包描述 |
| `lscript.ld`、`empty_application_example.cmake` | 14 MiB 私有链接区与内存布局 |
| `CMakeLists.txt`、`user_config.cmake` | Vitis 2025.2 应用构建与优化配置 |

完整逐文件来源和哈希见 `evidence/packaging/hardware_files.json`。除私有 CMake 文件名及对应 include 的小写化外，应用 C/H 与链接布局逐字节保留。`CMakeLists.txt` 是工具规定的文件名。原 `app.yaml` 只包含旧工作区/BSP 绝对路径，属于可生成元数据，未带入。

## 可选 standalone 构建

安装 Vitis 2025.2 和 Cortex-A9 裸机工具链，在仓库根目录使用：

```powershell
vitis -s build/scripts/baremetal/build_application.py
```

脚本从 `board/hardware/npu100.xsa` 新建 `npu100_platform`、`standalone_a9_0` 域和 `npu100_app`，配置 UART0 与 xilffs，按当前文件布局复制源代码后构建。默认输出在 `build/work/vitis`；环境变量 `NPU_BAREMETAL_WORKSPACE` 可指定全新工作区，`NPU_XSA` 可指定新匹配 XSA。脚本拒绝覆盖非空工作区。

该入口按本机 Vitis 2025.2 API 和官方示例编写并进行 Python 语法检查；整理阶段未执行 BSP 生成或 ELF 链接，因此不作为已通过的裸机构建证据。发布包不混入其他工程的 BSP、头文件或 ELF。

当前应用的 `AI_CAMERA_LOAD_FROM_SD` 保留原始 `OFF` 配置，裸机模型参数原按 JTAG 预装；最终 Linux SD 加载由 Linux 运行时实现。启动时停止推理并默认选择 NEU6；KEY0/MIO12 选 ResNet，KEY1/MIO11 选 NEU6，KEY2/L14 选 COCO80，KEY3/K16 启停。

## 待补材料

- 从本发布包 XSA 生成并核对的 standalone BSP/ELF 构建回执。
- 如需展示裸机独立运行，补充与本版 bit/XSA/模型匹配的运行日志；最终 Linux 验证另行归档。

