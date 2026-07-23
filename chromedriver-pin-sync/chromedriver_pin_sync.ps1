#Requires -Version 5.1
<#
.SYNOPSIS
    Offline ChromeDriver pin auditor/updater for Windows (Windows Server 2022,
    Windows PowerShell 5.1+).

.DESCRIPTION
    Fully offline, single-file automation that:

      1. Detects the ChromeDriver version installed on THIS machine.
      2. Scans a repository (a checkout you choose) for every place the
         ChromeDriver version is *pinned*.
      3. Shows you a diff between what is pinned in the repo and what you have
         installed locally.
      4. Optionally updates the pinned version in the repo -- but ONLY when your
         locally installed ChromeDriver is a HIGHER version than the pin.

    Design constraints (all enforced):
      * NO network calls. NO API calls. NO outbound connections of any kind.
        The only external process this script ever runs is the local
        ChromeDriver binary with `--version` to read its version string.
        Nothing leaves the machine. Safe on a network-separated / air-gapped
        host (or pass -Version to skip execution entirely).
      * Windows PowerShell 5.1 (ships in the box on Windows Server 2022). Also
        runs on PowerShell 7+. No modules to install.
      * One file. Drop the containing folder anywhere and run it.

.PARAMETER Repo
    Path to the repository / checkout to scan. (Required.)

.PARAMETER Version
    Installed ChromeDriver version to use, e.g. 128.0.6613.119. Use this on
    air-gapped hosts where the binary can't be run.

.PARAMETER ChromeDriver
    Explicit path to the chromedriver.exe binary to interrogate.

.PARAMETER Apply
    Actually write the upgrades to disk. Without it, the run is a dry run that
    only shows the diff.

.PARAMETER Quiet
    Print less: suppress the 'already current' / 'ahead' detail.

.EXAMPLE
    .\chromedriver_pin_sync.ps1 -Repo C:\code\myapp
    Dry run: detect + scan + show the diff, change nothing.

.EXAMPLE
    .\chromedriver_pin_sync.ps1 -Repo C:\code\myapp -Apply
    Same, but WRITE the upgrades where installed > pinned.

.EXAMPLE
    .\chromedriver_pin_sync.ps1 -Repo C:\code\myapp -Version 128.0.6613.119
    Air-gapped box where the driver can't be executed: supply the version.

.NOTES
    Exit codes:
      0  success (nothing to do, or changes shown/applied cleanly)
      1  usage / environment error (bad repo path, no version, etc.)
      2  changes are AVAILABLE but were not applied (dry-run found upgrades).
         Handy for CI-style gating: exit 2 == "the repo is behind".
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias('r')]
    [string] $Repo,

    [Alias('V')]
    [string] $Version,

    [Alias('c')]
    [string] $ChromeDriver,

    [switch] $Apply,

    [Alias('q')]
    [switch] $Quiet
)

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Configuration: where drivers usually live on Windows, and which files to scan.
# ---------------------------------------------------------------------------

# Common locations for chromedriver.exe on Windows. Checked in order.
$script:CommonDriverPaths = @(
    "$env:ProgramFiles\chromedriver\chromedriver.exe",
    "${env:ProgramFiles(x86)}\chromedriver\chromedriver.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chromedriver.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chromedriver.exe",
    'C:\chromedriver\chromedriver.exe',
    'C:\chromedriver.exe',
    'C:\Selenium\chromedriver.exe',
    'C:\tools\chromedriver.exe',
    'C:\WebDriver\bin\chromedriver.exe',
    "$env:USERPROFILE\chromedriver.exe",
    "$env:LOCALAPPDATA\chromedriver\chromedriver.exe",
    "$env:ChocolateyInstall\bin\chromedriver.exe"
)

# As a fallback for version detection when no driver binary can be executed,
# read the installed Google Chrome / Chromium version -- ChromeDriver tracks
# Chrome's version number, so the major line matches.
$script:CommonBrowserPaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Chromium\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Chromium\Application\chrome.exe"
)

