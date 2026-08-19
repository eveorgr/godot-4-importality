#!/usr/bin/env python3
"""Standalone validation for the Importality Krita Layers v2 archive contract."""
from __future__ import annotations

import hashlib
import json
import re
import zipfile
from pathlib import Path

SCHEMA = "importality.krita.layers/v2"
_NAME_RE = re.compile(r"^[\w][\w -]*$", re.UNICODE)
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_DIRECTIONS = {"forward", "reverse", "ping_pong", "ping_pong_reverse"}


def _normalize_id(value: str) -> str:
    normalized = value.strip().lower().replace(" ", "_").replace("-", "_")
    while "__" in normalized:
        normalized = normalized.replace("__", "_")
    return normalized.strip("_")


def _logical_name(value: object) -> str | None:
    name = str(value).strip()
    if not name or _NAME_RE.fullmatch(name) is None or not _normalize_id(name):
        return None
    return name


def validate(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        with zipfile.ZipFile(path, "r") as archive:
            names = set(archive.namelist())
            if "manifest.json" not in names:
                return ["bundle has no manifest.json"]
            try:
                manifest = json.loads(archive.read("manifest.json"))
            except Exception as exc:
                return [f"manifest.json is invalid JSON: {exc}"]

            if not isinstance(manifest, dict):
                return ["manifest must be a JSON object"]
            if manifest.get("schema") != SCHEMA:
                errors.append(f"unsupported schema: {manifest.get('schema')!r}")

            canvas = manifest.get("canvas")
            if not isinstance(canvas, dict):
                errors.append("manifest has no canvas object")
                canvas = {}
            width, height = int(canvas.get("width", 0)), int(canvas.get("height", 0))
            if width <= 0 or height <= 0:
                errors.append("canvas dimensions must be positive")

            animation = manifest.get("animation")
            if not isinstance(animation, dict):
                errors.append("manifest has no animation object")
                animation = {}
            try:
                fps = float(animation.get("fps", 0.0))
            except (TypeError, ValueError):
                fps = 0.0
            if fps <= 0.0:
                errors.append("animation fps must be positive")

            slots = manifest.get("slots")
            if not isinstance(slots, list) or not slots:
                errors.append("slots must be a non-empty array")
                slots = []

            seen_slots: set[str] = set()
            seen_animations: set[str] = set()
            for slot in slots:
                if not isinstance(slot, dict):
                    errors.append("slot is not an object")
                    continue
                slot_name = _logical_name(slot.get("name", ""))
                if slot_name is None:
                    errors.append(f"invalid slot name: {slot.get('name')!r}")
                    continue
                additive = bool(slot.get("additive", False))
                expected_raw = ("+" if additive else "") + slot_name
                if str(slot.get("raw_name", "")).strip() != expected_raw:
                    errors.append(f"slot marker metadata mismatch: {slot_name}")
                normalized_slot = _normalize_id(slot_name)
                if normalized_slot in seen_slots:
                    errors.append(f"normalized slot collision: {normalized_slot}")
                seen_slots.add(normalized_slot)

                variants = slot.get("variants")
                if not isinstance(variants, list) or not variants:
                    errors.append(f"slot has no variants: {slot_name}")
                    continue
                seen_variants: set[str] = set()
                default_count = 0
                for variant in variants:
                    if not isinstance(variant, dict):
                        errors.append(f"variant is not an object: {slot_name}")
                        continue
                    variant_name = _logical_name(variant.get("name", ""))
                    if variant_name is None:
                        errors.append(f"invalid variant name in {slot_name}: {variant.get('name')!r}")
                        continue
                    is_default = bool(variant.get("default", False))
                    default_count += int(is_default)
                    if default_count > 1:
                        errors.append(f"more than one default variant: {slot_name}")
                    expected_variant_raw = ("*" if is_default else "") + variant_name
                    if str(variant.get("raw_name", "")).strip() != expected_variant_raw:
                        errors.append(f"variant marker metadata mismatch: {slot_name}/{variant_name}")
                    normalized_variant = _normalize_id(variant_name)
                    if normalized_variant in seen_variants:
                        errors.append(f"normalized variant collision: {normalized_slot}/{normalized_variant}")
                    seen_variants.add(normalized_variant)
                    if str(variant.get("blend_mode", "")).lower() != "normal" or int(variant.get("opacity", -1)) != 255:
                        errors.append(f"top-level variant is not normal/opaque: {slot_name}/{variant_name}")

                    playback = variant.get("playback")
                    if not isinstance(playback, dict) or playback.get("direction") not in _DIRECTIONS:
                        errors.append(f"invalid playback direction: {slot_name}/{variant_name}")
                    else:
                        repeat = playback.get("repeat_count", -1)
                        if not isinstance(repeat, (int, float)) or isinstance(repeat, bool) or repeat < 0 or int(repeat) != repeat:
                            errors.append(f"invalid repeat_count: {slot_name}/{variant_name}")

                    frames = variant.get("frames")
                    if not isinstance(frames, list) or not frames:
                        errors.append(f"variant has no frames: {slot_name}/{variant_name}")
                        continue
                    animation_name = f"{expected_raw}/{expected_variant_raw}"
                    if animation_name in seen_animations:
                        errors.append(f"duplicate animation: {animation_name}")
                    seen_animations.add(animation_name)

                    for frame in frames:
                        if not isinstance(frame, dict):
                            errors.append(f"frame is not an object: {animation_name}")
                            continue
                        archive_file = str(frame.get("file", ""))
                        parts = archive_file.split("/")
                        if (
                            not archive_file
                            or archive_file.startswith("/")
                            or "\\" in archive_file
                            or any(part in {"", ".", ".."} for part in parts)
                        ):
                            errors.append(f"unsafe frame archive path: {archive_file}")
                            continue
                        duration = frame.get("duration_frames", 0)
                        if not isinstance(duration, int) or isinstance(duration, bool) or duration <= 0:
                            errors.append(f"invalid frame duration: {archive_file}")
                        digest = str(frame.get("sha256", "")).lower()
                        if _SHA256_RE.fullmatch(digest) is None:
                            errors.append(f"invalid frame SHA-256 metadata: {archive_file}")
                            continue
                        if archive_file not in names:
                            errors.append(f"missing frame: {archive_file}")
                            continue
                        payload = archive.read(archive_file)
                        if hashlib.sha256(payload).hexdigest() != digest:
                            errors.append(f"frame SHA-256 mismatch: {archive_file}")

            rules = manifest.get("visibility_rules")
            if rules is not None and not isinstance(rules, dict):
                errors.append("visibility_rules metadata must be an object when present")
    except FileNotFoundError:
        errors.append(f"bundle not found: {path}")
    except zipfile.BadZipFile as exc:
        errors.append(f"invalid ZIP archive: {exc}")
    return errors


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    args = parser.parse_args()
    errors = validate(args.bundle)
    if errors:
        for error in errors:
            print(f"[FAIL] {error}")
        return 1
    print(f"[PASS] {args.bundle} satisfies Importality Krita Layers v2 contract")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
