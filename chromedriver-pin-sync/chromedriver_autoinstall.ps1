#Requires -Version 5.1
<#
    chromedriver_autoinstall.ps1  (Windows Server 2022 / PowerShell 5.1+)

    One job: pull down the ChromeDriver that matches the installed Google Chrome
    and install it locally. Nothing else -- no repo scanning, no pin editing.

    Downloads use the native Windows API urlmon!URLDownloadToFile (WinINet /
    SChannel, honors the system proxy), not Invoke-WebRequest.

    Params:
      -Destination  Where to place chromedriver.exe. Default C:\WebDriver\chromedriver.exe.
      -ChromePath   Explicit chrome.exe, if it isn't in a standard location.

    Exit: 0 on success; non-zero on any error.
#>

[CmdletBinding()]
param(
    [string] $Destination = 'C:\WebDriver\chromedriver.exe',
    [string] $ChromePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- native Windows download API -------------------------------------------
Add-Type -Namespace Win32 -Name Net -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("urlmon.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern int URLDownloadToFile(System.IntPtr pCaller, string szURL, string szFileName, int dwReserved, System.IntPtr lpfnCB);
'@ -ErrorAction SilentlyContinue

function Get-File([string] $Url, [string] $OutFile) {
    if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
    $hr = [Win32.Net]::URLDownloadToFile([IntPtr]::Zero, $Url, $OutFile, 0, [IntPtr]::Zero)
    if ($hr -ne 0) { throw ("download failed for {0} (HRESULT 0x{1:X8})" -f $Url, $hr) }
}

# --- 1. installed Chrome version -------------------------------------------
if (-not $ChromePath) {
    foreach ($p in @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                     "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                     "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")) {
        if (Test-Path -LiteralPath $p) { $ChromePath = $p; break }
    }
}
$chromeVer = $null
if ($ChromePath -and (Test-Path -LiteralPath $ChromePath)) {
    $chromeVer = (Get-Item -LiteralPath $ChromePath).VersionInfo.ProductVersion
}
if (-not $chromeVer) {
    foreach ($k in 'HKLM:\SOFTWARE\Google\Chrome\BLBeacon',
                   'HKLM:\SOFTWARE\Wow6432Node\Google\Chrome\BLBeacon',
                   'HKCU:\Software\Google\Chrome\BLBeacon') {
        try { $chromeVer = (Get-ItemProperty -Path $k -ErrorAction Stop).version } catch { }
        if ($chromeVer) { break }
    }
}
if (-not $chromeVer) { throw "could not find installed Chrome; pass -ChromePath <chrome.exe>" }
Write-Host "Installed Chrome : $chromeVer"

# --- 2. matching ChromeDriver version (Chrome-for-Testing) -----------------
# Latest patch for Chrome's MAJOR.MINOR.BUILD, else latest for the milestone.
$parts = $chromeVer -split '\.'
$build = "$($parts[0]).$($parts[1]).$($parts[2])"
$tmp = [System.IO.Path]::GetTempFileName()
$driverVer = $null
foreach ($u in "https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_$build",
               "https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_$($parts[0])") {
    try { Get-File $u $tmp; $v = ([System.IO.File]::ReadAllText($tmp)).Trim() } catch { $v = $null }
    if ($v -and ($v -match '^\d+(\.\d+){3}$')) { $driverVer = $v; break }
}
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
if (-not $driverVer) { throw "could not resolve a ChromeDriver version for Chrome $chromeVer" }
Write-Host "ChromeDriver     : $driverVer"

# --- 3. download + install --------------------------------------------------
$zip = Join-Path $env:TEMP "chromedriver-$driverVer-win64.zip"
$out = Join-Path $env:TEMP "chromedriver-$driverVer-win64"
Get-File "https://storage.googleapis.com/chrome-for-testing-public/$driverVer/win64/chromedriver-win64.zip" $zip
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
Expand-Archive -LiteralPath $zip -DestinationPath $out -Force

$exe = Join-Path $out 'chromedriver-win64\chromedriver.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "chromedriver.exe not found in the downloaded package" }

Get-Process chromedriver -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$destDir = Split-Path -Parent $Destination
if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
Copy-Item -LiteralPath $exe -Destination $Destination -Force
Remove-Item -LiteralPath $zip, $out -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Installed to     : $Destination"
& $Destination --version