# Registry spots that hold the installed Chrome version string.
$script:ChromeRegistryKeys = @(
    'HKLM:\SOFTWARE\Google\Chrome\BLBeacon',
    'HKLM:\SOFTWARE\Wow6432Node\Google\Chrome\BLBeacon',
    'HKCU:\Software\Google\Chrome\BLBeacon'
)

# Directories we never descend into while scanning a repo.
$script:SkipDirs = @(
    '.git', '.hg', '.svn', 'node_modules', '.venv', 'venv', 'env',
    '__pycache__', '.mypy_cache', '.pytest_cache', '.tox', 'dist', 'build',
    '.idea', '.vscode', 'site-packages', '.cache', 'target', 'vendor'
)

# Only scan files that plausibly hold a version pin, by extension...
$script:ScanExtensions = @(
    '.txt', '.cfg', '.ini', '.toml', '.yaml', '.yml', '.json', '.env',
    '.sh', '.bash', '.zsh', '.ps1', '.psm1', '.psd1', '.bat', '.cmd',
    '.py', '.rb', '.js', '.ts', '.gradle', '.xml', '.properties', '.conf',
    '.tf', '.tfvars', '.mk', '.make', '.dockerfile', '.lock'
)
# ...or by exact filename.
$script:ScanFilenames = @(
    'Dockerfile', 'dockerfile', 'Makefile', 'makefile', '.tool-versions',
    'requirements.txt', 'constraints.txt', 'environment.yml', '.env',
    'Pipfile', 'Pipfile.lock', 'package.json', 'package-lock.json',
    'docker-compose.yml', 'docker-compose.yaml', '.chromedriver-version',
    '.chromedriver_version', 'chromedriver.version'
)

