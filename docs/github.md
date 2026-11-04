# GitHub仓库维护

本页说明本仓库的Git、Git LFS配置及提交前检查流程。

`.gitattributes`禁止Git自动转换换行符，保持冻结源码、原始报告及SHA256清单在Windows/Linux克隆后的字节一致。新增脚本采用LF；既有证据不批量改换行。数据集划分/校准JSON应正常入库，只有raw/downloads原始数据目录被忽略。

已筛选归档的evidence/sim/unit波形纳入Git LFS；其他临时生成的.wdb仍忽略。

## 本地提交前

1. 阅读根目录LICENSE、license.md及各文件已有授权声明。项目作者拥有版权且未另行标注许可证的原创代码采用MIT；保留独立许可证及第三方版权信息。
2. 安装Git与Git LFS。大于普通Git托管限制的checkpoint等文件已经列入 .gitattributes；不要跳过LFS直接提交实体大文件。
3. 按docs/reproduction.md核对部署入口与相对目录，确认公开文件不含个人访问凭据。
4. 修改材料后运行 `python tools/release_manifest.py --write` 更新清单，再运行 `--check`。
5. 确认仓库未包含工具安装目录、缓存、虚拟环境或公共完整数据集。

如需自行初始化本地Git仓库，可在此目录执行：

```sh
git init
git lfs install
git add .gitattributes .gitignore
git add .
git lfs ls-files
git status
```

上述命令仅用于初始化与暂存，已有本地仓库无需重复初始化。维护已有仓库时先同步远端，再提交实际文件变更和更新后的清单。LFS文件须连同其对象上传；仅上传pointer将导致他人无法部署。

## 内容规则

英文目录名与稳定文件名用于跨平台复现。工具和格式固定名（README.md、CMakeLists.txt、Makefile、BOOT.BIN、SKILL.md）以及模型内部BUNDLE_VERSION/SHA256SUMS保留，所有例外列于evidence/packaging/package_validation.json。历史收据的日期与源路径属于正文内容，不是发布路径。

