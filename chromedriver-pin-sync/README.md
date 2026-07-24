# chromedriver-pin-sync

PowerShell tooling for **Windows Server 2022** (Windows PowerShell 5.1, in-box;
also runs on PowerShell 7+) to keep ChromeDriver, Chrome, and your repo's
pinned version in agreement — and to fix the classic mismatch:

```
SessionNotCreatedException: This version of ChromeDriver only supports Chrome
version 148 / Current browser version is 150.0.7871.129
```

There are **two scripts**, with deliberately different network postures:

| Script | Network | Job |
|--------|---------|-----|
| `chromedriver_pin_sync.ps1` | **None (offline)** | Detect installed driver **and** browser, warn on major mismatch, and update the ChromeDriver version pinned in a repo. |
| `chromedriver_autoinstall.ps1` | **Online** | Resolve the ChromeDriver that matches your installed Chrome and install it locally, downloading via a native Windows API. |

---

## 1. `chromedriver_pin_sync.ps1` — offline pin auditor/updater

Fully offline. The only OS interaction is spawning the local driver/Chrome
binary to read its `--version`; use `-Version` to avoid even that. No network,
no API calls.

It:

1. Detects the installed **ChromeDriver** (binary `--version`) **and** the
   installed **Chrome** (executable file-version or `BLBeacon` registry key).
2. **Warns** when their major versions differ — the exact cause of the Selenium
   `SessionNotCreatedException` above.
3. Scans a repo you choose for every place the ChromeDriver version is *pinned*
   (CI files, Dockerfiles, `requirements.txt`, `package.json`, `.tool-versions`,
   YAML, `.env`, …).
4. Shows a **diff**, and with `-Apply` updates the pins that are *behind* the
   version being synced.

### Usage

```powershell
# Dry run: detect both, warn on mismatch, show the diff. Changes nothing.
.\chromedriver_pin_sync.ps1 -Repo C:\code\myapp

# Write the pin updates.
.\chromedriver_pin_sync.ps1 -Repo C:\code\myapp -Apply

# Air-gapped: supply the version, no binary is executed.
.\chromedriver_pin_sync.ps1 -Repo C:\code\myapp -Version 150.0.7871.120
```

### Which version drives the pin? (`-Source`)

When the installed driver and browser differ, `-Source` decides what the repo
is pinned to:

| `-Source` | Pins to |
|-----------|---------|
| `Auto` *(default)* | The **Chrome browser** version — that *is* the ChromeDriver version you need — falling back to the driver if no browser is found. |
| `Browser` | Always the Chrome browser version. |
| `Driver` | Always the installed ChromeDriver version. |
| `Newer` | The higher of the two. |

> Given the mismatch error, `Auto` intentionally pins to **Chrome's** version so
> provisioning/CI fetches a *matching* driver — not the stale driver you happen
> to have on disk.

### Parameters

| Parameter | Meaning |
|-----------|---------|
| `-Repo`, `-r` | **(required)** Repository / checkout to scan. |
| `-Version`, `-V` | Version to sync to; skips detection (air-gapped). |
| `-ChromeDriver`, `-c` | Explicit path to `chromedriver.exe`. |
| `-Source`, `-s` | `Auto` / `Browser` / `Driver` / `Newer` (see above). |
| `-Apply` | Write the updates. Without it, dry run. |
| `-Quiet`, `-q` | Suppress the "already current" / "ahead" detail. |

Exit codes: `0` clean, `1` error, `2` dry-run found upgrades ("repo is behind",
useful for CI gating). Update rules honor each pin's granularity, preserve pip
packaging suffixes, and preserve CRLF/LF + trailing-newline on write.

---

## 2. `chromedriver_autoinstall.ps1` — resolve + install a matching driver

This is the **online** companion. Its whole job is: find the correct
ChromeDriver for the Chrome you have, and install it locally. It does **not**
touch any repo, tests, or Chrome itself.

Version resolution follows Google's documented lookup for a non-CfT Chrome
binary: take Chrome's `MAJOR.MINOR.BUILD` and query the Chrome-for-Testing
"latest patch per build" endpoint, falling back to the milestone endpoint:

```
https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_<MAJOR.MINOR.BUILD>
https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_<MAJOR>   (fallback)
```

The download uses a **native Windows API — `urlmon!URLDownloadToFile`** (WinINet
under the hood, honoring the system/WinHTTP proxy and SChannel TLS) via
P/Invoke, not `Invoke-WebRequest`.

### Usage

```powershell
# Detect Chrome, resolve + download the matching driver, install it.
# (Run elevated when writing under C:\ .)
.\chromedriver_autoinstall.ps1

# Install somewhere else.
.\chromedriver_autoinstall.ps1 -Destination C:\Selenium\chromedriver.exe
```

### Parameters

| Parameter | Meaning |
|-----------|---------|
| `-Destination` | Install path. Default `C:\WebDriver\chromedriver.exe`. |
| `-ChromePath` | Explicit `chrome.exe`, if it isn't in a standard location. |

Exit: `0` on success, non-zero on error. It stops any running `chromedriver`
process before replacing the binary and verifies with `chromedriver --version`.

---

## Recommended workflow

1. **Diagnose / prevent:** run `chromedriver_pin_sync.ps1 -Repo <repo>` in CI or
   pre-suite. The driver-vs-browser mismatch warning (and exit `2` on stale
   pins) turns a `SessionNotCreatedException` stack into a one-line failure.
2. **Fix the box:** run `chromedriver_autoinstall.ps1` to drop a matching
   ChromeDriver next to your Chrome.
3. **Get off the moving target:** pin a Chrome-for-Testing build and its matched
   driver as a pair (mirror the zips into your artifact registry for runners) so
   production Chrome auto-updating can't drift out from under a pinned driver.

## Requirements

- Windows Server 2022 / Windows 10/11, Windows PowerShell 5.1+ — no modules.
- `chromedriver_autoinstall.ps1` needs outbound HTTPS to
  `googlechromelabs.github.io` and `storage.googleapis.com`.
