# 环境与依赖

## 硬件开发

- FPGA：本版 npu100.xpr 配置的 Zynq-7020，完整 part 与约束见 hardware.md。
- Vivado / Vitis：现有工程使用 2025.2，具体构建版本保留于原始报告；重建脚本应使用同版本。
- Linux 软件：与板端 `6.12.40-xilinx` 精确匹配的内核配置、符号版本、设备树与 ARM 交叉工具链，见 linux.md。
- 裸机软件：需要根据本版 XSA 新建匹配的 standalone BSP，不能套用旧工程 BSP。

## 主机模型流程

训练、PTQ、ONNX 与模型编译工具的 Python 版本和依赖分开说明于 model_pipeline.md 及 src/host/ 下的配置文件。不要将训练环境、ONNX Runtime 验证环境和模型编译环境混为同一已锁定环境。

本包整理校验脚本仅需 Python 3.11+ 标准库：

```powershell
python tools/release_manifest.py --check
```

## 不随包复制的通用工具

Vivado/Vitis 安装程序、完整 Python 虚拟环境、Linux 通用工具链、公共原始数据集及旧 SD 原始磁盘镜像。文档记录其获取或构建方式；需要维护者提供的特定生成工程列入 missing_materials.md。

