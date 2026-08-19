#!/usr/bin/env python3
"""Generate a small deterministic .kritalayers v2 bundle for importer CI."""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import zipfile
from pathlib import Path
import zlib

SCHEMA = "importality.krita.layers/v2"


def png(rgba: tuple[int, int, int, int], width: int = 2, height: int = 2) -> bytes:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    row = bytes(rgba) * width
    raw = b"".join(b"\x00" + row for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def frame(path: str, pixels: tuple[int, int, int, int]) -> tuple[str, bytes, str]:
    data = png(pixels)
    return path, data, hashlib.sha256(data).hexdigest()


def build_manifest(frames: list[tuple[str, bytes, str]]) -> dict:
    by_path = {path: digest for path, _data, digest in frames}
    return {
        "schema": SCHEMA,
        "source": "synthetic-importality.kra",
        "source_sha256": hashlib.sha256(b"synthetic-importality-source").hexdigest(),
        "canvas": {"width": 2, "height": 2},
        "animation": {"fps": 12.0, "start": 0, "end": 0},
        "slots": [
            {
                "name": "BODY", "raw_name": "BODY", "additive": False,
                "variants": [{
                    "name": "base", "raw_name": "*base", "default": True,
                    "blend_mode": "normal", "opacity": 255, "animated": False,
                    "playback": {"direction": "forward", "repeat_count": 0},
                    "frames": [{"file": "frames/body/base.png", "source_time": 0, "duration_frames": 1, "sha256": by_path["frames/body/base.png"]}],
                }],
            },
            {
                "name": "FACE", "raw_name": "FACE", "additive": False,
                "variants": [{
                    "name": "neutral", "raw_name": "*neutral", "default": True,
                    "blend_mode": "normal", "opacity": 255, "animated": False,
                    "playback": {"direction": "forward", "repeat_count": 0},
                    "frames": [{"file": "frames/face/neutral.png", "source_time": 0, "duration_frames": 1, "sha256": by_path["frames/face/neutral.png"]}],
                }, {
                    "name": "smile", "raw_name": "smile", "default": False,
                    "blend_mode": "normal", "opacity": 255, "animated": False,
                    "playback": {"direction": "ping_pong", "repeat_count": 2},
                    "frames": [{"file": "frames/face/smile.png", "source_time": 0, "duration_frames": 2, "sha256": by_path["frames/face/smile.png"]}],
                }],
            },
            {
                "name": "DETAILS", "raw_name": "+DETAILS", "additive": True,
                "variants": [{
                    "name": "none", "raw_name": "*none", "default": True,
                    "blend_mode": "normal", "opacity": 255, "animated": False,
                    "playback": {"direction": "forward", "repeat_count": 0},
                    "frames": [{"file": "frames/details/none.png", "source_time": 0, "duration_frames": 1, "sha256": by_path["frames/details/none.png"]}],
                }, {
                    "name": "cut_face", "raw_name": "cut_face", "default": False,
                    "blend_mode": "normal", "opacity": 255, "animated": False,
                    "playback": {"direction": "reverse", "repeat_count": 1},
                    "frames": [{"file": "frames/details/cut_face.png", "source_time": 0, "duration_frames": 1, "sha256": by_path["frames/details/cut_face.png"]}],
                }],
            },
        ],
        "visibility_rules": {
            "schema": "krita-sprite-visibility-rules/v1",
            "groups": [{
                "id": "face_smile",
                "expression": "FACE/smile",
                "nodes": ["FACE", "smile"],
            }],
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    frames = [
        frame("frames/body/base.png", (45, 100, 180, 255)),
        frame("frames/face/neutral.png", (240, 190, 160, 255)),
        frame("frames/face/smile.png", (180, 70, 100, 255)),
        frame("frames/details/none.png", (0, 0, 0, 0)),
        frame("frames/details/cut_face.png", (180, 40, 50, 255)),
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    manifest = build_manifest(frames)
    with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
        for path, data, _digest in frames:
            archive.writestr(path, data)
    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
