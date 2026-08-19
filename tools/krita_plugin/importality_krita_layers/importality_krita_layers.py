from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
import zipfile

from krita import Extension, Krita

from .visibility_rules_adapter import bind_rules_to_exports, collect_export_bindings

try:
    from PyQt6.QtCore import QBuffer, QIODevice
    from PyQt6.QtGui import QImage
    from PyQt6.QtWidgets import QFileDialog, QMessageBox
    _QT_WRITE_ONLY = QIODevice.OpenModeFlag.WriteOnly
    _QT_ARGB32 = QImage.Format.Format_ARGB32
except ImportError:
    from PyQt5.QtCore import QBuffer, QIODevice
    from PyQt5.QtGui import QImage
    from PyQt5.QtWidgets import QFileDialog, QMessageBox
    _QT_WRITE_ONLY = QIODevice.WriteOnly
    _QT_ARGB32 = QImage.Format_ARGB32

SCHEMA = "importality.krita.layers/v2"
SAFE_NAME = re.compile(r"^[\w][\w -]*$", re.UNICODE)


def _normalize_id(value: str) -> str:
    normalized = value.strip().lower().replace(" ", "_").replace("-", "_")
    while "__" in normalized:
        normalized = normalized.replace("__", "_")
    return normalized.strip("_")


def _logical_name(value: str) -> str:
    value = value.strip()
    if not value or not SAFE_NAME.fullmatch(value) or not _normalize_id(value):
        raise ValueError(f"Invalid logical name: {value!r}")
    return value


def _node_children(node):
    return list(node.childNodes()) if node is not None else []


def _as_png_bytes(image: QImage) -> bytes:
    buffer = QBuffer()
    if not buffer.open(_QT_WRITE_ONLY):
        raise RuntimeError("Could not open Krita PNG buffer")
    try:
        if not image.save(buffer, "PNG"):
            raise RuntimeError("Krita could not encode a PNG frame")
        return bytes(buffer.data())
    finally:
        buffer.close()


def _node_projection_png(node, width: int, height: int) -> bytes:
    raw = node.projectionPixelData(0, 0, width, height)
    if not raw:
        raise RuntimeError(f"Layer {node.name()!r} returned no pixel data")
    image = QImage(raw, width, height, width * 4, _QT_ARGB32).copy()
    if image.isNull():
        raise RuntimeError(f"Could not decode projection for {node.name()!r}")
    return _as_png_bytes(image)


def _find_export_root(doc):
    matches = [n for n in _node_children(doc.rootNode()) if n.name().strip() == "@export"]
    if len(matches) != 1:
        raise ValueError("Document must contain exactly one top-level group named @export")
    root = matches[0]
    if root.type() != "grouplayer":
        raise ValueError("@export must be a group layer")
    return root


def _manifest_for_document(doc, source_name: str):
    export_root = _find_export_root(doc)
    width, height = int(doc.width()), int(doc.height())
    if width <= 0 or height <= 0:
        raise ValueError("Document canvas must be non-empty")

    slots, frames = [], {}
    seen_slots = set()
    seen_animations = set()

    for slot_node in _node_children(export_root):
        if slot_node.type() != "grouplayer":
            raise ValueError(f"Export slot {slot_node.name()!r} must be a group layer")
        raw_slot = slot_node.name().strip()
        additive = raw_slot.startswith("+")
        slot_name = _logical_name(raw_slot[1:] if additive else raw_slot)
        normalized_slot = _normalize_id(slot_name)
        if normalized_slot in seen_slots:
            raise ValueError(f"Normalized slot collision: {normalized_slot}")
        seen_slots.add(normalized_slot)

        variants, seen_variants = [], set()
        default_count = 0
        for variant_node in _node_children(slot_node):
            raw_variant = variant_node.name().strip()
            is_default = raw_variant.startswith("*")
            variant_name = _logical_name(raw_variant[1:] if is_default else raw_variant)
            normalized_variant = _normalize_id(variant_name)
            if normalized_variant in seen_variants:
                raise ValueError(f"Normalized variant collision: {normalized_slot}/{normalized_variant}")
            seen_variants.add(normalized_variant)
            if is_default:
                default_count += 1
                if default_count > 1:
                    raise ValueError(f"Slot {slot_name!r} has more than one default variant")

            png = _node_projection_png(variant_node, width, height)
            archive_file = f"frames/{normalized_slot}/{normalized_variant}.png"
            frames[archive_file] = png
            variants.append({
                "name": variant_name,
                "raw_name": ("*" if is_default else "") + variant_name,
                "default": is_default,
                "blend_mode": "normal",
                "opacity": 255,
                "animated": False,
                "playback": {"direction": "forward", "repeat_count": 0},
                "frames": [{
                    "file": archive_file,
                    "source_time": 0,
                    "duration_frames": 1,
                    "sha256": hashlib.sha256(png).hexdigest(),
                }],
            })

        if not variants:
            raise ValueError(f"Slot {slot_name!r} has no variants")
        slots.append({
            "name": slot_name,
            "raw_name": ("+" if additive else "") + slot_name,
            "additive": additive,
            "variants": variants,
        })
        for variant in variants:
            marker = "*" if variant["default"] else ""
            prefix = "+" if additive else ""
            animation_name = prefix + slot_name + "/" + marker + variant["name"]
            if animation_name in seen_animations:
                raise ValueError(f"Duplicate animation name: {animation_name}")
            seen_animations.add(animation_name)

    if not slots:
        raise ValueError("@export must contain at least one slot")

    return {
        "schema": SCHEMA,
        "source": source_name,
        "source_sha256": "",
        "canvas": {"width": width, "height": height},
        "animation": {"fps": 1.0, "start": 0, "end": 0},
        "slots": slots,
    }, frames


