# 发布包静态校验

安装 Python 3.11 或更新版本，克隆仓库后先执行 `git lfs pull`，再在仓库根目录执行：

```sh
python -B tools/verify_release.py
```

也可从其他目录指定仓库位置：

```sh
python -B /path/to/AI-NPU/tools/verify_release.py --root /path/to/AI-NPU
```

脚本只使用 Python 标准库，复用现有校验器完成以下检查：

- 必需校验文件存在，Git LFS 文件已下载为实体。
- 发布清单与受保护文件的 SHA256 一致，Python 文件可通过语法检查。
- 独立 SHA256 清单校验器复核文件完整性。
- 三模型包身份、输入哈希、描述符、固定 DDR 地址及运行时二进制合同正确。

输出为 JSON，`passed: true` 且退出码为 `0` 表示上述静态检查通过；失败返回非零退出码。现有发布清单检查会刷新 `evidence/packaging/package_validation.json`，其余源码、模型和部署产物不会被修改。

此检查不调用 Vivado、不访问开发板、不运行推理或 RTL 仿真，也不计算数据集精度。上板操作按 [部署流程](../docs/reproduction.md) 执行；已有定向仿真材料的入口见 [单元测试说明](../sim/rtl/unit/README.md)。

维护者在完成有意的文件修改后，应先确认变更范围，再更新发布清单并重跑检查：

```sh
python -B tools/release_manifest.py --write
python -B tools/verify_release.py
```

普通使用者发现文件缺失或哈希不符时，应重新获取对应文件或执行 `git lfs pull`；不要用 `--write` 把损坏的文件重新登记为正确版本。
