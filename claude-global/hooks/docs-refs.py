#!/usr/bin/env python3
"""
docs-refs: scan markdown docs for file/directory references.

References are declared explicitly via a YAML frontmatter `tracks:` list
(inline `[a, b]` or block `- a` form). Body-text scanning is intentionally
*not* done — backtick tokens that happen to resolve to existing paths
produced false positives (e.g. `docs/` matching the docs directory itself,
which then matched every sibling doc).

Resolution attempts per token (in order, first hit wins):
  - Absolute path (after `~` expansion).
  - Relative to the doc file's parent directory.
  - If the doc lives inside a `docs/` subtree, relative to the `docs/`'s parent
    (the natural "project root").

Unresolved entries are dropped silently but will start matching as soon as
the path exists — useful for declaring intent before a file is created.

Subcommands:
  scan [dir...]
    Print JSON {<doc abs path>: [<resolved ref abs paths>]}.
    Default dirs: $PWD/docs and ~/.docs (each only if it exists).

  for-file <changed_file> [--dir DIR ...]
    Print absolute paths of docs that reference <changed_file>, one per line.
    A directory ref matches any file under it. Default dirs as above.

  has-tracks <doc>
    Exit 0 iff <doc> declares a `tracks:` block (even if empty/unresolved);
    exit 1 if missing or unreadable. Used by the notify hook to flag docs
    that opted out of the reference system silently.

  --quiet  (for-file only): suppress errors, exit 0 even on failure.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)
TRACKS_INLINE_RE = re.compile(r"^tracks:\s*\[(.*?)\]\s*$", re.MULTILINE)
TRACKS_BLOCK_RE = re.compile(r"^tracks:\s*\n((?:\s*-\s*.+\n?)+)", re.MULTILINE)


def default_dirs() -> list[Path]:
    dirs = []
    cwd_docs = Path.cwd() / "docs"
    if cwd_docs.is_dir():
        dirs.append(cwd_docs)
    home_docs = Path.home() / ".docs"
    if home_docs.is_dir():
        dirs.append(home_docs)
    return dirs


def project_root_for(doc: Path) -> Path | None:
    """If the doc lives under a `docs/` directory, return its parent."""
    for parent in doc.parents:
        if parent.name == "docs":
            return parent.parent
    return None


def resolve_token(token: str, doc: Path) -> Path | None:
    """Try resolving a backtick/frontmatter token to an existing path."""
    token = token.strip()
    if not token:
        return None
    # Reject obvious non-path tokens early.
    if any(c in token for c in "\n\t"):
        return None
    candidates: list[Path] = []
    expanded = os.path.expanduser(token)
    if os.path.isabs(expanded):
        candidates.append(Path(expanded))
    else:
        candidates.append(doc.parent / expanded)
        root = project_root_for(doc)
        if root is not None:
            candidates.append(root / expanded)
    for c in candidates:
        try:
            if c.exists():
                return c.resolve()
        except OSError:
            continue
    return None


def parse_frontmatter_tracks(text: str) -> list[str]:
    m = FRONTMATTER_RE.match(text)
    if not m:
        return []
    fm = m.group(1)
    items: list[str] = []
    for im in TRACKS_INLINE_RE.finditer(fm):
        for raw in im.group(1).split(","):
            raw = raw.strip().strip("'\"")
            if raw:
                items.append(raw)
    for bm in TRACKS_BLOCK_RE.finditer(fm):
        for line in bm.group(1).splitlines():
            line = line.strip()
            if line.startswith("-"):
                raw = line[1:].strip().strip("'\"")
                if raw:
                    items.append(raw)
    return items


def extract_refs(doc: Path) -> list[Path]:
    """Return resolved, deduplicated absolute paths referenced by `doc`."""
    try:
        text = doc.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    seen: set[Path] = set()
    out: list[Path] = []

    def add(p: Path | None) -> None:
        if p is None or p in seen:
            return
        seen.add(p)
        out.append(p)

    for token in parse_frontmatter_tracks(text):
        add(resolve_token(token, doc))

    return out


def iter_docs(dirs: list[Path]):
    for d in dirs:
        if not d.is_dir():
            continue
        for p in d.rglob("*.md"):
            if p.is_file():
                yield p


def cmd_scan(args: argparse.Namespace) -> int:
    dirs = [Path(d).resolve() for d in args.dirs] if args.dirs else default_dirs()
    out: dict[str, list[str]] = {}
    for doc in iter_docs(dirs):
        refs = extract_refs(doc)
        if refs:
            out[str(doc.resolve())] = [str(r) for r in refs]
    json.dump(out, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


def file_matches_ref(changed: Path, ref: Path) -> bool:
    """changed (file) matches ref (file or dir)."""
    try:
        c = changed.resolve()
    except OSError:
        c = changed
    if c == ref:
        return True
    if ref.is_dir():
        try:
            c.relative_to(ref)
            return True
        except ValueError:
            return False
    return False


def cmd_has_tracks(args: argparse.Namespace) -> int:
    try:
        text = Path(args.path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 1
    m = FRONTMATTER_RE.match(text)
    if not m:
        return 1
    fm = m.group(1)
    if TRACKS_INLINE_RE.search(fm) or TRACKS_BLOCK_RE.search(fm):
        return 0
    return 1


def cmd_for_file(args: argparse.Namespace) -> int:
    target_raw = Path(os.path.expanduser(args.changed_file))
    try:
        target = target_raw.resolve()
    except OSError:
        target = target_raw
    dirs = [Path(d).resolve() for d in args.dir] if args.dir else default_dirs()
    matches: list[str] = []
    for doc in iter_docs(dirs):
        for ref in extract_refs(doc):
            if file_matches_ref(target, ref):
                matches.append(str(doc.resolve()))
                break
    for m in matches:
        print(m)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="docs-refs", description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_scan = sub.add_parser("scan", help="emit JSON of all doc -> [refs]")
    p_scan.add_argument("dirs", nargs="*")
    p_scan.set_defaults(func=cmd_scan)

    p_ff = sub.add_parser("for-file", help="list docs referencing a changed file")
    p_ff.add_argument("changed_file")
    p_ff.add_argument("--dir", action="append", default=[])
    p_ff.add_argument("--quiet", action="store_true")
    p_ff.set_defaults(func=cmd_for_file)

    p_ht = sub.add_parser("has-tracks", help="exit 0 iff doc declares a tracks: block")
    p_ht.add_argument("path")
    p_ht.set_defaults(func=cmd_has_tracks)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as e:
        if getattr(args, "quiet", False):
            return 0
        print(f"docs-refs: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
