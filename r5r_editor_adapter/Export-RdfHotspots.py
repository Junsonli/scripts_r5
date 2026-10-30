#!/usr/bin/env python3
"""Validate native RFD_EDITOR_V1 snapshots and export hotspot data, never code.

Python 3.9+ standard library only. No game files are modified.
"""

import argparse
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile


MAX_BYTES = 1024 * 1024
MAX_PROPS = 200
MAX_ABS_NUMBER = 1_000_000.0
MAP_PATTERN = re.compile(r"mp_[A-Za-z0-9_]{1,120}\Z")
MODEL_PATTERN = re.compile(r"mdl/[A-Za-z0-9_./-]+\.rmdl\Z")
NUMBER_PATTERN = re.compile(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\Z")
COUNT_PATTERN = re.compile(r"(?:0|[1-9][0-9]*)\Z")
TAG_PATTERN = re.compile(r"([ABCD])_(center|spawn|vertex_[1-9][0-9]*)\Z")


class SnapshotError(ValueError):
    """The snapshot is incomplete, malformed, or not the requested map."""


def _count(value, context):
    if not COUNT_PATTERN.fullmatch(value):
        raise SnapshotError(f"{context}: expected a nonnegative integer")
    if len(value) > len(str(MAX_PROPS)):
        raise SnapshotError(f"{context}: exceeds the {MAX_PROPS}-prop limit")
    count = int(value)
    if count > MAX_PROPS:
        raise SnapshotError(f"{context}: exceeds the {MAX_PROPS}-prop limit")
    return count


def _number(value, line_number):
    if not NUMBER_PATTERN.fullmatch(value):
        raise SnapshotError(f"line {line_number}: invalid numeric field")
    number = float(value)
    if not math.isfinite(number) or abs(number) > MAX_ABS_NUMBER:
        raise SnapshotError(f"line {line_number}: nonfinite or out-of-range number")
    return number


def parse_snapshot(text, expected_map=None, require_centers=False):
    """Return data from one complete snapshot; do not evaluate input as code."""
    if len(text.encode("utf-8")) > MAX_BYTES:
        raise SnapshotError("snapshot exceeds the 1 MiB limit")
    if expected_map is not None and not MAP_PATTERN.fullmatch(expected_map):
        raise SnapshotError("expected map must be an mp_ map identifier")
    lines = text.splitlines()
    if not lines or lines[0] != "RFD_EDITOR_V1":
        raise SnapshotError("missing RFD_EDITOR_V1 header; provide the .rfd file, not a log or .cfg")
    if len(lines) < 3:
        raise SnapshotError("truncated snapshot: MAP and END records are required")
    map_fields = lines[1].split("|")
    if len(map_fields) != 2 or map_fields[0] != "MAP" or not MAP_PATTERN.fullmatch(map_fields[1]):
        raise SnapshotError("line 2: invalid MAP record")
    map_name = map_fields[1]
    if expected_map is not None and map_name != expected_map:
        raise SnapshotError("snapshot MAP does not match --expected-map")

    props = []
    seen_tags = set()
    hotspots = {
        name: {"center": None, "vertices": [], "vertex_tags": []}
        for name in "ABCD"
    }
    spawns = {name: None for name in "ABC"}
    ended = False
    for line_number, line in enumerate(lines[2:], start=3):
        fields = line.split("|")
        if fields[0] == "END":
            if len(fields) != 2:
                raise SnapshotError(f"line {line_number}: invalid END record")
            declared = _count(fields[1], f"line {line_number}")
            if declared != len(props):
                raise SnapshotError(f"END count {declared} does not match {len(props)} PROP records")
            if line_number != len(lines):
                raise SnapshotError("unexpected data after END; export one snapshot at a time")
            ended = True
            break
        if len(fields) != 9 or fields[0] != "PROP":
            raise SnapshotError(f"line {line_number}: expected PROP with exactly 9 fields, or END")
        model = fields[1]
        if not MODEL_PATTERN.fullmatch(model) or any(part in ("", ".", "..") for part in model.split("/")):
            raise SnapshotError(f"line {line_number}: invalid model asset path")
        values = [_number(field, line_number) for field in fields[2:8]]
        tag = fields[8]
        if tag != "-":
            match = TAG_PATTERN.fullmatch(tag)
            if match is None or (match.group(1) == "D" and match.group(2) == "spawn"):
                raise SnapshotError(f"line {line_number}: invalid hotspot tag")
            if tag in seen_tags:
                kind = "center" if tag.endswith("_center") else "spawn" if tag.endswith("_spawn") else "vertex tag"
                raise SnapshotError(f"line {line_number}: duplicate {kind}: {tag}")
            seen_tags.add(tag)
            group = hotspots[match.group(1)]
            if match.group(2) == "center":
                group["center"] = values[:3]
            elif match.group(2) == "spawn":
                spawns[match.group(1)] = values[:3]
                group["spawn"] = values[:3]
            else:
                # Preserve recorded order; do not infer a convex hull or radius.
                group["vertices"].append(values[:3])
                group["vertex_tags"].append(tag)
        props.append({"model": model, "origin": values[:3], "angles": values[3:], "tag": tag})
        if len(props) > MAX_PROPS:
            raise SnapshotError(f"snapshot exceeds the {MAX_PROPS}-prop limit")
    if not ended:
        raise SnapshotError("truncated snapshot: missing END record")
    missing = [name for name, group in hotspots.items() if group["center"] is None]
    if require_centers and missing:
        raise SnapshotError("missing hotspot centers: " + ", ".join(missing))
    return {
        "schema": "rfd_hotspots_v1",
        "source_format": "RFD_EDITOR_V1",
        "map": map_name,
        "prop_count": len(props),
        "complete_centers": not missing,
        "hotspots": hotspots,
        "spawns": spawns,
        "props": props,
    }


def read_snapshot(path, expected_map=None, require_centers=False):
    path = Path(path)
    if path.stat().st_size > MAX_BYTES:
        raise SnapshotError("snapshot exceeds the 1 MiB limit")
    # The engine emits ASCII-compatible records; accept a UTF-8 BOM added by editors.
    return parse_snapshot(path.read_text(encoding="utf-8-sig"), expected_map, require_centers)


def write_json(data, path, overwrite=False):
    path = Path(path)
    if path.exists() and not overwrite:
        raise SnapshotError("output already exists; choose another filename or pass --force")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", newline="\n", dir=path.parent, prefix=".rfd-export-", suffix=".tmp", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(data, stream, ensure_ascii=False, allow_nan=False, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Validate an editor .rfd snapshot and export A/B/C/D hotspot JSON.")
    parser.add_argument("input", type=Path, help="native RFD_EDITOR_V1 .rfd snapshot")
    parser.add_argument("output", type=Path, help="new JSON output file")
    parser.add_argument("--expected-map", help="reject a snapshot for another map")
    parser.add_argument("--require-centers", action="store_true", help="require all four hotspot centers")
    parser.add_argument("--force", action="store_true", help="replace an existing JSON output")
    args = parser.parse_args(argv)
    try:
        if args.input.resolve() == args.output.resolve():
            raise SnapshotError("input and output must be different files")
        data = read_snapshot(args.input, args.expected_map, args.require_centers)
        write_json(data, args.output, args.force)
    except (SnapshotError, OSError, UnicodeError) as error:
        print(f"Export failed: {error}", file=sys.stderr)
        return 2
    centers = sum(group["center"] is not None for group in data["hotspots"].values())
    print(f"Exported map={data['map']} props={data['prop_count']} centers={centers}/4")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