# A ChromeDriver version: a leading integer plus up to three ".integer" groups
# (e.g. 128, 128.0, 128.0.6613, 128.0.6613.119).
$script:VersionPattern = '\d+(\.\d+){0,3}'
$script:VersionRegex = [regex]::new($script:VersionPattern)
$script:FullVersionRegex = [regex]::new('^' + $script:VersionPattern + '$')
# The driver token in any of its spellings.
$script:DriverRegex = [regex]::new('chrome[_-]?driver',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

$script:MaxFileBytes = 2MB

# ---------------------------------------------------------------------------
# Version handling
# ---------------------------------------------------------------------------

function ConvertTo-VersionArray {
    <# Parse a dotted numeric version into an int[] (full match), or $null. #>
    param([string] $Text)
    if ($null -eq $Text) { return $null }
    $t = $Text.Trim()
    if ($script:FullVersionRegex.IsMatch($t)) {
        return @($t -split '\.' | ForEach-Object { [int] $_ })
    }
    return $null
}

function Get-FirstVersionArray {
    <# Extract the first version-looking token from arbitrary text. #>
    param([string] $Text)
    if ($null -eq $Text) { return $null }
    $m = [regex]::Match($Text, '\d+(\.\d+){1,3}')
    if ($m.Success) { return ConvertTo-VersionArray $m.Value }
    return $null
}

function Test-AcceptableVersion {
    <# Reject a stray single small integer (e.g. "chromedriver issue 3"). #>
    param([int[]] $Version)
    if ($null -eq $Version -or $Version.Length -eq 0) { return $false }
    if ($Version.Length -eq 1 -and $Version[0] -lt 60) { return $false }
    return $true
}

function Compare-PinVersion {
    <#
        Compare Installed vs Pinned, but only to the precision of the pin.
        ChromeDriver pins are written at different granularities: some repos
        pin just the major line "128", others the full "128.0.6613.119". We
        honor the pin's own precision by truncating the installed version to
        the pin's component count before comparing.
        Returns 1 if installed > pinned, 0 if equal, -1 if installed < pinned,
        all at the pin's granularity.
    #>
    param([int[]] $Installed, [int[]] $Pinned)
    $depth = $Pinned.Length
    for ($i = 0; $i -lt $depth; $i++) {
        $inst = if ($i -lt $Installed.Length) { $Installed[$i] } else { 0 }
        if ($inst -gt $Pinned[$i]) { return 1 }
        if ($inst -lt $Pinned[$i]) { return -1 }
    }
    return 0
}

function ConvertTo-NewPin {
    <#
        Render the installed version at the same granularity as the old pin,
        preserving how many components the maintainers chose to pin.
    #>
    param([int[]] $Installed, [int[]] $Pinned)
    $depth = $Pinned.Length
    $parts = @()
    for ($i = 0; $i -lt $depth; $i++) {
        if ($i -lt $Installed.Length) { $parts += $Installed[$i] } else { $parts += 0 }
    }
    return ($parts -join '.')
}

function Format-VersionArray {
    param([int[]] $Version)
    return ($Version -join '.')
}

# ---------------------------------------------------------------------------
# Local ChromeDriver / Chrome version detection (no network)
# ---------------------------------------------------------------------------

function Invoke-VersionBanner {
    <#
        Run `<binary> --version` locally and return raw output, or $null.
        This is the ONLY external process the program launches. It executes a
        local binary and reads its own version banner. No network is involved.
    #>
    param([string] $Binary)
    try {
        $out = & $Binary --version 2>&1 | Out-String
    } catch {
        return $null
    }
    if ($null -eq $out) { return $null }
    $out = $out.Trim()
    if ([string]::IsNullOrWhiteSpace($out)) { return $null }
    return $out
}

function Get-InstalledDriverVersion {
    <#
        Figure out the locally installed ChromeDriver version, offline.
        Priority:
          1. -Version supplied by the user (air-gapped hosts).
          2. -ChromeDriver <path> supplied by the user.
          3. chromedriver(.exe) on PATH.
          4. Well-known driver locations.
          5. Fallback: installed Chrome/Chromium version (file or registry).
        Returns a PSCustomObject { Version = int[]; Source; Raw } or $null.
    #>
    param([string] $ExplicitVersion, [string] $ExplicitBinary)

    # 1) Explicit version wins outright.
    if (-not [string]::IsNullOrWhiteSpace($ExplicitVersion)) {
        $v = ConvertTo-VersionArray $ExplicitVersion
        if ($null -eq $v) {
            throw "-Version '$ExplicitVersion' is not a valid dotted version (expected e.g. 128.0.6613.119)"
        }
        return [pscustomobject]@{ Version = $v; Source = 'provided via -Version'; Raw = $ExplicitVersion }
    }

    $candidates = New-Object System.Collections.Generic.List[string]

    # 2) Explicit binary path.
    if (-not [string]::IsNullOrWhiteSpace($ExplicitBinary)) {
        if (-not (Test-Path -LiteralPath $ExplicitBinary -PathType Leaf)) {
            throw "-ChromeDriver path does not exist: $ExplicitBinary"
        }
        $candidates.Add($ExplicitBinary)
    }

    # 3) PATH lookup.
    foreach ($name in @('chromedriver.exe', 'chromedriver')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $candidates.Add($cmd.Source); break }
    }

    # 4) Well-known locations.
    foreach ($p in $script:CommonDriverPaths) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { $candidates.Add($p) }
    }

    $seen = @{}
    foreach ($binary in $candidates) {
        $real = try { (Resolve-Path -LiteralPath $binary -ErrorAction Stop).Path } catch { $binary }
        if ($seen.ContainsKey($real)) { continue }
        $seen[$real] = $true
        $raw = Invoke-VersionBanner $binary
        if ($raw) {
            $v = Get-FirstVersionArray $raw
            if ($v) {
                return [pscustomobject]@{ Version = $v; Source = "chromedriver binary at $binary"; Raw = $raw }
            }
        }
    }

    # 5a) Fallback: Chrome/Chromium executable file version (no execution).
    foreach ($p in $script:CommonBrowserPaths) {
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            try {
                $pv = (Get-Item -LiteralPath $p).VersionInfo.ProductVersion
            } catch {
                $pv = $null
            }
            if ($pv) {
                $v = Get-FirstVersionArray $pv
                if ($v) {
                    return [pscustomobject]@{
                        Version = $v
                        Source  = "Chrome/Chromium at $p (driver version tracks the browser)"
                        Raw     = $pv
                    }
                }
            }
        }
    }

    # 5b) Fallback: Chrome version from the registry.
    foreach ($key in $script:ChromeRegistryKeys) {
        try {
            $item = Get-ItemProperty -Path $key -ErrorAction Stop
            $rv = $item.version
        } catch {
            $rv = $null
        }
        if ($rv) {
            $v = Get-FirstVersionArray $rv
            if ($v) {
                return [pscustomobject]@{
                    Version = $v
                    Source  = "Chrome version from registry $key (driver tracks the browser)"
                    Raw     = $rv
                }
            }
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Repository scan
# ---------------------------------------------------------------------------

function Test-ShouldScan {
    param([string] $Name)
    if ($script:ScanFilenames -contains $Name) { return $true }
    $ext = [System.IO.Path]::GetExtension($Name)
    if ($ext) { $ext = $ext.ToLower() }
    if ($ext -and ($script:ScanExtensions -contains $ext)) { return $true }
    $base = ($Name -split '\.', 2)[0]
    if (@('Dockerfile', 'dockerfile', 'Makefile', 'makefile') -contains $base) { return $true }
    return $false
}

function Get-CandidateFile {
    param([string] $RepoRoot)
    $rootLen = $RepoRoot.Length
    Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $file = $_
            $rel = $file.FullName.Substring($rootLen).TrimStart('\', '/')
            $segs = $rel -split '[\\/]'
            if ($segs.Length -gt 1) {
                $parentSegs = $segs[0..($segs.Length - 2)]
                $skip = $false
                foreach ($s in $parentSegs) {
                    if ($script:SkipDirs -contains $s) { $skip = $true; break }
                }
                if ($skip) { return }
            }
            if (-not (Test-ShouldScan $file.Name)) { return }
            if ($file.Length -gt $script:MaxFileBytes) { return }
            $file
        }
}

function Get-LeadingIndent {
    param([string] $Line)
    return ($Line.Length - $Line.TrimStart().Length)
}

function Read-RepoFile {
    <# Read a file preserving newline style + trailing-newline state. #>
    param([string] $Path)
    $raw = [System.IO.File]::ReadAllText($Path)
    $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $endsNL = $raw.EndsWith("`n")
    $lines = [regex]::Split($raw, "`r`n|`n|`r")
    if ($endsNL -and $lines.Length -gt 0 -and $lines[$lines.Length - 1] -eq '') {
        $lines = $lines[0..($lines.Length - 2)]
    }
    return [pscustomobject]@{ Lines = @($lines); Newline = $nl; EndsWithNewline = $endsNL }
}

function Find-DriverPins {
    <#
        Find ChromeDriver version pins in the repo -- precisely. For every line
        that mentions chromedriver (any spelling), capture exactly ONE version:
        the token directly associated with that mention (same-line value, a
        value to its left, or a nested value on the indented block beneath a
        bare key). Sibling / unrelated pins are never touched.
        Returns a list of hit PSCustomObjects.
    #>
    param([string] $RepoRoot)
    $hits = New-Object System.Collections.Generic.List[object]

    foreach ($file in Get-CandidateFile $RepoRoot) {
        try {
            $doc = Read-RepoFile $file.FullName
        } catch {
            continue
        }
        $lines = $doc.Lines
        $rel = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')

        for ($idx = 0; $idx -lt $lines.Length; $idx++) {
            $line = $lines[$idx]
            $tok = $script:DriverRegex.Match($line)
            if (-not $tok.Success) { continue }

            $foundIdx = -1
            $foundStr = $null
            $foundStart = -1
            $foundLen = 0
            $foundVer = $null

            # (a) A version to the RIGHT of the token on the same line.
            $after = $script:VersionRegex.Match($line, $tok.Index + $tok.Length)
            if ($after.Success) {
                $v = ConvertTo-VersionArray $after.Value
                if ((Test-AcceptableVersion $v)) {
                    $foundIdx = $idx; $foundStr = $after.Value
                    $foundStart = $after.Index; $foundLen = $after.Length; $foundVer = $v
                }
            }

            # (b) Otherwise a version to the LEFT (e.g. "114... # chromedriver").
            if (($null -eq $foundVer) -and $tok.Index -gt 0) {
                $left = $line.Substring(0, $tok.Index)
                $leftMatches = $script:VersionRegex.Matches($left)
                if ($leftMatches.Count -gt 0) {
                    $m = $leftMatches[$leftMatches.Count - 1]
                    $v = ConvertTo-VersionArray $m.Value
                    if ((Test-AcceptableVersion $v)) {
                        $foundIdx = $idx; $foundStr = $m.Value
                        $foundStart = $m.Index; $foundLen = $m.Length; $foundVer = $v
                    }
                }
            }

            # (c) Otherwise treat it as a nested key; look FORWARD into the
            #     indented block for the version value.
            if ($null -eq $foundVer) {
                $keyIndent = Get-LeadingIndent $line
                $look = 0
                for ($j = $idx + 1; $j -lt $lines.Length; $j++) {
                    $nxt = $lines[$j]
                    if ([string]::IsNullOrWhiteSpace($nxt)) { continue }
                    if ((Get-LeadingIndent $nxt) -le $keyIndent) { break }
                    $nv = $script:VersionRegex.Match($nxt, 0)
                    if ($nv.Success) {
                        $v = ConvertTo-VersionArray $nv.Value
                        if ((Test-AcceptableVersion $v)) {
                            $foundIdx = $j; $foundStr = $nv.Value
                            $foundStart = $nv.Index; $foundLen = $nv.Length; $foundVer = $v
                        }
                        break
                    }
                    $look++
                    if ($look -ge 5) { break }
                }
            }

            if ($null -eq $foundVer) { continue }

            $hits.Add([pscustomobject]@{
                Path       = $file.FullName
                RelPath    = $rel
                LineIndex  = $foundIdx
                LineNo     = $foundIdx + 1
                Line       = $lines[$foundIdx]
                VersionStr = $foundStr
                Start      = $foundStart
                Length     = $foundLen
                Version    = $foundVer
            })
        }
    }

    # De-duplicate, then order for humans.
    $unique = @{}
    foreach ($h in $hits) {
        $k = "$($h.Path)|$($h.LineNo)|$($h.Start)"
        $unique[$k] = $h
    }
    return @($unique.Values | Sort-Object RelPath, LineNo, Start)
}

# ---------------------------------------------------------------------------
# Diff + apply
# ---------------------------------------------------------------------------

function Get-UpdatedLines {
    <# Apply per-line, per-span edits (right-to-left within a line). #>
    param([string[]] $OrigLines, [hashtable] $EditsByLine)
    $new = @($OrigLines)
    foreach ($li in $EditsByLine.Keys) {
        $line = $new[$li]
        $edits = @($EditsByLine[$li] | Sort-Object Start -Descending)
        foreach ($e in $edits) {
            $line = $line.Substring(0, $e.Start) + $e.NewStr + $line.Substring($e.Start + $e.Length)
        }
        $new[$li] = $line
    }
    return , $new
}

function Write-UnifiedDiff {
    <# Print a readable diff for one file's changed lines, with 1 line of context. #>
    param([string] $RelPath, [string[]] $OrigLines, [string[]] $NewLines, [int[]] $ChangedIdx)
    Write-Host "--- a/$RelPath"
    Write-Host "+++ b/$RelPath"
    foreach ($i in ($ChangedIdx | Sort-Object -Unique)) {
        Write-Host ("@@ line " + ($i + 1) + " @@") -ForegroundColor Cyan
        if ($i - 1 -ge 0) { Write-Host ("  " + $OrigLines[$i - 1]) }
        Write-Host ("- " + $OrigLines[$i]) -ForegroundColor Red
        Write-Host ("+ " + $NewLines[$i]) -ForegroundColor Green
        if ($i + 1 -lt $OrigLines.Length) { Write-Host ("  " + $OrigLines[$i + 1]) }
    }
}

function Write-RepoFile {
    param([string] $Path, [string[]] $Lines, [string] $Newline, [bool] $EndsWithNewline)
    $out = [string]::Join($Newline, $Lines)
    if ($EndsWithNewline) { $out += $Newline }
    $enc = New-Object System.Text.UTF8Encoding($false)   # UTF-8, no BOM
    [System.IO.File]::WriteAllText($Path, $out, $enc)
}

# ---------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------

function Write-Rule {
    param([char] $Char = '-', [int] $Width = 72)
    Write-Host ([string]::new($Char, $Width))
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Invoke-Main {
    $repoRoot = $null
    try {
        $repoRoot = (Resolve-Path -LiteralPath $Repo -ErrorAction Stop).Path
    } catch {
        [Console]::Error.WriteLine("error: -Repo path not found: $Repo")
        return 1
    }
    if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
        [Console]::Error.WriteLine("error: -Repo is not a directory: $repoRoot")
        return 1
    }

    # --- Step 1: detect installed version ---------------------------------
    $detection = $null
    try {
        $detection = Get-InstalledDriverVersion -ExplicitVersion $Version -ExplicitBinary $ChromeDriver
    } catch {
        [Console]::Error.WriteLine("error: " + $_.Exception.Message)
        return 1
    }

    if ($null -eq $detection) {
        [Console]::Error.WriteLine(@"
error: could not detect an installed ChromeDriver version.
       No chromedriver.exe was found on PATH or in the well-known locations,
       and no Chrome/Chromium fallback (file or registry) was available.
       Re-run with -Version <x.y.z.w> to supply it manually,
       or with -ChromeDriver <path> to point at the binary.
"@)
        return 1
    }

    Write-Rule '='
    Write-Host 'ChromeDriver pin sync  (offline / no network)'
    Write-Rule '='
    Write-Host ("Installed ChromeDriver : " + (Format-VersionArray $detection.Version))
    Write-Host ("  detected from        : " + $detection.Source)
    if ($detection.Raw -and ($detection.Raw -ne (Format-VersionArray $detection.Version))) {
        Write-Host ("  raw version string   : " + $detection.Raw)
    }
    Write-Host ("Repository scanned     : " + $repoRoot)
    Write-Host ''

    # --- Step 2: scan repo for pins ---------------------------------------
    # Wrap in @() so an empty result stays an array (functions unroll @() to
    # $null on return, which StrictMode then rejects on .Count).
    $hits = @(Find-DriverPins $repoRoot)
    if ($hits.Count -eq 0) {
        Write-Host 'No ChromeDriver version pins were found in the repository.'
        Write-Host 'Nothing to compare. (Scanned config, CI, Docker, and manifest files.)'
        return 0
    }

    Write-Host ("Found " + $hits.Count + " ChromeDriver version pin(s):")
    foreach ($h in $hits) {
        Write-Host ("  " + $h.RelPath + ":" + $h.LineNo + "  ->  " + $h.VersionStr)
    }
    Write-Host ''

    # --- Step 3: classify --------------------------------------------------
    $upgrades = New-Object System.Collections.Generic.List[object]
    $equal = New-Object System.Collections.Generic.List[object]
    $ahead = New-Object System.Collections.Generic.List[object]

    foreach ($h in $hits) {
        $cmp = Compare-PinVersion $detection.Version $h.Version
        if ($cmp -gt 0) {
            $newStr = ConvertTo-NewPin $detection.Version $h.Version
            $upgrades.Add([pscustomobject]@{ Hit = $h; OldStr = $h.VersionStr; NewStr = $newStr })
        } elseif ($cmp -eq 0) {
            $equal.Add($h)
        } else {
            $ahead.Add($h)
        }
    }

    if (-not $Quiet) {
        if ($equal.Count -gt 0) {
            Write-Host ("Already current (" + $equal.Count + ") -- pin matches installed:")
            foreach ($h in $equal) { Write-Host ("  " + $h.RelPath + ":" + $h.LineNo + "  =  " + $h.VersionStr) }
            Write-Host ''
        }
        if ($ahead.Count -gt 0) {
            Write-Host ("Ahead of installed (" + $ahead.Count + ") -- pin is HIGHER than your driver; left untouched:")
            foreach ($h in $ahead) {
                Write-Host ("  " + $h.RelPath + ":" + $h.LineNo + "  >  " + $h.VersionStr +
                    "  (installed " + (Format-VersionArray $detection.Version) + ")")
            }
            Write-Host ''
        }
    }

    if ($upgrades.Count -eq 0) {
        Write-Rule
        Write-Host 'Result: no pins are behind your installed ChromeDriver. Nothing to update.'
        return 0
    }

    # Group upgrades by file.
    $byFile = [ordered]@{}
    foreach ($u in $upgrades) {
        $p = $u.Hit.Path
        if (-not $byFile.Contains($p)) { $byFile[$p] = New-Object System.Collections.Generic.List[object] }
        $byFile[$p].Add($u)
    }

    Write-Rule
    Write-Host ("Upgrades available (" + $upgrades.Count + " pin(s) in " + $byFile.Keys.Count +
        " file(s)) -- installed driver is HIGHER:")
    Write-Host ''
    foreach ($u in $upgrades) {
        Write-Host ("  " + $u.Hit.RelPath + ":" + $u.Hit.LineNo + "   " +
            $u.OldStr + "  ->  " + $u.NewStr)
    }
    Write-Host ''
    Write-Rule
    if ($Apply) { Write-Host 'DIFF  (applying)' } else { Write-Host 'DIFF  (dry run -- not written)' }
    Write-Rule

    # --- Step 4: show diff, then apply or report --------------------------
    foreach ($p in $byFile.Keys) {
        $doc = Read-RepoFile $p
        $editsByLine = @{}
        $changed = New-Object System.Collections.Generic.List[int]
        foreach ($u in $byFile[$p]) {
            $li = $u.Hit.LineIndex
            if (-not $editsByLine.ContainsKey($li)) {
                $editsByLine[$li] = New-Object System.Collections.Generic.List[object]
            }
            $editsByLine[$li].Add([pscustomobject]@{
                Start = $u.Hit.Start; Length = $u.Hit.Length; NewStr = $u.NewStr
            })
            $changed.Add($li)
        }
        $newLines = Get-UpdatedLines $doc.Lines $editsByLine
        $rel = $p.Substring($repoRoot.Length).TrimStart('\', '/')
        Write-UnifiedDiff -RelPath $rel -OrigLines $doc.Lines -NewLines $newLines -ChangedIdx $changed.ToArray()

        if ($Apply) {
            Write-RepoFile -Path $p -Lines $newLines -Newline $doc.Newline -EndsWithNewline $doc.EndsWithNewline
        }
    }
    Write-Host ''

    if (-not $Apply) {
        Write-Rule
        Write-Host 'Dry run complete. Re-run with -Apply to write these changes.'
        return 2   # exit 2 signals "the repo is behind" for CI-style gating.
    }

    Write-Rule
    foreach ($p in $byFile.Keys) {
        $rel = $p.Substring($repoRoot.Length).TrimStart('\', '/')
        Write-Host ("updated: " + $rel)
    }
    Write-Host ''
    Write-Rule
    Write-Host ("Applied " + $upgrades.Count + " upgrade(s) across " + $byFile.Keys.Count +
        " file(s). Review with 'git diff' before committing.")
    return 0
}

$code = Invoke-Main
exit $code
