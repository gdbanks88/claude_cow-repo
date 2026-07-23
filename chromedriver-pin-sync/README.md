# chromedriver-pin-sync

A **single-file, fully offline** utility that reconciles the ChromeDriver
version pinned in a repository with the ChromeDriver version installed on the
machine you run it from.

It does four things, in order:

1. **Detects** the ChromeDriver version installed locally.
2. **Scans** a repository you choose for every place the ChromeDriver version
   is *pinned* (CI files, Dockerfiles, `requirements.txt`, `package.json`,
   `.tool-versions`, YAML, `.env`, and more).
3. **Shows you the diff** between what's pinned and what you have installed.
4. **Updates** the pins — but only the ones that are *behind* your installed
   driver — when you pass `--apply`.

## Hard guarantees

- **No network. No API calls. No back-end.** The only subprocess it ever runs
  is a local Chrome/ChromeDriver binary with `--version` to read its own
  version banner. Nothing leaves the host. Safe on air-gapped / network-
  separated systems.
- **Pure Python 3 standard library.** No `pip install`, no third-party deps.
- **One file** — `chromedriver_pin_sync.py`. Copy the folder anywhere and run.
- Targets **Linux (Red Hat family: RHEL / CentOS / Fedora)** and works on
  generic Linux and macOS layouts too.

## Requirements

- Python 3.6+ (standard library only).

## Usage

```bash
# 1) Dry run — detect + scan + show the diff, change nothing (default).
./chromedriver_pin_sync.py --repo /path/to/your/checkout

# 2) Same, but actually WRITE the upgrades (only where installed > pinned).
./chromedriver_pin_sync.py --repo /path/to/your/checkout --apply

# 3) Air-gapped box where the driver binary can't be executed?
#    Supply the installed version by hand:
./chromedriver_pin_sync.py --repo /path/to/checkout --version 128.0.6613.119

# 4) Point at a specific driver binary:
./chromedriver_pin_sync.py --repo /path/to/checkout \
    --chromedriver /opt/selenium/chromedriver
```

### Options

| Flag | Meaning |
|------|---------|
| `--repo`, `-r` | **(required)** Repository / checkout to scan. |
| `--version`, `-V` | Installed ChromeDriver version to use, e.g. `128.0.6613.119`. Use on air-gapped hosts. |
| `--chromedriver`, `-c` | Explicit path to the `chromedriver` binary to interrogate. |
| `--apply` | Write the upgrades to disk. Without it, the run is a dry run. |
| `--quiet`, `-q` | Suppress the "already current" / "ahead" detail. |

## How version detection works (offline)

Resolution order, first hit wins:

1. `--version` you supplied.
2. `--chromedriver <path>` you supplied.
3. `chromedriver` on `PATH`.
4. Well-known driver locations (`/usr/bin`, `/usr/local/bin`,
   `/opt/...`, etc.).
5. Fallback: the installed Google Chrome / Chromium version — ChromeDriver's
   version tracks the browser, so the major line matches.

## Update rules

- A pin is upgraded **only** when your installed driver is a *higher* version.
- Comparison honors the pin's own **granularity**: a major-only pin like
  `114` moves only when the major changes (→ `147`); a full pin like
  `114.0.5735.90` moves on any component (→ `147.0.7727.24`).
- A packaging suffix on a pip pin (e.g. `chromedriver-binary==114.0.5735.90.0`
  → `147.0.7727.24.0`) is preserved.
- Pins that are **equal to** or **ahead of** your installed driver are never
  touched (and the "ahead" ones are reported so you can see them).

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success — nothing to do, or changes shown/applied cleanly. |
| `1` | Usage / environment error (bad repo path, version undetectable, …). |
| `2` | Dry run found upgrades that were **not** written. Useful for CI gating: `2` == "the repo is behind". |

## What gets scanned

Config/manifest/CI files by extension (`.txt`, `.yml`, `.yaml`, `.json`,
`.toml`, `.env`, `.sh`, `.cfg`, `.ini`, `.gradle`, `.tf`, …) and by name
(`Dockerfile`, `Makefile`, `.tool-versions`, `requirements.txt`,
`package.json`, `docker-compose.yml`, …). VCS and dependency directories
(`.git`, `node_modules`, `.venv`, `dist`, `build`, …) are skipped.

A version counts as a ChromeDriver pin only when a `chromedriver` token (any
of `chromedriver` / `chrome-driver` / `chrome_driver` / `CHROMEDRIVER`) is
directly associated with it — on the same line, or as the key above a nested
`version:` value. Neighboring unrelated pins (e.g. `requests==2.31.0`) are
left alone.
