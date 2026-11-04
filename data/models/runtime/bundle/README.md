npu100 三模型 Linux SD 包
整理日期：2026-11-02

请将整个 npu100_models 目录复制到板端：
    /home/petalinux/npu100_models

三份模型：
    ID 1  ResNet18 160x160    models/m1/model.bin
    ID 3  YOLOX-S NEU6 256    models/m3/model.bin
    ID 4  YOLOX-S COCO80 256  coco80/model.bin

这些 model.bin 与当前 npu100 软件目录要求的冻结模型逐字节一致。
本次只复制原模型并更新打包清单，没有重新训练、量化或编译模型。
input.bin 是随原模型保留的固定样本，不是摄像头运行时输入。

复制后在板上校验：
    cd /home/petalinux/npu100_models
    sha256sum -c SHA256SUMS

安装当前 npu100 Linux 软件后，可继续执行文件预检：
    python3 /opt/npu100/preflight.py --bundle /home/petalinux/npu100_models --files-only

Linux 使用 schema 2 的 manifest.json，其中完整登记了三个模型。
manifest.bin 仅为兼容历史裸机加载器保留两个记录，不供 Linux 三模型加载使用。

本包通过的是本地文件、哈希、CRC、描述符和内存范围检查。
manifest 中的 accuracy_validated、rtl_verified、board_verified 仍为 false；
本次打包没有执行模型精度、RTL 或上板验证。

运行前还需完成匹配 PL 的 Linux 启动文件、设备树、驱动和服务部署。
设备树须在启动时将 [0x10000000,0x20000000) 预留为 no-map 内存。
仅复制本目录不会启动 NPU，也不会自动向 DDR 写入模型。
