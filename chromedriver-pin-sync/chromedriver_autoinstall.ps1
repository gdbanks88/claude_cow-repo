#Requires -Version 5.1
<#
.SYNOPSIS
    Resolve the ChromeDriver that matches the locally installed Google Chrome
    and install it -- for Windows Server 2022 (Windows PowerShell 5.1+).

.DESCRIPTION
    Companion to chromedriver_pin_sync.ps1. Where that script is strictly
    OFFLINE (audits/updates repo pins), THIS script is the ONLINE installer:
    its whole job is to (1) find the correct ChromeDriver version for the
    Chrome you have and (2) install that driver locally. Nothing else.

    How the version is resolved (Google's documented lookup for a non-CfT
    Chrome binary):
      * Read the installed Chrome version, take MAJOR.MINOR.BUILD, and ask the
        Chrome-for-Testing "latest patch per build" endpoint:
            LATEST_RELEASE_<MAJOR.MINOR.BUILD>
      * If there is no entry for that build yet, fall back to the milestone
        endpoint (latest version per milestone):
            LATEST_RELEASE_<MAJOR>
      Since Chrome M115+, ChromeDriver ships in lockstep with Chrome, so the
      resolved driver is guaranteed to match your browser's major.

    Downloads use a NATIVE WINDOWS API -- urlmon!URLDownloadToFile (WinINet
    under the hood, honoring the system/WinHTTP proxy and SChannel TLS) -- via
    P/Invoke, not Invoke-WebRequest. If outbound egress is blocked, download the
    matching chromedriver-win64.zip from another machine
    (https://googlechromelabs.github.io/chrome-for-testing/) and pass it with
    -ZipPath to install with ZERO network access.

    Scope guardrails (by design):
      * It ONLY finds the correct version and installs the driver locally.
      * It does NOT touch any repository, pins, tests, or Chrome itself.
      * It does not auto-update Chrome or schedule anything.

.PARAMETER Destination
    Full path to install chromedriver.exe to. Default: C:\WebDriver\chromedriver.exe.
    (Writing under C:\ typically needs an elevated shell.)

.PARAMETER ChromePath
    Explicit path to chrome.exe. Default: auto-detect from the usual install
    locations and the registry.

.PARAMETER DriverVersion
    Force a specific ChromeDriver version (e.g. 150.0.7871.120) and skip the
    CfT lookup. Still downloads unless -ZipPath is given.

.PARAMETER Platform
    Chrome-for-Testing platform folder. Default win64. (win32 also valid.)

.PARAMETER ZipPath
    Install from a pre-downloaded chromedriver-<platform>.zip instead of
    downloading. Makes the run fully offline (for egress-blocked hosts).

.EXAMPLE
    .\chromedriver_autoinstall.ps1
    Detect Chrome, resolve + download the matching ChromeDriver, install to
    C:\WebDriver\chromedriver.exe.

.EXAMPLE
    .\chromedriver_autoinstall.ps1 -Destination C:\Selenium\chromedriver.exe

.EXAMPLE
    .\chromedriver_autoinstall.ps1 -ZipPath D:\stage\chromedriver-win64.zip
    Egress blocked: install from a sideloaded zip, no network.

.NOTES
    Exit codes: 0 success; 1 error.
    Run elevated when installing under a protected path (e.g. C:\WebDriver).
#>

[CmdletBinding()]
param(
    [Alias('d')]
    [string] $Destination = 'C:\WebDriver\chromedriver.exe',

    [string] $ChromePath,

    [Alias('V')]
    [string] $DriverVersion,

    [ValidateSet('win64', 'win32')]
    [string] $Platform = 'win64',

    [string] $ZipPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Chrome-for-Testing endpoints (the only hosts this script contacts).
$script:CftBase = 'https://googlechromelabs.github.io/chrome-for-testing'
$script:CftStorage = 'https://storage.googleapis.com/chrome-for-testing-public'

$script:CommonBrowserPaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)
$script:ChromeRegistryKeys = @(
    'HKLM:\SOFTWARE\Google\Chrome\BLBeacon',
    'HKLM:\SOFTWARE\Wow6432Node\Google\Chrome\BLBeacon',
    'HKCU:\Software\Google\Chrome\BLBeacon'
)

# ---------------------------------------------------------------------------
# Native Windows download API: urlmon!URLDownloadToFile via P/Invoke.
# ---------------------------------------------------------------------------

Add-Type -Namespace Win32 -Name UrlmonDownloader -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("urlmon.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern int URLDownloadToFile(System.IntPtr pCaller, string szURL, string szFileName, int dwReserved, System.IntPtr lpfnCB);
'@ -ErrorAction SilentlyContinue

function Invoke-WinApiDownload {
    <# Download $Url to $OutFile using the Windows urlmon API. #>
    param([string] $Url, [string] $OutFile)
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
    $hr = [Win32.UrlmonDownloader]::URLDownloadToFile([IntPtr]::Zero, $Url, $OutFile, 0, [IntPtr]::Zero)
    if ($hr -ne 0) {
        throw ("URLDownloadToFile failed for {0} (HRESULT 0x{1:X8}). Check egress/proxy; or sideload with -ZipPath." -f $Url, $hr)
    }
    if (-not (Test-Path -LiteralPath $OutFile)) {
        throw "download reported success but produced no file: $OutFile"
    }
}

function Get-RemoteText {
    <# Fetch a small text resource (the LATEST_RELEASE endpoints) via the Win API. #>
    param([string] $Url)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-WinApiDownload -Url $Url -OutFile $tmp
        return ([System.IO.File]::ReadAllText($tmp)).Trim()
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Local Chrome detection (no execution: file version, then registry).
# ---------------------------------------------------------------------------

function Get-ChromeVersion {
    param([string] $ExplicitPath)

    $paths = @()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
            throw "-ChromePath does not exist: $ExplicitPath"
        }
        $paths += $ExplicitPath
    }
    $paths += $script:CommonBrowserPaths

    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            try {
                $pv = (Get-Item -LiteralPath $p).VersionInfo.ProductVersion
            } catch {
                $pv = $null
            }
            if ($pv -and ($pv -match '\d+(\.\d+){1,3}')) {
                return $Matches[0]
            }
        }
    }

    foreach ($key in $script:ChromeRegistryKeys) {
        try {
            $rv = (Get-ItemProperty -Path $key -ErrorAction Stop).version
        } catch {
            $rv = $null
        }
        if ($rv -and ($rv -match '\d+(\.\d+){1,3}')) {
            return $Matches[0]
        }
    }

    return $null
}

