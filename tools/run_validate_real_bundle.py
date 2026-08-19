#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
from validate_kritalayers import validate

root = Path(__file__).resolve().parents[1]
bundles = list((root / ".ci-local" / "krita-runtime").glob("*.kritalayers"))
if len(bundles) != 1:
    raise SystemExit(f"Expected exactly one real Krita bundle, found {len(bundles)}")
errors = validate(bundles[0])
if errors:
    for error in errors:
        print(f"[FAIL] {error}")
    raise SystemExit(1)
print(f"[PASS] Real Krita bundle passes standalone contract validation: {bundles[0]}")
