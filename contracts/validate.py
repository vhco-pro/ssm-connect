#!/usr/bin/env python3
"""Validate the portable contracts and their fixtures.

Checks, in order:

1. Every JSON document parses, and no object contains duplicate keys.
2. Both schemas are themselves valid JSON Schema (draft 2020-12).
3. Every profile fixture validates against connection-profile.schema.json.
4. Every workflow fixture validates against state-machine.schema.json.
5. Every profile reference in a workflow fixture resolves to a real file.
6. Fixture IDs are unique and match their filename.
7. No fixture contains a value that looks like real credential material.

Run: python contracts/validate.py
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

from jsonschema import Draft202012Validator

ROOT = pathlib.Path(__file__).resolve().parent
PROFILE_SCHEMA = ROOT / "connection-profile.schema.json"
WORKFLOW_SCHEMA = ROOT / "state-machine.schema.json"
PROFILE_FIXTURES = sorted((ROOT / "fixtures" / "profiles").glob("*.json"))
WORKFLOW_FIXTURES = sorted((ROOT / "fixtures" / "workflows").glob("*.json"))

failures: list[str] = []


def fail(where: pathlib.Path | str, message: str) -> None:
    name = where if isinstance(where, str) else where.relative_to(ROOT).as_posix()
    failures.append(f"{name}: {message}")


def no_duplicate_keys(pairs):
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise ValueError(f"duplicate key {key!r}")
        seen[key] = value
    return seen


def load(path: pathlib.Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=no_duplicate_keys)
    except ValueError as error:
        fail(path, f"invalid JSON ({error})")
        return None


# Values that must never appear in a fixture. Fixtures are synthetic by rule
# (specification section 6.2), so this is a tripwire, not a heuristic scan.
FORBIDDEN_PATTERNS = [
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key ID"),
    (re.compile(r"\bASIA[0-9A-Z]{16}\b"), "AWS temporary access key ID"),
    (re.compile(r"\barn:aws:[a-z0-9-]*:[a-z0-9-]*:\d{12}:"), "ARN with a real-looking account ID"),
    (re.compile(r"X-Amz-Signature=", re.IGNORECASE), "presigned URL signature"),
]


def scan_for_secrets(path: pathlib.Path, node, trail: str = "$") -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            scan_for_secrets(path, value, f"{trail}.{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            scan_for_secrets(path, value, f"{trail}[{index}]")
    elif isinstance(node, str):
        for pattern, label in FORBIDDEN_PATTERNS:
            if pattern.search(node):
                fail(path, f"{trail} looks like a {label}")
        if re.fullmatch(r"\d{12}", node) and node != "000000000000":
            fail(path, f"{trail} looks like a real AWS account ID")


def main() -> int:
    profile_schema = load(PROFILE_SCHEMA)
    workflow_schema = load(WORKFLOW_SCHEMA)
    if profile_schema is None or workflow_schema is None:
        print("\n".join(failures), file=sys.stderr)
        return 1

    for schema, path in ((profile_schema, PROFILE_SCHEMA), (workflow_schema, WORKFLOW_SCHEMA)):
        try:
            Draft202012Validator.check_schema(schema)
        except Exception as error:  # noqa: BLE001 - surfaced verbatim to the operator
            fail(path, f"not a valid JSON Schema ({error})")

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1

    profile_validator = Draft202012Validator(profile_schema)
    workflow_validator = Draft202012Validator(workflow_schema)

    if not PROFILE_FIXTURES:
        fail("fixtures/profiles", "no profile fixtures found")
    if not WORKFLOW_FIXTURES:
        fail("fixtures/workflows", "no workflow fixtures found")

    for path in PROFILE_FIXTURES:
        document = load(path)
        if document is None:
            continue
        for error in sorted(profile_validator.iter_errors(document), key=str):
            fail(path, f"{'/'.join(str(p) for p in error.absolute_path) or '<root>'}: {error.message}")
        scan_for_secrets(path, document)

    seen_ids: dict[str, pathlib.Path] = {}
    for path in WORKFLOW_FIXTURES:
        document = load(path)
        if document is None:
            continue
        for error in sorted(workflow_validator.iter_errors(document), key=str):
            fail(path, f"{'/'.join(str(p) for p in error.absolute_path) or '<root>'}: {error.message}")
        scan_for_secrets(path, document)

        fixture_id = document.get("id")
        if fixture_id:
            if fixture_id != path.stem:
                fail(path, f"id {fixture_id!r} does not match the filename")
            if fixture_id in seen_ids:
                fail(path, f"duplicate id, also used by {seen_ids[fixture_id].name}")
            seen_ids[fixture_id] = path

        reference = (document.get("profile") or {}).get("$ref")
        if reference:
            target = (path.parent / reference).resolve()
            if not target.is_file():
                fail(path, f"profile $ref does not resolve: {reference}")

    if failures:
        print(f"FAIL: {len(failures)} problem(s)\n", file=sys.stderr)
        print("\n".join(f"  - {f}" for f in failures), file=sys.stderr)
        return 1

    print(
        f"PASS: 2 schemas, {len(PROFILE_FIXTURES)} profile fixtures, "
        f"{len(WORKFLOW_FIXTURES)} workflow fixtures."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
