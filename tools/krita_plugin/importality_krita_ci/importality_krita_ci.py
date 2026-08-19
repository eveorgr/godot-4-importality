from __future__ import annotations

import hashlib
import json
import os
import sys
import time
import zipfile
from pathlib import Path

_STAGE_PATH = os.environ.get("IMPORTALITY_KRITA_CI_STAGE", "").strip()
if _STAGE_PATH:
    try:
        stage = Path(_STAGE_PATH).resolve()
        stage.parent.mkdir(parents=True, exist_ok=True)
        with stage.open("a", encoding="utf-8") as handle:
            handle.write("[startup] Importality Krita CI plugin module discovered\n")
    except Exception:
        pass

from krita import Extension, Krita

try:
    from PyQt6.QtCore import QByteArray, QTimer
    from PyQt6.QtGui import QColor
    from PyQt6.QtWidgets import QApplication
    QT_BINDING = "PyQt6"
except ImportError:
    from PyQt5.QtCore import QByteArray, QTimer
    from PyQt5.QtGui import QColor
    from PyQt5.QtWidgets import QApplication
    QT_BINDING = "PyQt5"

PLUGIN_NAME = "importality_krita_layers"


def _project_root() -> Path:
    value = os.environ.get("IMPORTALITY_KRITA_CI_PROJECT_ROOT", "").strip()
    if not value:
        raise RuntimeError("IMPORTALITY_KRITA_CI_PROJECT_ROOT is not set")
    return Path(value).resolve()


def _result_path() -> Path:
    value = os.environ.get("IMPORTALITY_KRITA_CI_RESULT", "").strip()
    if not value:
        raise RuntimeError("IMPORTALITY_KRITA_CI_RESULT is not set")
    return Path(value).resolve()


def _stage_path() -> Path:
    value = os.environ.get("IMPORTALITY_KRITA_CI_STAGE", "").strip()
    if not value:
        raise RuntimeError("IMPORTALITY_KRITA_CI_STAGE is not set")
    return Path(value).resolve()


def _log(message: str) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {message}"
    print(line, flush=True)
    try:
        path = _stage_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except Exception:
        pass


