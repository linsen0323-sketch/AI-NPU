#!/usr/bin/env python3
"""Generate and verify a portable release inventory without vendor dependencies."""
from __future__ import annotations
import argparse
import ast
import csv
import hashlib
import json
import re
from collections import Counter
from pathlib import Path
from datetime import datetime, timezone

EXCLUDED = {
    "manifests/files.sha256", "manifests/files.json",
    "manifests/file_catalog.csv", "evidence/packaging/package_validation.json",
}
IGNORED_PARTS = {".git", "__pycache__", ".Xil", "work", "tmp", ".venv"}
FIXED_NAMES = {"README.md", "LICENSE", "NOTICE", "COPYING", "AUTHORS",
               "CMakeLists.txt", "Makefile", "BOOT.BIN", "BUNDLE_VERSION", "SKILL.md",
               "SHA256SUMS", "FILES.sha256"}
LAYOUT_PREFIXES = {
    "software/": "src/software/", "host/": "src/host/",
    "third_party/": "src/third_party/", "models/": "data/models/",
}


def current_target_path(relative: str) -> str:
    """Resolve historical repository targets without changing package ABI paths."""
    for before, after in LAYOUT_PREFIXES.items():
        if relative.startswith(before):
            return after + relative[len(before):]
    return relative

PURPOSE_HINTS = {
    "camera_bridge.c": "Linux用户态与共享C预处理/后处理算法的桥接ABI",
    "unified_npu.c": "NPU字符设备驱动、寄存器访问、共享DDR、时钟与任务生命周期",
    "unified_npu_uapi.h": "Linux内核与用户态共用的ioctl结构和ABI定义",
    "linux_camera.py": "摄像头运行循环、按键状态、任务提交与结果显示",
    "npu_runtime.py": "Linux设备封装、模型加载、推理提交和完成处理",
    "manifest.py": "生产运行时的模型清单及部署合同检查",
    "plan_manifest.py": "离线模型派生与执行计划的结构检查合同",
    "runtime_manifest.py": "最终三模型包的严格Linux运行合同",
    "service.py": "SysV托管的单实例摄像头服务、日志和退出管理",
    "configure_autostart.py": "开机服务配置与安装布局检查",
    "compiler.py": "QDQ ONNX到整数执行图的主机编译器",
    "package.py": "AIPKG模型镜像组织、读写和格式校验",
    "pack_runtime_weights.py": "WPK1运行时权重布局重排；不执行浮点量化",
    "mixed_precision_ptq.py": "原YOLOX混合精度PTQ数值核心",
    "export_mixed_precision_onnx.py": "混合精度量化参考到QDQ ONNX的导出",
    "build_requant_params.py": "ResNet整数重定点参数推导",
    "verify_full_resnet18_int8.py": "ResNet冻结整数Golden数值规格与比较实现",
    "ai_camera_math.c": "固定点检测框解码、数值换算和NMS共享算法",
    "ai_camera_math_tables.h": "共享固定点数学查找表",
    "ai_resnet_score_lut.h": "ResNet分类置信度计算查找表",
    "ai_camera_memory.c": "相机帧槽、模型槽与工作区的DDR管理",
    "ai_display.c": "PS侧结果发布、帧身份和显示状态管理",
    "ai_board_keys.c": "板上实体按键读取与控制支持",
    "ai_detector.c": "推理任务和检测结果处理状态机",
    "ai_preprocess.c": "图像缩放、像素格式与模型输入组织",
    "npu_shared_pe.sv": "共享并行乘加计算阵列",
    "npu_graph_plan_backend.sv": "统一计算图执行计划后端",
    "npu_plan_dispatch.sv": "算子指令分发及执行资源调度",
    "npu_stream_weight_loader.sv": "流式权重读取和片上缓存装载",
    "npu_input_tile_loader.sv": "输入特征图分块读取、边界和缓存装载",
    "npu_conv2d_stream_engine.sv": "流式卷积执行与数据供给协调",
}

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def files(root: Path):
    for path in sorted(root.rglob("*")):
        if path.is_file() and not any(part in IGNORED_PARTS for part in path.relative_to(root).parts):
            yield path

