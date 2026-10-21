"""Read local SLX XML only; store routing evidence on the research side."""
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "results" / "EXP-20261019-004"


def read_system(z, name):
    root = ET.fromstring(z.read(f"simulink/systems/{name}.xml"))
    blocks = {}
    for block in root.findall("Block"):
        props = {p.get("Name"): p.text for p in block.findall("P")}
        blocks[block.get("SID")] = {**block.attrib, "parameters": props}
    edges = []
    for line in root.findall("Line"):
        src = line.find("P[@Name='Src']")
        if src is not None:
            edges += [[src.text, dst.text] for dst in line.findall(".//P[@Name='Dst']")]
    return {"blocks": blocks, "edges": edges}


def audit():
    records = []
    for variant, filename in [("fixed", "EMA_Paper_Fixed.slx"), ("gradual", "EMA_Paper_Gradual.slx")]:
        path = ROOT / "matlab" / variant / filename
        with ZipFile(path) as z:
            systems = {name: read_system(z, name) for name in
                       ["system_root", "system_134", "system_1556", "system_1526", "system_1538"]}
        root = systems["system_root"]
        drive = systems["system_1538"]
        bus = systems["system_134"]
        current = systems["system_1526"]
        assert ["1464#out:1", "1596#in:1"] in root["edges"]
        assert root["blocks"]["1464"]["BlockType"] == "Inport"
        assert root["blocks"]["1597"]["parameters"]["GotoTag"] == root["blocks"]["1596"]["parameters"]["GotoTag"]
        assert ["1556#out:2", "1576#in:1"] in root["edges"]
        assert "is_a" in bus["blocks"]["136"]["parameters"]["OutputSignals"]
        assert "is_b" in bus["blocks"]["136"]["parameters"]["OutputSignals"]
        assert "is_c" in bus["blocks"]["136"]["parameters"]["OutputSignals"]
        for channel in (1, 2, 3):
            assert [f"136#out:{channel}", f"138#in:{channel}"] in bus["edges"]
        assert ["1529#out:1", "1533#in:1"] in current["edges"]
        assert ["1533#out:1", "1535#in:1"] in current["edges"]
        assert current["blocks"]["1535"]["BlockType"] == "Sum"
        assert ["1535#out:1", "1536#in:1"] in current["edges"]
        for channel in (2, 3):
            assert [f"1533#out:{channel}", f"1536#in:{channel}"] in current["edges"]
        assert ["1536#out:1", "1530#in:1"] in current["edges"]
        assert ["1544#out:1", "132#in:1"] in drive["edges"]
        for channel in (1, 2, 3):
            assert [f"132#out:{channel}", f"123#in:{channel}"] in drive["edges"]
        assert ["143#out:1", "1550#in:1"] in drive["edges"]
        assert ["143#out:2", "1554#in:1"] in drive["edges"]
        assert ["134#out:4", "1553#in:1"] in drive["edges"]
        records.append({"model": str(path.relative_to(ROOT)),
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "routing_assertions_passed": True, "systems": systems})
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "model_source_audit_private.json").write_text(
        json.dumps({"scope": "static_routing_only_no_simulation", "models": records},
                   ensure_ascii=False, indent=2), encoding="utf-8")
    print("Static source routing assertions passed for both local models.")


if __name__ == "__main__":
    audit()
