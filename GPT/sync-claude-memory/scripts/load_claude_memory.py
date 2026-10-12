#!/usr/bin/env python3
"""Locate and print Claude memory for a project without modifying source files."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Iterable


INDEX_NAME = "MEMORY.md"
LINK_RE = re.compile(r"\(([^)#?]+\.md)(?:#[^)]*)?\)", re.IGNORECASE)


def canonical(path: Path) -> str:
    return os.path.normcase(str(path.expanduser().resolve()))


def is_within(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def has_memory(directory: Path) -> bool:
    return directory.is_dir() and any(directory.glob("*.md"))


def project_root(start: Path) -> Path:
    start = start.expanduser().resolve()
    for candidate in (start, *start.parents):
        if (candidate / ".git").exists():
            return candidate
    return start


def find_cwd(value: object) -> str | None:
    if isinstance(value, dict):
        cwd = value.get("cwd")
        if isinstance(cwd, str) and cwd.strip():
            return cwd
        for nested in value.values():
            found = find_cwd(nested)
            if found:
                return found
    elif isinstance(value, list):
        for nested in value:
            found = find_cwd(nested)
            if found:
                return found
    return None


def jsonl_cwd(path: Path, max_lines: int = 3000) -> Path | None:
    try:
        with path.open("r", encoding="utf-8-sig", errors="replace") as stream:
            for number, line in enumerate(stream, start=1):
                if number > max_lines:
                    break
                if '"cwd"' not in line:
                    continue
                try:
                    cwd = find_cwd(json.loads(line))
                except json.JSONDecodeError:
                    continue
                if cwd:
                    return Path(cwd).expanduser().resolve()
    except OSError:
        return None
    return None


def local_candidates(start: Path, root: Path, claude_projects: Path) -> list[Path]:
    found: list[Path] = []

    # A Codex task may be opened directly on ~/.claude/projects/<encoded-project>.
    for base in (start, root):
        direct = base / "memory"
        if has_memory(direct) and is_within(base, claude_projects):
            found.append(direct.resolve())

    # A normal source project may keep memory under .claude/memory.
    for base in (start, *start.parents):
        candidate = base / ".claude" / "memory"
        if has_memory(candidate):
            found.append(candidate.resolve())
        if base == root:
            break

    return unique_paths(found)


def match_score(target: Path, recorded_cwd: Path) -> int:
    if canonical(target) == canonical(recorded_cwd):
        return 3
    if is_within(target, recorded_cwd):
        return 2
    if is_within(recorded_cwd, target):
        return 1
    return 0


def global_candidates(target: Path, claude_projects: Path) -> list[tuple[int, float, Path, Path]]:
    matches: list[tuple[int, float, Path, Path]] = []
    if not claude_projects.is_dir():
        return matches

    for state_dir in claude_projects.iterdir():
        memory_dir = state_dir / "memory"
        if not has_memory(memory_dir):
            continue
        sessions = sorted(
            state_dir.glob("*.jsonl"),
            key=lambda item: item.stat().st_mtime,
            reverse=True,
        )
        recorded: Path | None = None
        newest = 0.0
        for session in sessions:
            newest = max(newest, session.stat().st_mtime)
            recorded = jsonl_cwd(session)
            if recorded:
                break
        if not recorded:
            continue
        score = match_score(target, recorded)
        if score:
            matches.append((score, newest, memory_dir.resolve(), recorded))
    return sorted(matches, key=lambda item: (item[0], item[1]), reverse=True)


def unique_paths(paths: Iterable[Path]) -> list[Path]:
    result: list[Path] = []
    seen: set[str] = set()
    for path in paths:
        key = canonical(path)
        if key not in seen:
            seen.add(key)
            result.append(path)
    return result


def discover(project: Path, claude_home: Path) -> Path:
    start = project.expanduser().resolve()
    root = project_root(start)
    claude_projects = claude_home.expanduser().resolve() / "projects"

    local = local_candidates(start, root, claude_projects)
    if len(local) == 1:
        return local[0]
    if len(local) > 1:
        raise RuntimeError(
            "Multiple local Claude memory directories matched:\n"
            + "\n".join(f"- {path}" for path in local)
        )

    matches = global_candidates(root, claude_projects)
    if not matches and canonical(root) != canonical(start):
        matches = global_candidates(start, claude_projects)
    if not matches:
        raise FileNotFoundError(
            f"No Claude memory matched project: {root}\n"
            f"Checked local .claude/memory and: {claude_projects}"
        )

    best_score = matches[0][0]
    best = [item for item in matches if item[0] == best_score]
    if len(best) > 1 and best[0][1] == best[1][1]:
        raise RuntimeError(
            "Claude memory discovery is ambiguous:\n"
            + "\n".join(
                f"- memory={memory}; recorded_cwd={cwd}" for _, _, memory, cwd in best
            )
        )
    return best[0][2]


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig", errors="replace")


def indexed_files(memory_dir: Path, include_all: bool) -> list[Path]:
    index = memory_dir / INDEX_NAME
    markdown = sorted(memory_dir.glob("*.md"), key=lambda item: item.name.lower())
    if not index.is_file():
        return markdown

    ordered: list[Path] = [index]
    for link in LINK_RE.findall(read_text(index)):
        candidate = (memory_dir / link).resolve()
        if is_within(candidate, memory_dir) and candidate.is_file():
            ordered.append(candidate)
    if include_all:
        ordered.extend(markdown)
    return unique_paths(ordered)


def validate_explicit_source(source: Path) -> Path:
    resolved = source.expanduser().resolve()
    if not has_memory(resolved):
        raise FileNotFoundError(f"No Markdown memory files found in: {resolved}")
    return resolved


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path.cwd())
    parser.add_argument("--source", type=Path, help="Explicit Claude memory directory")
    parser.add_argument(
        "--claude-home",
        type=Path,
        default=Path(os.environ.get("CLAUDE_HOME", Path.home() / ".claude")),
    )
    parser.add_argument("--all", action="store_true", help="Include unindexed Markdown files")
    parser.add_argument("--paths-only", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        memory_dir = (
            validate_explicit_source(args.source)
            if args.source
            else discover(args.project, args.claude_home)
        )
        files = indexed_files(memory_dir, args.all)
    except (FileNotFoundError, RuntimeError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2

    print(f"CLAUDE_MEMORY_DIR: {memory_dir}")
    print("MODE: read-only")
    print(f"FILES: {len(files)}")
    for path in files:
        print(f"- {path}")

    if args.paths_only:
        return 0

    for path in files:
        print(f"\n===== BEGIN {path.name} =====")
        print(read_text(path).rstrip())
        print(f"===== END {path.name} =====")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