def source_records(root: Path):
    records = {}
    for path in sorted((root / "evidence/packaging").glob("*_files.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        entries = data if isinstance(data, list) else data.get("records", data.get("files", []))
        for item in entries:
            original_target = item.get("destination", item.get("target", item.get("destination_path", ""))).replace("\\", "/")
            if not original_target:
                continue
            target = current_target_path(original_target)
            current = (root / target).resolve()
            if not current.is_relative_to(root.resolve()):
                raise ValueError(f"Historical target escapes the repository: {original_target}")
            if not current.is_file():
                continue
            record = {
                "path": target,
                "original_target": original_target,
                "source": item.get("source_path", item.get("source")),
                "source_sha256": item.get("source_sha256"),
                "sha256": sha256(current),
                "purpose": item.get("purpose", item.get("description", "")),
                "modified": item.get("edited", item.get("modified", False)),
                "record": path.relative_to(root).as_posix(),
            }
            if record["source_sha256"] and record["sha256"] != record["source_sha256"]:
                record["modified"] = True
            records[target] = record
    return records

def description(path: Path, root: Path, record: dict | None) -> str:
    rel = path.relative_to(root).as_posix()
    if record and record.get("purpose"):
        result = record["purpose"]
    elif rel.startswith("docs/"):
        result = "项目文档：" + path.stem.replace("_", " ")
    elif rel.startswith("report/"):
        result = "报告、展示材料或真实交互记录：" + path.stem.replace("_", " ")
    elif rel.startswith("skill/"):
        result = "可复用技能包工作流或完整性校验工具"
    elif rel.startswith("tools/"):
        result = "项目的维护、清单或检查工具"
    elif rel.startswith("evidence/"):
        result = "验证证据或整理检查记录；按正文标注阶段解读"
    elif path.name == ".gitkeep":
        result = "保留待补空目录；不代表已有验证结果"
    else:
        role = {"hardware": "PL硬件设计", "src": "当前工程设计源码", "software": "PS与Linux软件",
                "host": "主机模型工具", "models": "模型输入、参数或部署产物",
                "data": "数据划分、校准或参考结果", "board": "板端部署文件",
                "build": "构建脚本或实现报告", "sim": "仿真材料",
                "third_party": "第三方依赖源码及授权"}.get(rel.split("/")[0], "项目入口或配置")
        result = role + "：" + path.stem.replace("_", " ")
    if path.name in PURPOSE_HINTS:
        result = PURPOSE_HINTS[path.name] + "; " + result
    if path.suffix in {".sv", ".v"}:
        text = path.read_text(encoding="utf-8", errors="replace")
        modules = re.findall(r"(?m)^\s*module\s+(\w+)", text)
        if modules:
            result += "; modules=" + ",".join(modules)
    elif path.suffix == ".py":
        try:
            tree = ast.parse(path.read_text(encoding="utf-8-sig"))
            doc = ast.get_docstring(tree)
            if doc:
                result += "; " + doc.splitlines()[0][:180]
        except (SyntaxError, UnicodeError):
            pass
    return result

def write(root: Path):
    records = source_records(root)
    manifest_dir = root / "manifests"
    manifest_dir.mkdir(parents=True, exist_ok=True)
    source_map = {"schema": 1, "note": "Source paths are provenance only; build uses package-relative paths.",
                  "layout_mapping": LAYOUT_PREFIXES,
                  "files": sorted(records.values(), key=lambda item: item["path"])}
    (manifest_dir / "source_map.json").write_text(json.dumps(source_map, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    listing = list(files(root))
    rows = []
    for path in listing:
        rel = path.relative_to(root).as_posix()
        rows.append({"path": rel, "bytes": path.stat().st_size if rel not in EXCLUDED else "",
                     "purpose": description(path, root, records.get(rel)),
                     "origin": "adapted" if records.get(rel, {}).get("modified") else "copied" if rel in records else "authored_or_generated",
                     "source": records.get(rel, {}).get("source") or ""})
    # Catalog also documents its own generated maintenance files.
    known = {row["path"] for row in rows}
    for rel, purpose in [("manifests/file_catalog.csv", "逐文件用途、大小与来源目录"),
                         ("manifests/files.json", "完整性清单的结构化文件索引"),
                         ("manifests/files.sha256", "受保护文件的SHA256清单；不包含自身"),
                         ("evidence/packaging/package_validation.json", "当前提交包完整性、命名与语法检查结果")]:
        if rel not in known:
            rows.append({"path": rel, "bytes": "", "purpose": purpose, "origin": "authored_or_generated", "source": ""})
    with (manifest_dir / "file_catalog.csv").open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=["path", "bytes", "purpose", "origin", "source"])
        writer.writeheader()
        writer.writerows(sorted(rows, key=lambda item: item["path"]))
    protected = []
    for path in files(root):
        rel = path.relative_to(root).as_posix()
        if rel not in EXCLUDED:
            protected.append({"path": rel, "bytes": path.stat().st_size, "sha256": sha256(path)})
    (manifest_dir / "files.json").write_text(json.dumps({"schema": 1, "excluded_self_metadata": sorted(EXCLUDED), "files": protected}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (manifest_dir / "files.sha256").write_text("".join(item["sha256"] + "  " + item["path"] + "\n" for item in protected), encoding="utf-8")
    return check(root, emit=True)

def check(root: Path, emit: bool = True):
    inventory = json.loads((root / "manifests/files.json").read_text(encoding="utf-8"))
    expected = {entry["path"]: entry for entry in inventory["files"]}
    actual = {path.relative_to(root).as_posix(): path for path in files(root) if path.relative_to(root).as_posix() not in EXCLUDED}
    issues = []
    ledger = root / "manifests/files.sha256"
    expected_ledger = "".join(item["sha256"] + "  " + item["path"] + "\n" for item in inventory["files"])
    if not ledger.is_file() or ledger.read_text(encoding="utf-8") != expected_ledger:
        issues.append({"kind": "ledger_mismatch", "path": "manifests/files.sha256"})
    for rel in sorted(expected.keys() - actual.keys()):
        issues.append({"kind": "missing", "path": rel})
    for rel in sorted(actual.keys() - expected.keys()):
        issues.append({"kind": "unlisted", "path": rel})
    for rel in sorted(expected.keys() & actual.keys()):
        try:
            if sha256(actual[rel]) != expected[rel]["sha256"]:
                issues.append({"kind": "hash_mismatch", "path": rel})
        except OSError as exc:
            issues.append({"kind": "changed_while_checking", "path": rel, "error": str(exc)})
    syntax = []
    naming_exceptions = []
    dated_names = []
    for path in files(root):
        rel = path.relative_to(root).as_posix()
        if path.suffix == ".py":
            try:
                ast.parse(path.read_text(encoding="utf-8-sig"), filename=rel)
            except (SyntaxError, UnicodeError) as exc:
                syntax.append({"path": rel, "error": str(exc)})
        for part in path.relative_to(root).parts:
            if not re.fullmatch(r"[a-z0-9_.-]+", part):
                naming_exceptions.append({"path": rel, "component": part,
                    "reason": "tool_or_protocol_name" if part in FIXED_NAMES else "review_required"})
            if re.search(r"(?:19|20)\d{6}", part):
                dated_names.append(rel)
    forbidden_paths = [path.relative_to(root).as_posix() for path in root.rglob("*")
                       if path.is_file() and not any(part in {".git", "work", "tmp", ".venv"}
                                                    for part in path.relative_to(root).parts)
                       and any(part in {"node_modules", "__pycache__", ".Xil"}
                               for part in path.relative_to(root).parts)]
    result = {"schema": 1, "checked_at_utc": datetime.now(timezone.utc).isoformat(),
              "integrity_pass": not issues, "python_syntax_pass": not syntax,
              "protected_files": len(expected), "total_files": len(list(files(root))),
              "bytes": sum(path.stat().st_size for path in files(root)),
              "integrity_issues": issues, "python_syntax_issues": syntax,
              "naming_exceptions": naming_exceptions, "dated_path_names": sorted(set(dated_names)),
              "forbidden_paths": forbidden_paths,
              "validation_scope": "package integrity and syntax, not training, full FPGA implementation or board replay"}
    if emit:
        output = root / "evidence/packaging/package_validation.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: result[key] for key in ["integrity_pass", "python_syntax_pass", "protected_files", "total_files", "bytes"]}, ensure_ascii=False))
    return 0 if not issues and not syntax else 1

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--write", action="store_true", help="Refresh catalogs after an authorized release change")
    group.add_argument("--check", action="store_true", help="Verify the packaged inventory")
    args = parser.parse_args()
    root = args.root.resolve()
    return write(root) if args.write else check(root)

if __name__ == "__main__":
    raise SystemExit(main())