def _project_root(start_path: str) -> str | None:
    current = os.path.abspath(start_path)
    if os.path.isfile(current):
        current = os.path.dirname(current)
    while True:
        if os.path.isfile(os.path.join(current, "project.godot")):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            return None
        current = parent


def _default_export_path(doc) -> str:
    source = doc.fileName()
    if not source:
        return ""
    project_root = _project_root(os.path.dirname(source))
    if project_root:
        try:
            inside = os.path.commonpath([project_root, os.path.abspath(source)]) == project_root
        except ValueError:
            inside = False
        if inside:
            target_dir = os.path.join(project_root, "assets", "importality")
            os.makedirs(target_dir, exist_ok=True)
            return os.path.join(target_dir, os.path.splitext(os.path.basename(source))[0] + ".kritalayers")
    return os.path.join(os.path.dirname(source), os.path.splitext(os.path.basename(source))[0] + ".kritalayers")


def export_bundle(doc, target_path: str) -> str:
    source_path = doc.fileName()
    if not source_path:
        raise ValueError("Save the Krita document before exporting")
    if not source_path.lower().endswith(".kra"):
        raise ValueError("The source document must be a .kra file")
    if doc.modified() and not doc.save():
        raise RuntimeError("Could not save the Krita document before export")
    with open(source_path, "rb") as handle:
        source_sha256 = hashlib.sha256(handle.read()).hexdigest()

    manifest, frames = _manifest_for_document(doc, os.path.basename(source_path))
    manifest["source_sha256"] = source_sha256
    manifest["visibility_rules"] = bind_rules_to_exports(doc, collect_export_bindings(doc))

    target_path = os.path.abspath(target_path)
    os.makedirs(os.path.dirname(target_path), exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix="kritalayers_", suffix=".zip", dir=os.path.dirname(target_path))
    os.close(fd)
    try:
        with zipfile.ZipFile(tmp_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            archive.writestr("manifest.json", json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
            for archive_file, data in sorted(frames.items()):
                archive.writestr(archive_file, data)
        os.replace(tmp_path, target_path)
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
    return target_path


class ImportalityKritaLayersExtension(Extension):
    def __init__(self, parent):
        super().__init__(parent)

    def setup(self):
        pass

    def createActions(self, window):
        export_action = window.createAction("importality_export_kritalayers", "Importality: Export .kritalayers", "tools/scripts")
        export_action.triggered.connect(self._export_active)

    def _export_active(self):
        doc = Krita.instance().activeDocument()
        if doc is None:
            QMessageBox.warning(None, "Importality Krita Layers", "Open or create a Krita document first.")
            return
        try:
            default_path = _default_export_path(doc)
            if not default_path:
                QMessageBox.warning(None, "Importality Krita Layers", "Save the .kra file before exporting.")
                return
            path, _ = QFileDialog.getSaveFileName(
                None,
                "Export Importality .kritalayers",
                default_path,
                "Krita Layer Bundle (*.kritalayers)",
            )
            if not path:
                return
            if not path.lower().endswith(".kritalayers"):
                path += ".kritalayers"
            output = export_bundle(doc, path)
            QMessageBox.information(None, "Importality Krita Layers", f"Exported .kritalayers:\n{output}")
        except Exception as exc:
            QMessageBox.critical(None, "Importality Krita Layers", str(exc))


Krita.instance().addExtension(ImportalityKritaLayersExtension(Krita.instance()))