def _assert(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def _find_target_plugin() -> Path:
    resource_root = os.environ.get("IMPORTALITY_KRITA_CI_RESOURCE_ROOT", "").strip()
    candidates = []
    if resource_root:
        candidates.append(Path(resource_root) / "pykrita" / PLUGIN_NAME)
    candidates.append(Path(__file__).resolve().parents[1] / "importality_krita_layers")
    for candidate in candidates:
        if (candidate / "importality_krita_layers.py").is_file():
            return candidate
    raise RuntimeError("Installed Importality Krita Layers plugin was not found")


def _paint_rect(layer, x0: int, y0: int, x1: int, y1: int, color: QColor) -> None:
    width, height = x1 - x0, y1 - y0
    if width <= 0 or height <= 0:
        return
    pixel = bytes((color.blue(), color.green(), color.red(), color.alpha()))
    layer.setPixelData(QByteArray(pixel * (width * height)), x0, y0, width, height)


def create_test_document():
    doc = Krita.instance().createDocument(96, 96, "Importality Krita CI Test", "RGBA", "U8", "", 72.0)
    root = doc.rootNode()
    export_root = doc.createNode("@export", "grouplayer")
    root.addChildNode(export_root, None)

    def add_slot(name: str):
        slot = doc.createNode(name, "grouplayer")
        export_root.addChildNode(slot, None)
        return slot

    def add_layer(slot, name: str):
        layer = doc.createNode(name, "paintlayer")
        slot.addChildNode(layer, None)
        return layer

    body = add_slot("BODY")
    _paint_rect(add_layer(body, "*base"), 18, 42, 78, 88, QColor(55, 110, 190, 255))

    face = add_slot("FACE")
    _paint_rect(add_layer(face, "*neutral"), 28, 18, 68, 50, QColor(240, 190, 160, 255))
    _paint_rect(add_layer(face, "smile"), 40, 36, 56, 40, QColor(180, 70, 95, 255))

    details = add_slot("+DETAILS")
    add_layer(details, "*none")
    _paint_rect(add_layer(details, "cut_face"), 46, 24, 50, 34, QColor(170, 45, 55, 255))

    doc.setName("Importality Krita CI Test")
    doc.setActiveNode(body.childNodes()[0])
    doc.setModified(True)
    return doc


def _verify_bundle(bundle_path: Path, kra_path: Path) -> dict:
    _log("Validating real Importality .kritalayers output...")
    _assert(bundle_path.is_file(), f"Bundle was not created: {bundle_path}")
    _assert(kra_path.is_file(), f"KRA was not created: {kra_path}")
    source_hash = hashlib.sha256(kra_path.read_bytes()).hexdigest()

    with zipfile.ZipFile(bundle_path, "r") as archive:
        names = archive.namelist()
        _assert("manifest.json" in names, "Bundle is missing manifest.json")
        manifest = json.loads(archive.read("manifest.json"))
        _assert(manifest.get("schema") == "importality.krita.layers/v2", "Unexpected bundle schema")
        _assert(manifest.get("source_sha256") == source_hash, "Source SHA-256 mismatch")

        expected = {
            "BODY": {"base"},
            "FACE": {"neutral", "smile"},
            "DETAILS": {"none", "cut_face"},
        }
        slots = manifest.get("slots", [])
        _assert({slot["name"] for slot in slots} == set(expected), "Unexpected exported slots")
        frame_count = 0
        for slot in slots:
            _assert({variant["name"] for variant in slot["variants"]} == expected[slot["name"]], f"Unexpected variants for {slot['name']}")
            _assert(sum(1 for variant in slot["variants"] if variant["default"]) == 1, f"Expected one default in {slot['name']}")
            if slot["name"] == "DETAILS":
                _assert(slot["additive"] is True, "DETAILS must be additive")
            for variant in slot["variants"]:
                for frame in variant["frames"]:
                    _assert(frame["file"] in names, f"Missing frame: {frame['file']}")
                    payload = archive.read(frame["file"])
                    _assert(hashlib.sha256(payload).hexdigest() == frame["sha256"], f"Frame SHA-256 mismatch: {frame['file']}")
                    frame_count += 1
        rules = manifest.get("visibility_rules", {})
        _assert(isinstance(rules, dict), "visibility_rules must remain generic object metadata")

    return {
        "schema": manifest["schema"],
        "source_sha256": source_hash,
        "slots": len(slots),
        "frames": frame_count,
        "visibility_rules_type": type(manifest.get("visibility_rules")).__name__,
    }


def _run() -> None:
    status, error, details, doc = "passed", None, {}, None
    try:
        _log(f"CI extension loaded in Krita {Krita.instance().version()} using {QT_BINDING}")
        project_root = _project_root()
        result_path = _result_path()
        plugin_dir = _find_target_plugin()
        sys.path.insert(0, str(plugin_dir.parent))
        module = __import__(PLUGIN_NAME + ".importality_krita_layers", fromlist=["*"])
        for name in ("export_bundle", "ImportalityKritaLayersExtension", "_manifest_for_document", "_default_export_path"):
            _assert(hasattr(module, name), f"Importality plugin member missing: {name}")
        _assert(Krita.instance().action("importality_export_kritalayers") is not None, "Importality export action was not registered")
        _log("Importality Krita Layers plugin loaded and action registered")

        ci_dir = project_root / ".ci-local" / "krita-runtime"
        ci_dir.mkdir(parents=True, exist_ok=True)
        kra_path = ci_dir / "Importality_Krita_CI_Test.kra"
        bundle_path = ci_dir / "Importality_Krita_CI_Test.kritalayers"
        result_path.parent.mkdir(parents=True, exist_ok=True)
        kra_path.unlink(missing_ok=True)
        bundle_path.unlink(missing_ok=True)

        _log("Creating generic Importality CI document...")
        doc = create_test_document()
        window = Krita.instance().activeWindow()
        _assert(window is not None, "Krita did not provide an active window")
        _assert(window.addView(doc) is not None, "Krita failed to add a view")
        _log("Saving .kra...")
        _assert(doc.saveAs(str(kra_path)), "Krita failed to save .kra")
        _assert(kra_path.is_file(), "Krita reported success but .kra is missing")

        default_path = Path(module._default_export_path(doc)).resolve()
        _assert(default_path.suffix.lower() == ".kritalayers", f"Importality default export path is not a .kritalayers path: {default_path}")
        _log(f"Importality default export destination: {default_path}")
        _log(f"CI artifact destination: {bundle_path}")
        module.export_bundle(doc, str(bundle_path))
        details = _verify_bundle(bundle_path, kra_path)
        _log("Real Krita -> .kritalayers validation passed")
    except Exception as exc:
        status = "failed"
        error = f"{type(exc).__name__}: {exc}"
        _log(f"FAIL: {error}")
    finally:
        try:
            result_path = _result_path()
            result_path.parent.mkdir(parents=True, exist_ok=True)
            result_path.write_text(json.dumps({"status": status, "krita_version": str(Krita.instance().version()), "qt_binding": QT_BINDING, "error": error, "details": details}, indent=2) + "\n", encoding="utf-8")
            _log("Result written")
        except Exception as exc:
            _log(f"Could not write result.json: {type(exc).__name__}: {exc}")
        try:
            if doc is not None:
                doc.close()
        except Exception:
            pass
        app = QApplication.instance()
        if app is not None:
            QTimer.singleShot(0, app.quit)


class ImportalityKritaCISmokeExtension(Extension):
    def __init__(self, parent):
        super().__init__(parent)
        _log("Importality Krita CI extension instance created")

    def setup(self):
        _log("Importality Krita CI extension setup complete; scheduling smoke test")
        QTimer.singleShot(250, _run)

    def createActions(self, _window):
        pass


Krita.instance().addExtension(ImportalityKritaCISmokeExtension(Krita.instance()))
