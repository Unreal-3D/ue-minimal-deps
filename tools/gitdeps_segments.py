#!/usr/bin/env python3
"""Explore the path-segment layout of a GitDependencies manifest.

This is the tool that finds the exclude patterns in the first place. UE's
manifest is a flat list of ~150k file paths; what you actually need is a
histogram of directory names, because that is the unit -exclude operates on.

    # what platform-ish directory names exist, and how big are they?
    tools/gitdeps_segments.py --manifest .../Commit.gitdeps.xml --platforms

    # what is under a given tree, two levels deep?
    tools/gitdeps_segments.py --manifest ... --tree Engine/Binaries/ThirdParty/DotNet

    # every segment matching a regex, with the directories that use it
    tools/gitdeps_segments.py --manifest ... --grep 'arm64|ios|android'

    # the biggest segments overall - where the bytes are
    tools/gitdeps_segments.py --manifest ... --top 40

Typical workflow for a new engine version:
  1. --platforms to see which platform segments exist and how they are spelled
  2. --grep on anything unfamiliar to find where it lives
  3. --tree on the directories that matter to confirm the layout
  4. update scripts/Setup_Minimal*.sh
  5. tools/gitdeps_audit.py --profile <name> to check you did not break anything

These tools live in a separate repo but read an engine tree, so run them with the
engine root as the working directory and an absolute path to the tool - the
default manifest is Engine/Build/Commit.gitdeps.xml relative to that directory.
"""

from __future__ import annotations

import argparse
import collections
import html
import pathlib
import re
import sys

# Directory names that carry platform identity. Deliberately broad: the point is
# to surface anything that might need a decision, not to be a final answer.
PLATFORM_HINTS = re.compile(
    r"(linux|unix|win|mac|osx|darwin|ios|tvos|visionos|watchos|android|"
    r"vs20\d\d|msvc|mingw|gnuwin32|"
    r"arm64|aarch64|x86_64|x64|x86|i386|"
    r"apple|metal|cef|vcpkg|overlay|dotnet|netcore|netstandard|"
    r"clang|gcc|msvc|ndk|ue4|ue5)",
    re.I,
)

# Segments that look platform-ish but are not platform payloads. Filtered out of
# --platforms so the output stays readable. Entries must be lowercase: the
# comparison lowercases the segment name before looking it up here.
FALSE_FRIENDS = {
    "window", "windowsdeviceprofileselector", "wind", "windsock", "wince",
    "windsettings", "unwind", "iostream3", "macros", "dynamicwind",
    "unrealdynamicwind", "previewing", "ratioscale",
}


def load_names(manifest: pathlib.Path) -> list[str]:
    if not manifest.is_file():
        sys.exit(
            f"error: manifest not found: {manifest}\n"
            "hint: run this from an Unreal Engine root (the directory holding Setup.sh),\n"
            "      or pass --manifest /path/to/Engine/Build/Commit.gitdeps.xml"
        )
    # File names are XML-attribute-escaped (5.7.4 has one "&amp;"), so decode them
    # before counting segments or the reported path would not exist on disk.
    return [html.unescape(n)
            for n in re.findall(r'<File Name="([^"]+)"', manifest.read_text(encoding="utf-8"))]


def segment_counts(names: list[str]) -> collections.Counter:
    counts: collections.Counter = collections.Counter()
    for n in names:
        counts.update(set(n.split("/")[:-1]))  # a segment counts once per file
    return counts


def segment_parents(names: list[str]) -> dict[str, collections.Counter]:
    parents: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for n in names:
        parts = n.split("/")
        for i, p in enumerate(parts[:-1]):
            parents[p]["/".join(parts[:i])] += 1
    return parents


def cmd_platforms(names: list[str], top: int) -> None:
    counts = segment_counts(names)
    parents = segment_parents(names)
    hits = [(s, c) for s, c in counts.items()
            if PLATFORM_HINTS.search(s) and s.lower() not in FALSE_FRIENDS]
    print(f"{len(names)} files, {len(counts)} distinct segments, "
          f"{len(hits)} platform-ish segments\n")
    print(f"{'files':>7}  {'segment':<42} where it lives")
    for seg, count in sorted(hits, key=lambda kv: -kv[1])[:top]:
        where = ", ".join(f"{p or '.'} ({c})" for p, c in parents[seg].most_common(3))
        print(f"{count:7d}  {seg:<42} {where}")


def cmd_grep(names: list[str], pattern: str, top: int) -> None:
    rx = re.compile(pattern, re.I)
    counts = segment_counts(names)
    parents = segment_parents(names)
    hits = [(s, c) for s, c in counts.items() if rx.search(s)]
    print(f"{len(hits)} segments match /{pattern}/i\n")
    for seg, count in sorted(hits, key=lambda kv: -kv[1])[:top]:
        print(f"{count:7d}  {seg}")
        for p, c in parents[seg].most_common(4):
            print(f"           {c:6d}  {p}/")
    print()


def cmd_tree(names: list[str], prefix: str, depth: int, top: int) -> None:
    prefix = prefix.strip("/")
    counts: collections.Counter = collections.Counter()
    for n in names:
        if not n.startswith(prefix + "/"):
            continue
        rest = n[len(prefix) + 1:]
        parts = rest.split("/")[:depth]
        counts["/".join(parts)] += 1
    if not counts:
        print(f"nothing under {prefix}/")
        return
    print(f"{sum(counts.values())} files under {prefix}/  (depth {depth})\n")
    for k, v in sorted(counts.items(), key=lambda kv: -kv[1])[:top]:
        print(f"{v:7d}  {k}")


def cmd_top(names: list[str], top: int) -> None:
    counts = segment_counts(names)
    print(f"{'files':>7}  segment")
    for seg, count in counts.most_common(top):
        print(f"{count:7d}  {seg}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", type=pathlib.Path,
                    default=pathlib.Path("Engine/Build/Commit.gitdeps.xml"))
    ap.add_argument("--platforms", action="store_true", help="list platform-ish segments with counts and locations")
    ap.add_argument("--grep", metavar="REGEX", help="list segments matching a regex")
    ap.add_argument("--tree", metavar="PREFIX", help="show the layout under a path prefix")
    ap.add_argument("--depth", type=int, default=2, help="depth for --tree (default 2)")
    ap.add_argument("--top", type=int, default=40, help="rows to print (default 40)")
    args = ap.parse_args()

    names = load_names(args.manifest)

    if args.tree:
        cmd_tree(names, args.tree, args.depth, args.top)
    elif args.grep:
        cmd_grep(names, args.grep, args.top)
    elif args.platforms:
        cmd_platforms(names, args.top)
    else:
        cmd_top(names, args.top)
    return 0


if __name__ == "__main__":
    sys.exit(main())
