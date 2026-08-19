#!/usr/bin/env python3
"""Exercise the .kritalayers v2 contract with valid and hostile bundles."""
from __future__ import annotations

import copy
import hashlib
import json
import struct
import tempfile
import zipfile
from pathlib import Path
import sys
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_kritalayers import SCHEMA, validate  # noqa: E402


def _png(width: int = 2, height: int = 2, rgba: tuple[int, int, int, int] = (0, 0, 0, 0)) -> bytes:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    row = bytes(rgba) * width
    raw = b"".join(b"\x00" + row for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def _fixture(source_hash: str, frame_hash: str) -> dict:
    return {
        "schema": SCHEMA,
        "source": "synthetic.kra",
        "source_sha256": source_hash,
        "canvas": {"width": 2, "height": 2},
        "animation": {"fps": 12, "start": 0, "end": 0},
        "slots": [
            {
                "name": "BODY", "raw_name": "BODY", "additive": False,
                "variants": [{
                    "name": "base", "raw_name": "*base", "default": True,
                    "blend_mode": "normal", "opacity": 255, "animated": False,
                    "playback": {"direction": "forward", "repeat_count": 0},
                    "frames": [{"file": "frames/body/base.png", "source_time": 0, "duration_frames": 1, "sha256": frame_hash}],
                }],
            },
            {
                "name": "FACE", "raw_name": "FACE", "additive": False,
                "variants": [{
                    "name": "neutral", "raw_name": "*neutral", "default": True,
                    "blend_mode": "normal", "opacity": 255, "animated": False,
                    "playback": {"direction": "forward", "repeat_count": 0},
                    "frames": [{"file": "frames/face/neutral.png", "source_time": 0, "duration_frames": 1, "sha256": frame_hash}],
                }, {
                    "name": "smile", "raw_name": "smile", "default": False,
                    "blend_mode": "normal", "opacity": 255, "animated": False,
                    "playback": {"direction": "ping_pong", "repeat_count": 2},
                    "frames": [{"file": "frames/face/smile.png", "source_time": 0, "duration_frames": 2, "sha256": frame_hash}],
                }],
            },
            {
                "name": "DETAILS", "raw_name": "+DETAILS", "additive": True,
                "variants": [{
                    "name": "none", "raw_name": "*none", "default": True,
                    "blend_mode": "normal", "opacity": 255, "animated": False,
                    "playback": {"direction": "forward", "repeat_count": 0},
                    "frames": [{"file": "frames/details/none.png", "source_time": 0, "duration_frames": 1, "sha256": frame_hash}],
                }, {
                    "name": "cut_face", "raw_name": "cut_face", "default": False,
                    "blend_mode": "normal", "opacity": 255, "animated": False,
                    "playback": {"direction": "reverse", "repeat_count": 1},
                    "frames": [{"file": "frames/details/cut_face.png", "source_time": 0, "duration_frames": 1, "sha256": frame_hash}],
                }],
            },
        ],
        "visibility_rules": {
            "schema": "krita-sprite-visibility-rules/v1",
            "groups": [{"id": "face_smile", "expression": "FACE/smile", "nodes": ["FACE"]}],
        },
    }


def _write_bundle(path: Path, manifest: dict, frame: bytes, declared_files: list[str]) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, indent=2) + "\n")
        for filename in declared_files:
            archive.writestr(filename, frame)


def _expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"[PASS] {message}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="importality-kritalayers-contract-") as temp_name:
        root = Path(temp_name)
        source = root / "synthetic.kra"
        source.write_bytes(b"synthetic-krita-source\n")
        source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        frame = _png(rgba=(40, 80, 120, 255))
        frame_hash = hashlib.sha256(frame).hexdigest()
        base = _fixture(source_hash, frame_hash)
        files = [
            "frames/body/base.png",
            "frames/face/neutral.png",
            "frames/face/smile.png",
            "frames/details/none.png",
            "frames/details/cut_face.png",
        ]

        valid = root / "valid.kritalayers"
        _write_bundle(valid, base, frame, files)
        _expect(validate(valid) == [], "valid v2 bundle passes standalone validation")
        _expect(base["visibility_rules"]["groups"][0]["expression"] == "FACE/smile", "visibility rules are present as generic source metadata")

        bad_hash = copy.deepcopy(base)
        bad_hash["slots"][0]["variants"][0]["frames"][0]["sha256"] = "0" * 64
        bad_hash_path = root / "bad-hash.kritalayers"
        _write_bundle(bad_hash, bad_hash, frame, files)
        _expect(any("SHA-256 mismatch" in error for error in validate(bad_hash_path)), "corrupt frame hash is rejected")

        unsafe = copy.deepcopy(base)
        unsafe["slots"][0]["variants"][0]["frames"][0]["file"] = "../evil.png"
        unsafe_path = root / "unsafe-path.kritalayers"
        _write_bundle(unsafe_path, unsafe, frame, files)
        _expect(any("unsafe frame archive path" in error for error in validate(unsafe_path)), "path traversal is rejected")

        collision = copy.deepcopy(base)
        collision["slots"][0]["variants"].append(copy.deepcopy(collision["slots"][0]["variants"][0]))
        collision["slots"][0]["variants"][-1]["name"] = "base-"
        collision["slots"][0]["variants"][-1]["raw_name"] = "base-"
        collision["slots"][0]["variants"][-1]["default"] = False
        collision_path = root / "normalized-collision.kritalayers"
        _write_bundle(collision_path, collision, frame, files)
        _expect(any("normalized variant collision" in error for error in validate(collision_path)), "normalized-name collision is rejected")

    print("[PASS] Importality Krita Layers contract smoke complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
