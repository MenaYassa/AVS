"""Contract parity: Flutter-vendored copy must match engine/schemas (§5.2).

The CI contract job regenerates and diffs; this test enforces the same
invariant locally so drift is caught in the engine test suite too.
"""

from __future__ import annotations

from pathlib import Path

ENGINE_SCHEMAS = Path(__file__).resolve().parent.parent / "schemas"
FLUTTER_CONTRACT = (
    Path(__file__).resolve().parent.parent.parent / "src" / "lib" / "data" / "contract"
)


def _schema_files(directory: Path) -> set[str]:
    return {p.name for p in directory.glob("*.schema.json")}


def test_flutter_vendored_schemas_match_engine() -> None:
    assert FLUTTER_CONTRACT.is_dir(), (
        "vendored contract missing; run: uv run python scripts/vendor_schemas.py"
    )
    assert _schema_files(ENGINE_SCHEMAS) == _schema_files(FLUTTER_CONTRACT), (
        "schema filename set drifted between engine/ and src/lib/data/contract/"
    )
    for name in sorted(_schema_files(ENGINE_SCHEMAS)):
        source = (ENGINE_SCHEMAS / name).read_bytes()
        vendored = (FLUTTER_CONTRACT / name).read_bytes()
        assert source == vendored, (
            f"{name} drifted; run: uv run python scripts/vendor_schemas.py"
        )
