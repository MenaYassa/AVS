#!/usr/bin/env python3
"""Vendor the canonical JSON Schema files into the Flutter app.

`engine/schemas/*.json` is the single source of truth (architecture §5.2).
Flutter consumes a generated copy at `src/data/contract/`; a CI job and
`tests/test_contract.py` enforce parity (regenerate + diff).

Usage:
    uv run python scripts/vendor_schemas.py
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

ENGINE_SCHEMAS = Path(__file__).resolve().parent.parent / "schemas"
FLUTTER_CONTRACT = (
    Path(__file__).resolve().parent.parent.parent / "src" / "lib" / "data" / "contract"
)


def vendor() -> None:
    if not ENGINE_SCHEMAS.is_dir():
        sys.exit(f"no schemas dir at {ENGINE_SCHEMAS}")
    FLUTTER_CONTRACT.mkdir(parents=True, exist_ok=True)
    for source in sorted(ENGINE_SCHEMAS.glob("*.schema.json")):
        shutil.copy2(source, FLUTTER_CONTRACT / source.name)
        print(f"vendored {source.name}")


if __name__ == "__main__":
    vendor()
