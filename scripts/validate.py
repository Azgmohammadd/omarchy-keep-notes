#!/usr/bin/env python3
from __future__ import annotations

import json
import py_compile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
assert manifest["schemaVersion"] == 1
assert manifest["id"] == "dev.zed.keep-notes"
assert manifest["name"] == "Keep Notes"
assert manifest["version"] == "1.0.0"
assert manifest["kinds"] == ["panel"]
assert manifest["entryPoints"]["panel"] == "Panel.qml"
assert "keepLoaded" not in manifest

required_files = [
    ROOT / "Panel.qml",
    ROOT / "bin" / "keep-notes",
    ROOT / "lib" / "keep_notes.py",
    ROOT / "README.md",
    ROOT / "LICENSE",
]
for path in required_files:
    assert path.exists(), f"missing {path.relative_to(ROOT)}"

py_compile.compile(str(ROOT / "lib" / "keep_notes.py"), doraise=True)

qml = (ROOT / "Panel.qml").read_text(encoding="utf-8")
for needle in [
    'text: "Keep Notes"',
    'id: authProc',
    'stdinEnabled: true',
    'event.key === Qt.Key_J',
    '"Connect & Sync"',
    '/.config/omarchy/plugins/',
]:
    assert needle in qml, f"missing QML marker: {needle}"

print("Keep Notes validation passed.")
