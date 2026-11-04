---
name: linux-npu-evidence
description: Classify saved Linux NPU bring-up logs by boot contract, driver metadata, PL ABI, DDR readback and inference evidence without opening devices, writing DDR or controlling a board.
---

# Linux NPU evidence

用于本项目或采用同类分层验收标记的 Linux NPU 日志复核。输入是维护者已经保存的板端文本日志；本技能不会连接板卡、打开设备、读写 MMIO/DDR、加载驱动、启动摄像头或调整时钟。

```sh
python skill/linux-npu-evidence/scripts/classify_log.py --log evidence/linux/board/driver_load.txt
```

脚本只读输入，输出 JSON。输入成功读取时退出 0；文件无法读取时退出 2。`reported_pass` 表示日志出现相应成功报告，不是工具重新验证了硬件，也不代表本次冷启动状态。

## 复核顺序

- 启动合同：识别 `BOOT_DT_PASS`，只说明保存日志中的设备树与预留内存检查通过。
- 驱动：将 `DRIVER_CHECK_OK` 的文件预检与 `DRIVER_LOAD_PASS`、`DRIVER_INFO_PASS` 的加载及 ABI 元数据分开。
- PL：只有实际 `PL_ABI_PASS` JSON 记录才归为 PL 寄存器身份核对；设备节点存在不等于 PL 匹配。
- 模型：`MODEL_PRELOAD_PASS` 归为 SD 到 DDR 装载与回读阶段；同时保留 `inference_started`、`camera_start_requested` 等字段，不能将装载成功写成推理已启动。
- 整机：自动分类器不判定摄像头、HDMI、按键和模型正确性。需要人复核真实运行截图、连续日志、有效结果和对应版本身份。

存在错误与后续成功标记时均保留，不自动抹去旧错误或推断哪一条对应当前启动。应按时间和重启边界切分日志再评价。

## 失效条件

日志被截断、来源不明、标记仅出现在说明文档中，或输出格式改变时，分类器只能提供检索线索。它不验证日志真实性、次数、时间戳先后、冷启动次数或性能统计；没有标记也不证明功能失败。

## 从实际失败沉淀的经验

Linux 已启动和 SSH 可用，只证明基础系统接通。该项目先后需要落实 256 MiB `no-map` DDR、匹配内核模块 CRC、解决 FCLK 整数舍入，以及区分“模型写入 DDR”与“启动采集推理”。这些问题跨越不同验收层级，重复执行安装或强制复位无法替代分层取证。

`evidence/linux/board/driver_load.txt` 的真实板端记录同时保留 `error -34`、FCLK 实际值 `99999999 Hz` 及后续驱动加载成功；该记录明确声明未做 PL MMIO 与 DDR 访问。对这份日志，脚本必须只报告驱动层成功。隔离测试和原始日志验证记录见 `../../report/collaboration/skill_validation.json`。
