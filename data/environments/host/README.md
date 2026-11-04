# 主机环境补充快照

`requirements_snapshot.txt`由已有 `D:/AI/.venv` 在本次整理时只读执行 `pip freeze --all` 得到。它固定记录当前已安装版本，用于依赖排查和恢复线索，不自动代表首次训练或量化时的完整锁定环境。

原COCO256量化时环境仍保存在 `models/quantization/coco80/environment.json`。当前与历史关键版本的比较在 `environment_snapshot.json`。若某个PyTorch构建来自私有/本地wheel，还需提供可公开获取的安装来源。

