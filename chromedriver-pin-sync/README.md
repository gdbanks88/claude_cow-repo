# chromedriver-pin-sync

A **single-file, fully offline** PowerShell utility that reconciles the
ChromeDriver version pinned in a repository with the ChromeDriver version
installed on the machine you run it from. Built for **Windows Server 2022**
(Windows PowerShell 5.1, which ships in the box) and also runs on
PowerShell 7+.

It does four things, in order:

1. **Detects** the ChromeDriver version installed locally.
2. **Scans** a repository you choose for every place the ChromeDriver version
   is *pinned* (CI files, Dockerfiles, `requirements.txt`, `package.json`,
   `.tool-versions`, YAML, `.env`, and more).
3. **Shows you the diff** between what's pinned and what you have installed.
4. **Updates** the pins — but only the ones that are *behind* your installed
   driver — when you pass `-Apply`.

## Hard guarantees

- **No network. No API calls. No back-end.** The only external process it ever
  runs is a local Chrome/ChromeDriver binary with `--version` to read its own
  version banner. Nothing leaves the host. Safe on air-gapped / network-
  separated systems (or pass `-Version` to skip execution entirely).
- **In-box PowerShell.** Windows PowerShell 5.1 on Windows Server 2022, no
  modules to install. Runs on PowerShell 7+ too.
- **One file** — `chromedriver_pin_sync.ps1`. Copy the folder anywhere and run.

## Requirements

- Windows Server 2022 (or Windows 10/11), Windows PowerShell 5.1+ — no
  additional modules.

## Usage

```powershell
# 1) Dry run — detect + scan + show the diff, change nothing (default).
.\chromedriver_pin_sync.ps1 -Repo C:\code\myapp

# 2) Same, but actually WRITE the upgrades (only where installed > pinned).
.\chromedriver_pin_sync.ps1 -Repo C:\code\myapp -Apply

# 3) Air-gapped box where the driver binary can't be executed?
#    Supply the installed version by hand:
.\chromedriver_pin_sync.ps1 -Repo C:\code\myapp -Version 128.0.6613.119

# 4) Point at a specific driver binary:
.\chromedriver_pin_sync.ps1 -Repo C:\code\myapp -ChromeDriver "C:\Selenium\chromedriver.exe"
```

If script execution is blocked by policy, run it for the current process only:

```powershell
powershell -ExecutionPolicy Bypass -File .\chromedriver_pin_sync.ps1 -Repo C:\code\myapp
```

### Parameters

| Parameter | Meaning |
|-----------|---------|
| `-Repo`, `-r` | **(required)** Repository / checkout to scan. |
| `-Version`, `-V` | Installed ChromeDriver version to use, e.g. `128.0.6613.119`. Use on air-gapped hosts. |
| `-ChromeDriver`, `-c` | Explicit path to the `chromedriver.exe` binary to interrogate. |
| `-Apply` | Write the upgrades to disk. Without it, the run is a dry run. |
| `-Quiet`, `-q` | Suppress the "already current" / "ahead" detail. |

## How version detection works (offline)

Resolution order, first hit wins:

1. `-Version` you supplied.
2. `-ChromeDriver <path>` you supplied.
3. `chromedriver.exe` on `PATH`.
4. Well-known driver locations (`Program Files`, `C:\chromedriver`,
   `C:\Selenium`, Chocolatey `bin`, etc.).
5. Fallback: the installed Google Chrome / Chromium version — read from the
   executable's file version, or from the registry (`BLBeacon`). ChromeDriver's
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
- Original line endings (CRLF/LF) and trailing-newline state are preserved on
  write.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success — nothing to do, or changes shown/applied cleanly. |
| `1` | Usage / environment error (bad repo path, version undetectable, …). |
| `2` | Dry run found upgrades that were **not** written. Useful for CI gating: `2` == "the repo is behind". |

## What gets scanned

Config/manifest/CI files by extension (`.txt`, `.yml`, `.yaml`, `.json`,
`.toml`, `.env`, `.ps1`, `.bat`, `.cmd`, `.cfg`, `.ini`, `.gradle`, `.tf`, …)
and by name (`Dockerfile`, `Makefile`, `.tool-versions`, `requirements.txt`,
`package.json`, `docker-compose.yml`, …). VCS and dependency directories
(`.git`, `node_modules`, `.venv`, `dist`, `build`, …) are skipped.

A version counts as a ChromeDriver pin only when a `chromedriver` token (any
of `chromedriver` / `chrome-driver` / `chrome_driver` / `CHROMEDRIVER`) is
directly associated with it — on the same line, or as the key above a nested
`version:` value. Neighboring unrelated pins (e.g. `requests==2.31.0`) are
left alone.
