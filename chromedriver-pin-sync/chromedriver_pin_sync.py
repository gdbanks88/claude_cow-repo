#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
chromedriver_pin_sync.py
========================

Fully offline, single-file automation that:

  1. Detects the ChromeDriver version installed on THIS machine.
  2. Scans a repository (a "code replay" / checkout you choose) for every place
     the ChromeDriver version is *pinned*.
  3. Shows you a diff between what is pinned in the repo and what you have
     installed locally.
  4. Optionally updates the pinned version in the repo -- but ONLY when your
     locally installed ChromeDriver is a HIGHER version than the pin.

Design constraints (all enforced):
  * NO network calls. NO API calls. NO outbound connections of any kind.
    The only subprocess this script ever runs is the local ChromeDriver
    binary with `--version` to read its version string. Nothing leaves the
    machine. Safe to run on a fully network-separated / air-gapped host.
  * Pure Python 3 standard library. No pip installs, no third-party deps.
  * One file. Drop the containing folder anywhere and run it.
  * Runs on Linux, tested against Red Hat-family layouts (RHEL/CentOS/Fedora)
    as well as generic distros. Also works on macOS paths.

Typical use
-----------
    # 1) Dry run: detect + scan + show diff, change nothing (the default).
    ./chromedriver_pin_sync.py --repo /path/to/your/checkout

    # 2) Same, but actually WRITE the updates where installed > pinned.
    ./chromedriver_pin_sync.py --repo /path/to/your/checkout --apply

    # 3) Air-gapped box where you can't execute the driver binary?
    #    Feed the version in by hand:
    ./chromedriver_pin_sync.py --repo /path/to/checkout --version 128.0.6613.119

    # 4) Point at a specific driver binary:
    ./chromedriver_pin_sync.py --repo /path/to/checkout \
        --chromedriver /opt/selenium/chromedriver

Exit codes
----------
    0  success (nothing to do, or changes shown/applied cleanly)
    1  usage / environment error (bad repo path, no version, etc.)
    2  changes are AVAILABLE but were not applied (dry-run found upgrades).
       Handy for CI-style gating: exit 2 == "the repo is behind".
