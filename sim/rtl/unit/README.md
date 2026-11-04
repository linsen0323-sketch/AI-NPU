# 找回的定向RTL仿真

四组原测试来自当前npu100工程自身的时序优化验证目录。已将被测模块及必要helper的SHA256与当前生产源码核对，结果见 `evidence/sim/unit/source_identity.json`。

| 测试 | 主要内容 | 仿真顶层 |
|---|---|---|
| wbuf | 原生权重缓存、读写冲突、反压及复位 | tb_wbuf_native |
| dma | DMA空/非空状态、credit、终结响应、错误、停止及复位 | tb_dma_nonempty |
| round | 有符号重定点、舍入、饱和、溢出、标签与流水资格 | tb_round_miter |
| maxpool | 窗口读取、bulk与scalar路径及故障行为 | tb_maxpool_source_words_bulk / scalar |

`reference/`只含原测试使用的独立命名对照模块，参与仿真，不加入生产硬件文件集。生产DUT统一从 `src/hardware/rtl/` 引用，不复制另一份可误用的生产RTL。

## 配置与执行

先用 `build/scripts/vivado/create_project.tcl` 创建npu100工程，在Vivado打开它后执行：

```tcl
source sim/rtl/unit/setup_unit_tests.tcl
launch_simulation -simset sim_unit_wbuf -mode behavioral
run all
close_sim
```

其他测试的simset为 `sim_unit_dma`、`sim_unit_round`、`sim_unit_maxpool_bulk` 和 `sim_unit_maxpool_scalar`。每次执行后保存编译、elaboration及simulate日志到新的输出目录。

本次材料整理核对了原始日志和模块身份，配置脚本只做工程/fileset检查；未重新执行RTL仿真。历史PASS不能替代最终三模型整网Golden或新的上板验证。Copy桥和时间戳候选与当前生产源码不完全一致，未将其旧PASS充作当前版本证据。

