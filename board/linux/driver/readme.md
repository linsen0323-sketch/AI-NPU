# ARM Linux driver artifacts

内核固定为 `6.12.40-xilinx-g31626ef92ff1`，ARMv7。驱动与C桥二进制保持原字节。

| 文件 | 用途 |
|---|---|
| `unified_npu.ko` | 最终内核模块，兼容标称100MHz时钟的±1Hz整数舍入 |
| `unified_npu_uapi.h` | ABI 3 ioctl定义 |
| `npu_driver_info.c` / `npu_driver_info` | 八个窗口的INFO检查源码和ARM可执行文件 |
| `libnpu_camera.so` | 摄像头程序调用的预处理/后处理C桥 |
| `check_driver.sh` | 默认只读检查；`--load`显式加载一次驱动 |
| `replace_failed_driver.sh` | 仅对无设备/无引用的失败probe模块进行普通卸载替换 |
| `sha256sums` | 本目录文件校验表 |

正常首次部署使用 `check_driver.sh --load`。已成功绑定的驱动不执行替换脚本。不要运行两个摄像头所有者。GPL驱动源码位于 `software/runtime/linux/driver/`。