"""

from __future__ import annotations

import argparse
import difflib
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Iterable, List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# Configuration: where drivers usually live, and which files to scan.
# ---------------------------------------------------------------------------

# Common locations for the chromedriver binary on Linux (Red Hat family and
# friends) plus a couple of macOS spots. Checked in order; first hit wins.
COMMON_DRIVER_PATHS: Sequence[str] = (
    "/usr/bin/chromedriver",
    "/usr/local/bin/chromedriver",
    "/usr/lib/chromium-browser/chromedriver",
    "/usr/lib64/chromium/chromedriver",
    "/opt/chromedriver/chromedriver",
    "/opt/selenium/chromedriver",
    "/opt/google/chrome/chromedriver",
    "/snap/bin/chromium.chromedriver",
    "/usr/local/share/chromedriver",
    os.path.expanduser("~/.local/bin/chromedriver"),
    os.path.expanduser("~/bin/chromedriver"),
)

# As a fallback for version detection when no driver binary can be executed,
# we can read the installed Google Chrome / Chromium version -- ChromeDriver
# tracks Chrome's version number, so the major line matches.
COMMON_BROWSER_PATHS: Sequence[str] = (
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/opt/google/chrome/chrome",
    "/opt/google/chrome/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
    "/usr/lib64/chromium/chromium",
)

# Directories we never descend into while scanning a repo.
SKIP_DIRS = {
    ".git", ".hg", ".svn", "node_modules", ".venv", "venv", "env",
    "__pycache__", ".mypy_cache", ".pytest_cache", ".tox", "dist", "build",
    ".idea", ".vscode", "site-packages", ".cache", "target", "vendor",
}

# Only scan files that plausibly hold a version pin. Extension-less files with
# a known name (Dockerfile, etc.) are handled separately below.
SCAN_EXTENSIONS = {
    ".txt", ".cfg", ".ini", ".toml", ".yaml", ".yml", ".json", ".env",
    ".sh", ".bash", ".zsh", ".py", ".rb", ".js", ".ts", ".gradle", ".xml",
    ".properties", ".conf", ".tf", ".tfvars", ".mk", ".make", ".dockerfile",
    ".lock",
}
SCAN_FILENAMES = {
    "Dockerfile", "dockerfile", "Makefile", "makefile", ".tool-versions",
    "requirements.txt", "constraints.txt", "environment.yml", ".env",
    "Pipfile", "Pipfile.lock", "package.json", "package-lock.json",
    "docker-compose.yml", "docker-compose.yaml", ".chromedriver-version",
    ".chromedriver_version", "chromedriver.version",
}

# A ChromeDriver version looks like one of:
#   128
#   128.0
#   128.0.6613
#   128.0.6613.119
# i.e. a leading integer followed by up to three ".integer" groups.
VERSION_RE = r"\d+(?:\.\d+){0,3}"

# The word "chromedriver" (or "chrome_driver" / "chrome-driver" / the env-var
# style "CHROMEDRIVER") must appear on, or immediately around, the same line
# for us to treat a version number as a driver pin. This keeps us from
# rewriting unrelated version strings.
DRIVER_TOKEN_RE = re.compile(r"chrome[_\-]?driver", re.IGNORECASE)

# Precompiled matcher that finds a version token on a line.
LINE_VERSION_RE = re.compile(VERSION_RE)

MAX_FILE_BYTES = 2 * 1024 * 1024  # skip anything larger than 2 MiB; pins are tiny


# ---------------------------------------------------------------------------
# Version handling
# ---------------------------------------------------------------------------

def parse_version(text: str) -> Optional[Tuple[int, ...]]:
    """Parse a dotted numeric version into a tuple of ints, or None."""
    m = re.fullmatch(VERSION_RE, text.strip())
    if not m:
        return None
    return tuple(int(part) for part in text.strip().split("."))


def compare_at_pin_granularity(
    installed: Tuple[int, ...], pinned: Tuple[int, ...]
) -> int:
    """Compare `installed` vs `pinned`, but only to the precision of the pin.

    ChromeDriver pins are written at different granularities (some repos pin
    just the major line "128", others pin the full "128.0.6613.119"). We honor
    the pin's own precision: the installed version is truncated to the same
    number of components as the pin before comparing. This means a major-only
    pin only "moves" when the major changes, and a full pin moves on any of
    its four components.

    Returns  1 if installed > pinned, 0 if equal, -1 if installed < pinned,
    all evaluated at the pin's granularity.
    """
    depth = len(pinned)
    trimmed = installed[:depth]
    # Pad the installed side with zeros if it is shorter than the pin depth.
    if len(trimmed) < depth:
        trimmed = trimmed + (0,) * (depth - len(trimmed))
    if trimmed > pinned:
        return 1
    if trimmed < pinned:
        return -1
    return 0


def render_new_pin(installed: Tuple[int, ...], pinned: Tuple[int, ...]) -> str:
    """Render the installed version at the same granularity as the old pin.

    Keeps the repo's chosen precision: replacing "128" with "129", or
    "128.0.6613.119" with "129.0.6668.100" -- never changing how many
    components the maintainers chose to pin.
    """
    depth = len(pinned)
    trimmed = installed[:depth]
    if len(trimmed) < depth:
        trimmed = trimmed + (0,) * (depth - len(trimmed))
    return ".".join(str(p) for p in trimmed)


# ---------------------------------------------------------------------------
# Local ChromeDriver / Chrome version detection (no network)
# ---------------------------------------------------------------------------

def _run_version_command(binary: str) -> Optional[str]:
    """Run `<binary> --version` locally and return raw stdout, or None.

    This is the ONLY subprocess call in the program. It executes a local
    binary and reads its own version banner. No network is involved.
    """
    try:
        proc = subprocess.run(
            [binary, "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    out = (proc.stdout or b"").decode("utf-8", "replace").strip()
    if not out:
        out = (proc.stderr or b"").decode("utf-8", "replace").strip()
    return out or None


def _first_version_in(text: str) -> Optional[Tuple[int, ...]]:
    m = re.search(VERSION_RE, text)
    if not m:
        return None
    return parse_version(m.group(0))


@dataclass
class Detection:
    version: Tuple[int, ...]
    source: str          # human-readable description of where it came from
    raw: str             # the raw string we parsed


def detect_installed_version(
    explicit_version: Optional[str],
    explicit_binary: Optional[str],
) -> Optional[Detection]:
    """Figure out the locally installed ChromeDriver version, offline.

    Priority:
      1. --version supplied by the user (for air-gapped hosts).
      2. --chromedriver <path> supplied by the user.
      3. `chromedriver` on PATH.
      4. Well-known driver locations.
      5. Fallback: installed Chrome/Chromium version (driver tracks Chrome).
    """
    # 1) Explicit version string wins outright.
    if explicit_version:
        v = parse_version(explicit_version)
        if not v:
            raise SystemExit(
                f"error: --version {explicit_version!r} is not a valid "
                f"dotted version (expected e.g. 128.0.6613.119)"
            )
        return Detection(v, "provided via --version", explicit_version)

    candidates: List[str] = []

    # 2) Explicit binary path.
    if explicit_binary:
        if not os.path.isfile(explicit_binary):
            raise SystemExit(
                f"error: --chromedriver path does not exist: {explicit_binary}"
            )
        candidates.append(explicit_binary)

    # 3) PATH lookup.
    on_path = shutil.which("chromedriver")
    if on_path:
        candidates.append(on_path)

    # 4) Well-known locations.
    candidates.extend(p for p in COMMON_DRIVER_PATHS if os.path.isfile(p))

    seen = set()
    for binary in candidates:
        real = os.path.realpath(binary)
        if real in seen:
            continue
        seen.add(real)
        raw = _run_version_command(binary)
        if raw:
            v = _first_version_in(raw)
            if v:
                return Detection(v, f"chromedriver binary at {binary}", raw)

    # 5) Fall back to the browser version (driver major == chrome major).
    browser_candidates: List[str] = []
    for name in ("google-chrome", "google-chrome-stable", "chromium",
                 "chromium-browser", "chrome"):
        found = shutil.which(name)
        if found:
            browser_candidates.append(found)
    browser_candidates.extend(
        p for p in COMMON_BROWSER_PATHS if os.path.isfile(p)
    )
    for binary in browser_candidates:
        raw = _run_version_command(binary)
        if raw:
            v = _first_version_in(raw)
            if v:
                return Detection(
                    v,
                    f"Chrome/Chromium browser at {binary} "
                    f"(driver version tracks the browser)",
                    raw,
                )

    return None


# ---------------------------------------------------------------------------
# Repository scan
# ---------------------------------------------------------------------------

@dataclass
class PinHit:
    path: str            # absolute path to file
    relpath: str         # path relative to the repo root (for display)
    line_no: int         # 1-based
    line: str            # original line text (no trailing newline)
    version_str: str     # the exact matched version substring
    span: Tuple[int, int]  # (start, end) indices of the version within `line`
    version: Tuple[int, ...]  # parsed


def _should_scan(filename: str) -> bool:
    if filename in SCAN_FILENAMES:
        return True
    _, ext = os.path.splitext(filename)
    if ext.lower() in SCAN_EXTENSIONS:
        return True
    # Files whose name *is* an extension-style token, e.g. "Dockerfile.ci".
    base = filename.split(".", 1)[0]
    if base in ("Dockerfile", "dockerfile", "Makefile", "makefile"):
        return True
    return False


def iter_candidate_files(repo_root: str) -> Iterable[str]:
    for dirpath, dirnames, filenames in os.walk(repo_root):
        # Prune skip dirs in place so os.walk doesn't descend into them.
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if _should_scan(fn):
                yield os.path.join(dirpath, fn)


def _leading_indent(line: str) -> int:
    return len(line) - len(line.lstrip())


def _version_after(line: str, start: int) -> Optional[Tuple[str, Tuple[int, int]]]:
    """First version token at/after index `start`; returns (str, (s,e))."""
    m = LINE_VERSION_RE.search(line, start)
    if not m:
        return None
    return m.group(0), (m.start(), m.end())


def _version_before(line: str, end: int) -> Optional[Tuple[str, Tuple[int, int]]]:
    """Last version token that ends at/before index `end`."""
    last = None
    for m in LINE_VERSION_RE.finditer(line[:end]):
        last = (m.group(0), (m.start(), m.end()))
    return last


def _accept(version_str: str, one_component_ok: bool) -> Optional[Tuple[int, ...]]:
    """Parse + apply the sanity guard against stray single digits."""
    v = parse_version(version_str)
    if v is None:
        return None
    # A bare single number is only a plausible ChromeDriver pin when it is a
    # modern-looking major (>= 60). Rejects matches like "chromedriver to 4".
    if len(v) == 1 and v[0] < 60 and not one_component_ok:
        return None
    return v


def scan_repo_for_pins(repo_root: str) -> List[PinHit]:
    """Find ChromeDriver version pins in the repo -- precisely.

    For every line that mentions ``chromedriver`` (any spelling), we capture
    exactly ONE version: the token directly associated with that mention.

      * Same-line value  -- e.g. ``CHROMEDRIVER_VERSION=114.0.5735.90`` or
        ``chromedriver-binary==114.0.5735.90.0`` (we take the driver's
        major.minor.build.patch and leave any packaging suffix intact).
      * Nested key/value -- when the mention is a bare key such as
        ``chromedriver:`` with no version on its own line, we look FORWARD at
        the indented block beneath it for the version.

    We deliberately do NOT scan sibling or unrelated lines, so a neighboring
    ``requests==2.31.0`` is never mistaken for a driver pin.
    """
    hits: List[PinHit] = []
    for path in iter_candidate_files(repo_root):
        try:
            if os.path.getsize(path) > MAX_FILE_BYTES:
                continue
        except OSError:
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except (OSError, UnicodeError):
            continue

        rel = os.path.relpath(path, repo_root)
        for idx, line in enumerate(lines):
            tok = DRIVER_TOKEN_RE.search(line)
            if not tok:
                continue

            found: Optional[Tuple[int, str, Tuple[int, int], Tuple[int, ...]]] = None

            # (a) A version to the RIGHT of the token on the same line.
            after = _version_after(line, tok.end())
            if after:
                v = _accept(after[0], one_component_ok=True)
                if v is not None:
                    found = (idx, after[0], after[1], v)

            # (b) Otherwise a version to the LEFT (e.g. "114... # chromedriver").
            if found is None:
                before = _version_before(line, tok.start())
                if before:
                    v = _accept(before[0], one_component_ok=True)
                    if v is not None:
                        found = (idx, before[0], before[1], v)

            # (c) Otherwise treat it as a nested key and look FORWARD into the
            #     indented block for the version value.
            if found is None:
                key_indent = _leading_indent(line)
                look = 0
                for j in range(idx + 1, len(lines)):
                    nxt = lines[j]
                    if not nxt.strip():
                        continue  # blank lines don't end the block
                    if _leading_indent(nxt) <= key_indent:
                        break     # dedent -> left the block
                    nv = _version_after(nxt, 0)
                    if nv:
                        pv = _accept(nv[0], one_component_ok=True)
                        if pv is not None:
                            found = (j, nv[0], nv[1], pv)
                        break
                    look += 1
                    if look >= 5:
                        break

            if found is None:
                continue

            hit_idx, vstr, span, ver = found
            hits.append(
                PinHit(
                    path=path,
                    relpath=rel,
                    line_no=hit_idx + 1,
                    line=lines[hit_idx],
                    version_str=vstr,
                    span=span,
                    version=ver,
                )
            )
    # De-duplicate (a nested key and its value line can't both win, but two
    # tokens could point at the same version line) and order for humans.
    unique = {}
    for h in hits:
        unique[(h.path, h.line_no, h.span)] = h
    ordered = sorted(unique.values(), key=lambda h: (h.relpath, h.line_no, h.span[0]))
    return ordered


# ---------------------------------------------------------------------------
# Diff + apply
# ---------------------------------------------------------------------------

@dataclass
class PlannedChange:
    hit: PinHit
    old_version_str: str
    new_version_str: str
    new_line: str


@dataclass
class FilePlan:
    path: str
    relpath: str
    original_lines: List[str]
    changes: List[PlannedChange] = field(default_factory=list)


def build_plan(
    hits: Sequence[PinHit], installed: Tuple[int, ...]
) -> Tuple[List[PlannedChange], List[PinHit], List[PinHit]]:
    """Split hits into upgrades / already-current / ahead-of-installed.

    Returns (upgrades, equal, ahead) where:
      upgrades  -> installed is HIGHER than pin (candidates to write)
      equal     -> pin already matches installed at its granularity
      ahead     -> pin is HIGHER than installed (never touched; reported)
    """
    upgrades: List[PlannedChange] = []
    equal: List[PinHit] = []
    ahead: List[PinHit] = []
    for hit in hits:
        cmp = compare_at_pin_granularity(installed, hit.version)
        if cmp > 0:
            new_str = render_new_pin(installed, hit.version)
            s, e = hit.span
            new_line = hit.line[:s] + new_str + hit.line[e:]
            upgrades.append(
                PlannedChange(hit, hit.version_str, new_str, new_line)
            )
        elif cmp == 0:
            equal.append(hit)
        else:
            ahead.append(hit)
    return upgrades, equal, ahead


def group_changes_by_file(changes: Sequence[PlannedChange]) -> List[FilePlan]:
    by_path = {}
    order: List[str] = []
    for ch in changes:
        p = ch.hit.path
        if p not in by_path:
            with open(p, "r", encoding="utf-8", errors="replace") as fh:
                original = fh.read().splitlines()
            by_path[p] = FilePlan(p, ch.hit.relpath, original)
            order.append(p)
        by_path[p].changes.append(ch)
    return [by_path[p] for p in order]


def apply_file_plan(plan: FilePlan) -> List[str]:
    """Return the new lines for a file with all planned changes applied.

    Applies per-line, respecting the exact character span of each version so
    that multiple pins on different lines (or the same line) are handled
    correctly.
    """
    # Map line_no -> list of (span, new_str), applied right-to-left per line.
    edits_by_line = {}
    for ch in plan.changes:
        edits_by_line.setdefault(ch.hit.line_no, []).append(
            (ch.hit.span, ch.new_version_str)
        )
    new_lines = list(plan.original_lines)
    for line_no, edits in edits_by_line.items():
        idx = line_no - 1
        if idx < 0 or idx >= len(new_lines):
            continue
        line = new_lines[idx]
        for (s, e), new_str in sorted(edits, key=lambda x: x[0][0], reverse=True):
            line = line[:s] + new_str + line[e:]
        new_lines[idx] = line
    return new_lines


def unified_diff_for(plan: FilePlan) -> str:
    new_lines = apply_file_plan(plan)
    diff = difflib.unified_diff(
        [l + "\n" for l in plan.original_lines],
        [l + "\n" for l in new_lines],
        fromfile=f"a/{plan.relpath}",
        tofile=f"b/{plan.relpath}",
        lineterm="\n",
    )
    return "".join(diff)


def write_file_plan(plan: FilePlan) -> None:
    """Write the updated file back to disk, preserving trailing newline state."""
    new_lines = apply_file_plan(plan)
    # Preserve whether the original file ended with a newline.
    with open(plan.path, "rb") as fh:
        ended_with_newline = fh.read()[-1:] == b"\n"
    text = "\n".join(new_lines)
    if ended_with_newline:
        text += "\n"
    with open(plan.path, "w", encoding="utf-8") as fh:
        fh.write(text)


# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

def fmt_version(v: Tuple[int, ...]) -> str:
    return ".".join(str(p) for p in v)


def hr(char: str = "-", width: int = 72) -> str:
    return char * width


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="chromedriver_pin_sync.py",
        description=(
            "Offline ChromeDriver pin auditor/updater. Detects the locally "
            "installed ChromeDriver version, finds where the version is "
            "pinned in a repo, shows the diff, and (with --apply) bumps pins "
            "that are BEHIND your installed driver. No network access."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--repo", "-r", required=True,
        help="Path to the repository / checkout to scan.",
    )
    parser.add_argument(
        "--version", "-V", dest="explicit_version", default=None,
        help="Installed ChromeDriver version to use, e.g. 128.0.6613.119. "
             "Use this on air-gapped hosts where the binary can't be run.",
    )
    parser.add_argument(
        "--chromedriver", "-c", dest="chromedriver", default=None,
        help="Explicit path to the chromedriver binary to interrogate.",
    )
    parser.add_argument(
        "--apply", action="store_true",
        help="Actually write the upgrades to disk. Default is a dry run "
             "that only shows the diff.",
    )
    parser.add_argument(
        "--quiet", "-q", action="store_true",
        help="Print less: suppress the 'already current' / 'ahead' detail.",
    )
    args = parser.parse_args(argv)

    repo_root = os.path.abspath(os.path.expanduser(args.repo))
    if not os.path.isdir(repo_root):
        print(f"error: --repo is not a directory: {repo_root}", file=sys.stderr)
        return 1

    # --- Step 1: detect installed version ---------------------------------
    try:
        detection = detect_installed_version(
            args.explicit_version, args.chromedriver
        )
    except SystemExit as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if detection is None:
        print(
            "error: could not detect an installed ChromeDriver version.\n"
            "       No chromedriver binary was found on PATH or in the "
            "well-known locations,\n"
            "       and no Chrome/Chromium fallback was available.\n"
            "       Re-run with --version <x.y.z.w> to supply it manually,\n"
            "       or with --chromedriver <path> to point at the binary.",
            file=sys.stderr,
        )
        return 1

    print(hr("="))
    print("ChromeDriver pin sync  (offline / no network)")
    print(hr("="))
    print(f"Installed ChromeDriver : {fmt_version(detection.version)}")
    print(f"  detected from        : {detection.source}")
    if detection.raw and detection.raw != fmt_version(detection.version):
        print(f"  raw version string   : {detection.raw}")
    print(f"Repository scanned     : {repo_root}")
    print()

    # --- Step 2: scan repo for pins ---------------------------------------
    hits = scan_repo_for_pins(repo_root)
    if not hits:
        print("No ChromeDriver version pins were found in the repository.")
        print("Nothing to compare. (Scanned config, CI, Docker, and manifest "
              "files.)")
        return 0

    print(f"Found {len(hits)} ChromeDriver version pin(s):")
    for h in hits:
        print(f"  {h.relpath}:{h.line_no}  ->  {h.version_str}")
    print()

    # --- Step 3: classify + show diff -------------------------------------
    upgrades, equal, ahead = build_plan(hits, detection.version)

    if not args.quiet:
        if equal:
            print(f"Already current ({len(equal)}) -- pin matches installed:")
            for h in equal:
                print(f"  {h.relpath}:{h.line_no}  =  {h.version_str}")
            print()
        if ahead:
            print(f"Ahead of installed ({len(ahead)}) -- pin is HIGHER than "
                  f"your driver; left untouched:")
            for h in ahead:
                print(f"  {h.relpath}:{h.line_no}  >  {h.version_str}  "
                      f"(installed {fmt_version(detection.version)})")
            print()

    if not upgrades:
        print(hr())
        print("Result: no pins are behind your installed ChromeDriver. "
              "Nothing to update.")
        return 0

    file_plans = group_changes_by_file(upgrades)

    print(hr())
    print(f"Upgrades available ({len(upgrades)} pin(s) in "
          f"{len(file_plans)} file(s)) -- installed driver is HIGHER:")
    print()
    for ch in upgrades:
        print(f"  {ch.hit.relpath}:{ch.hit.line_no}   "
              f"{ch.old_version_str}  ->  {ch.new_version_str}")
    print()
    print(hr())
    print("DIFF" + ("  (dry run -- not written)" if not args.apply
                    else "  (applying)"))
    print(hr())
    for plan in file_plans:
        sys.stdout.write(unified_diff_for(plan))
    print()

    # --- Step 4: apply, or report dry-run ---------------------------------
    if not args.apply:
        print(hr())
        print("Dry run complete. Re-run with --apply to write these changes.")
        # Exit 2 signals "the repo is behind" for CI-style gating.
        return 2

    for plan in file_plans:
        write_file_plan(plan)
        print(f"updated: {plan.relpath}")
    print()
    print(hr())
    print(f"Applied {len(upgrades)} upgrade(s) across {len(file_plans)} "
          f"file(s). Review with `git diff` before committing.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        # Downstream (e.g. `| head`) closed the pipe early. Exit quietly.
        try:
            sys.stdout.close()
        except Exception:
            pass
        os._exit(0)
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        os._exit(130)
