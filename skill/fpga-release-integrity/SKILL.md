---
name: fpga-release-integrity
description: Trace a selected FPGA release to its source, bitstream, models and deployment evidence, then verify portable SHA256 manifests without modifying the release or running vendor tools.
---

# FPGA release integrity

用于多份同名旧工程共存、硬件导出与模型文件分散的源码交付。先明确本次需要核对的工程入口和部署产物，不用目录名、修改时间或历史对话代替版本身份。

## 输入与检查

1. 读取目标 XPR 的文件集、BD、约束及导出脚本，记录实际引用；保存相对路径与文件 SHA256。若工程入口不唯一，先报告候选及差异。
2. 对照部署 XSA、其内 bitstream、实现目录 bitstream 和软件 ABI。报告名称中的频率不能代替时钟约束；综合、布局、布线时序分别记录。
3. 由最终模型清单反查训练 checkpoint、输入尺寸、量化与编译来源。权重重排及 DDR 打包不能称为重新量化，旧输入分辨率不能直接套用。
4. 将整理产生的路径适配与原始计算逻辑分开列出。路径适配后通过静态检查，不等于已经重做板测。
5. 用校验器验证相对路径 SHA256 清单；把缺失文件、变化、越界、重复条目和空清单视为失败。

```sh
python skill/fpga-release-integrity/scripts/verify_manifest.py --root . --manifest manifests/files.sha256
```

脚本仅使用 Python 3 标准库，只读源文件并向标准输出写 JSON；退出码 0 表示所有清单条目通过，退出码 1 表示清单或内容不匹配。它不扫描未列入清单的附加文件，完整发布检查还应使用仓库自身的目录清单。

## 失效条件

- 未取得活动工程文件集或部署产物，只能报告可取得文件之间的一致性。
- 清单本身不可信或不覆盖全部关键文件，不能据此宣称整个工程完整。
- SHA256 相同证明字节身份，不能证明算法正确、时序通过或物理接口接通。
- 模型、ABI、PL、设备树、时钟或 DDR 合同任一改变，必须重新建立对应验收证据。

## 失败来源与已验证效果

本项目曾将同名旧工程记录与 `npu100.xpr` 混用；用户重新确认入口后，协作流程改为按工程文件集和导出哈希锁定版本。Linux 与模型路径整理也暴露了换行符转换会改变冻结文件 SHA256 的问题。因此本技能把“身份”和“校验范围”放在变更之前。

原项目已有清单校验技能。本版在其基础上补充空清单拒绝、跨平台盘符路径拒绝、路径规范化及读取错误诊断。隔离目录中的正常、篡改、缺失、重复、越界、盘符路径和空清单验证结果见 `../../report/collaboration/skill_validation.json`。这些结果属于主机文件校验，不涉及仿真、综合或板测。
