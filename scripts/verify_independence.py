"""Read-only checks of the standalone paper package; Python standard library only."""
from __future__ import annotations

import csv
import hashlib
import json
import re
from pathlib import Path
from zipfile import ZipFile
import xml.etree.ElementTree as ET


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    errors, warnings = [], []
    checked = 0
    with (root / "provenance/copy_manifest.csv").open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    for row in rows:
        path = root / row["destination_relative"]
        if not path.is_file():
            errors.append(f"Missing imported file: {row['destination_relative']}")
        elif hashlib.sha256(path.read_bytes()).hexdigest() != row["destination_sha256"]:
            errors.append(f"Import baseline changed: {row['destination_relative']}")
        checked += 1
    for path in root.rglob("*"):
        if path.is_symlink():
            errors.append(f"Symbolic link: {path.relative_to(root)}")
    for path in (root / "matlab").rglob("*.m"):
        code = path.read_text(encoding="utf-8-sig")
        if re.search(r"[A-Za-z]:[\\/]", code):
            errors.append(f"Absolute runtime path: {path.relative_to(root)}")
        if "Unified_EMA_Motor" in code:
            errors.append(f"Old model name: {path.relative_to(root)}")
        first = next((line for line in code.splitlines() if line.strip().startswith("function ")), "")
        if first:
            match = re.search(r"(?:=\s*|function\s+)([A-Za-z]\w*)\s*\(", first)
            if match and match.group(1) != path.stem:
                errors.append(f"Function/filename mismatch: {path.relative_to(root)}")
        for name in re.findall(r"run\(fullfile\(folder,'([^']+\.m)'\)\)", code):
            if not (path.parent / name).is_file():
                errors.append(f"Missing local initializer: {path.relative_to(root)} -> {name}")
        for rel in re.findall(r'"(\.\./[^"\n]+\.md)"', code):
            resolved = (path.parent / rel).resolve()
            if not resolved.is_relative_to(root) or not resolved.is_file():
                errors.append(f"Unresolved local metadata path: {path.relative_to(root)} -> {rel}")
    for variant in ["fixed", "gradual"]:
        folder = root / "matlab" / variant
        path = folder / f"EMA_Paper_{variant.capitalize()}.slx"
        with ZipFile(path) as z:
            if z.testzip() is not None:
                errors.append(f"Invalid SLX archive: {path.name}")
            for name in z.namelist():
                if not name.endswith(".xml"):
                    continue
                try:
                    tree = ET.fromstring(z.read(name))
                except ET.ParseError as exc:
                    errors.append(f"Malformed XML: {path.name}/{name}: {exc}")
                    continue
                for p in tree.iter("P"):
                    key, value = p.get("Name", ""), p.text or ""
                    if re.search(r"[A-Za-z]:[\\/]", value):
                        errors.append(f"Absolute SLX path: {path.name}: {key}={value}")
                    if key in {"ModelName", "DataDictionary"} and value:
                        errors.append(f"External model/dictionary requires review: {path.name}: {value}")
                    if key == "SourceBlock" and value:
                        library = value.split("/")[0]
                        if not (library in {"simulink", "powerlib", "sflib", "simscape"} or library.startswith("sps")):
                            errors.append(f"Unreviewed custom library: {path.name}: {value}")
    if any(p.is_file() for p in (root / "data/agent_visible").rglob("*") if p.suffix != ".md"):
        warnings.append("Agent-visible data exists: inspect the field allowlist and truth separation.")
    required = ["README.md", "研究计划_详细版.md", "start_ema_agent_paper.m",
                "docs/独立性与迁移说明.md", "docs/工具接口与证据协议.md",
                "docs/实验任务与评价方案.md", "configs/research_protocol.json"]
    for rel in required:
        if not (root / rel).is_file():
            errors.append(f"Missing project document/entry: {rel}")
    runtime_path = root / "provenance/matlab_load_check.json"
    runtime_load_passed = False
    if runtime_path.is_file():
        runtime_load_passed = bool(json.loads(runtime_path.read_text(encoding="utf-8-sig")).get("loadAndSyntaxPassed", False))
    result = {"project_root": str(root), "imported_files_checked": checked,
              "static_check_passed": not errors, "errors": errors, "warnings": warnings,
              "runtime_model_load_verified": runtime_load_passed,
              "runtime_compile_or_simulation_verified": False,
              "note": "Static packaging verification only; does not prove numerical equivalence or runtime compatibility."}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(1 if errors else 0)


if __name__ == "__main__":
    main()