function Get-MajorVersion {
    param([string] $Version)
    return ($Version -split '\.')[0]
}

# ---------------------------------------------------------------------------
# Version resolution via Chrome-for-Testing
# ---------------------------------------------------------------------------

function Resolve-DriverVersion {
    <#
        Given a full Chrome version, return the matching ChromeDriver version
        using LATEST_RELEASE_<MAJOR.MINOR.BUILD>, falling back to
        LATEST_RELEASE_<MAJOR>.
    #>
    param([string] $ChromeVersion)
    $parts = $ChromeVersion -split '\.'
    if ($parts.Count -lt 3) {
        throw "unexpected Chrome version '$ChromeVersion' (need at least MAJOR.MINOR.BUILD)"
    }
    $mmb = ($parts[0..2] -join '.')
    $major = $parts[0]

    $candidates = @(
        [pscustomobject]@{ Label = "build $mmb";   Url = "$script:CftBase/LATEST_RELEASE_$mmb" },
        [pscustomobject]@{ Label = "milestone $major"; Url = "$script:CftBase/LATEST_RELEASE_$major" }
    )

    foreach ($c in $candidates) {
        Write-Host ("Resolving ChromeDriver via CfT ({0}) ..." -f $c.Label)
        $text = $null
        try {
            $text = Get-RemoteText $c.Url
        } catch {
            Write-Host ("  lookup failed: " + $_.Exception.Message) -ForegroundColor DarkYellow
            continue
        }
        if ($text -and ($text -match '^\d+(\.\d+){3}$')) {
            return $text
        }
        Write-Host ("  no usable version at that endpoint (got: '" + $text + "')") -ForegroundColor DarkYellow
    }
    throw "could not resolve a ChromeDriver version for Chrome $ChromeVersion from Chrome-for-Testing."
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

function Install-ChromeDriverFromZip {
    <# Extract chromedriver.exe from $Zip and place it at $Destination. #>
    param([string] $Zip, [string] $Destination)

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("cdinstall_" + [System.IO.Path]::GetFileNameWithoutExtension($Zip))
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $Zip -DestinationPath $work -Force

        $exe = Get-ChildItem -LiteralPath $work -Recurse -Filter 'chromedriver.exe' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $exe) {
            throw "no chromedriver.exe found inside $Zip"
        }

        # Release any lock on the target first.
        Get-Process chromedriver -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

        $destDir = Split-Path -Parent $Destination
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $exe.FullName -Destination $Destination -Force
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-IsElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal] $id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    } catch {
        return $true   # non-Windows / cannot determine: don't block
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function Invoke-Main {
    Write-Host '========================================================================'
    Write-Host 'ChromeDriver auto-install  (resolves + installs a matching driver)'
    Write-Host '========================================================================'

    $destDir = Split-Path -Parent $Destination
    if ($destDir -and (Test-Path -LiteralPath $destDir) -and -not (Test-IsElevated)) {
        Write-Host "note: not running elevated; writing to '$destDir' may be denied." -ForegroundColor DarkYellow
    }

    # --- Acquire the driver zip -------------------------------------------
    $zip = $null
    $cleanupZip = $false
    $resolvedVersion = $DriverVersion

    if (-not [string]::IsNullOrWhiteSpace($ZipPath)) {
        if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
            [Console]::Error.WriteLine("error: -ZipPath not found: $ZipPath")
            return 1
        }
        $zip = $ZipPath
        Write-Host ("Installing from sideloaded zip (no network): " + $zip)
    } else {
        # Need a version: use -DriverVersion, else resolve from installed Chrome.
        if ([string]::IsNullOrWhiteSpace($resolvedVersion)) {
            $chromeVer = Get-ChromeVersion -ExplicitPath $ChromePath
            if ($null -eq $chromeVer) {
                [Console]::Error.WriteLine(@"
error: could not detect an installed Chrome version.
       Pass -ChromePath <path to chrome.exe>, or -DriverVersion <x.y.z.w>,
       or -ZipPath <chromedriver-$Platform.zip> to install offline.
"@)
                return 1
            }
            Write-Host ("Installed Chrome       : " + $chromeVer)
            $resolvedVersion = Resolve-DriverVersion -ChromeVersion $chromeVer
        }
        Write-Host ("ChromeDriver to install: " + $resolvedVersion)

        $zipUrl = "$script:CftStorage/$resolvedVersion/$Platform/chromedriver-$Platform.zip"
        $zip = Join-Path ([System.IO.Path]::GetTempPath()) ("chromedriver-$resolvedVersion-$Platform.zip")
        $cleanupZip = $true
        Write-Host ("Downloading (Win API)  : " + $zipUrl)
        try {
            Invoke-WinApiDownload -Url $zipUrl -OutFile $zip
        } catch {
            [Console]::Error.WriteLine("error: " + $_.Exception.Message)
            return 1
        }
    }

    # --- Install ----------------------------------------------------------
    try {
        Install-ChromeDriverFromZip -Zip $zip -Destination $Destination
    } catch {
        [Console]::Error.WriteLine("error: install failed: " + $_.Exception.Message)
        return 1
    } finally {
        if ($cleanupZip -and (Test-Path -LiteralPath $zip)) {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ("Installed to           : " + $Destination)

    # --- Verify -----------------------------------------------------------
    $verOut = $null
    try {
        $verOut = (& $Destination --version 2>&1 | Out-String).Trim()
    } catch {
        $verOut = $null
    }
    if ($verOut) {
        Write-Host ("Verify                 : " + $verOut)
    } else {
        Write-Host "Verify                 : (could not run the installed binary)" -ForegroundColor DarkYellow
    }

    # Optional post-install sanity: driver major vs Chrome major.
    if ([string]::IsNullOrWhiteSpace($ZipPath)) {
        try {
            $chk = Get-ChromeVersion -ExplicitPath $ChromePath
            if ($chk -and $verOut -and ($verOut -match '\d+(\.\d+){3}')) {
                $dMaj = Get-MajorVersion $Matches[0]
                $cMaj = Get-MajorVersion $chk
                if ($dMaj -ne $cMaj) {
                    Write-Host ("WARNING: installed driver major ($dMaj) != Chrome major ($cMaj)." ) -ForegroundColor Yellow
                } else {
                    Write-Host ("Match                  : driver and Chrome are both major $cMaj.") -ForegroundColor Green
                }
            }
        } catch { }
    }

    Write-Host '------------------------------------------------------------------------'
    Write-Host 'Done.'
    return 0
}

$code = Invoke-Main
exit $code
