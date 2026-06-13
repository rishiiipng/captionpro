#Requires -Version 5.1
<#
.SYNOPSIS
  CaptionPro - Interactive Installer

.DESCRIPTION
  Checks dependencies, locates DaVinci Resolve Scripts folder (including
  non-default install paths), copies all plugin files, and logs every step.
  Re-running the installer is always safe - existing files are overwritten.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ==============================================================================
# 0. Logging
# ==============================================================================

$LogDir  = Join-Path $env:USERPROFILE "CaptionPro Logs"
$LogFile = Join-Path $LogDir "install.log"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
  param([string]$Msg, [string]$Level = "INFO")
  $ts   = Get-Date -Format "HH:mm:ss"
  $line = "[$ts][$Level] $Msg"
  Add-Content -Path $LogFile -Value $line
}

Set-Content -Path $LogFile -Value (
  "=== CaptionPro Installer  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===`n"
)

# ==============================================================================
# 1. Console helpers
# ==============================================================================

function Write-Banner {
  Clear-Host
  Write-Host ""
  Write-Host "  +--------------------------------------------------+" -ForegroundColor Cyan
  Write-Host "  |          CaptionPro  -  Installer                |" -ForegroundColor Cyan
  Write-Host "  |          Alpha v0.1  -  Created by Rishi          |" -ForegroundColor Cyan
  Write-Host "  +--------------------------------------------------+" -ForegroundColor Cyan
  Write-Host ""
}

function Write-Step {
  param([string]$Text)
  Write-Host "  >>  $Text" -ForegroundColor White
  Write-Log $Text
}

function Write-Ok {
  param([string]$Text)
  Write-Host "  [OK]  $Text" -ForegroundColor Green
  Write-Log $Text "OK"
}

function Write-Warn {
  param([string]$Text)
  Write-Host "  [!!]  $Text" -ForegroundColor Yellow
  Write-Log $Text "WARN"
}

function Write-Fail {
  param([string]$Text)
  Write-Host "  [XX]  $Text" -ForegroundColor Red
  Write-Log $Text "FAIL"
}

function Write-Info {
  param([string]$Text)
  Write-Host "        $Text" -ForegroundColor DarkGray
  Write-Log $Text "INFO"
}

function Write-SectionHeader {
  param([string]$Title)
  $line = "-" * 50
  Write-Host ""
  Write-Host "  --- $Title ---" -ForegroundColor Cyan
  Write-Host "  $line" -ForegroundColor DarkCyan
}

# ==============================================================================
# 2. Banner + intro
# ==============================================================================

Write-Banner
Write-Host "  This installer will:" -ForegroundColor Gray
Write-Host "    - Check your DaVinci Resolve installation" -ForegroundColor DarkGray
Write-Host "    - Locate the correct Scripts folder" -ForegroundColor DarkGray
Write-Host "    - Copy all plugin files and macros" -ForegroundColor DarkGray
Write-Host "    - Verify every file was placed correctly" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Install log: $LogFile" -ForegroundColor DarkGray
Write-Host ""

$confirm = Read-Host "  Press ENTER to continue, or type 'q' to quit"
if ($confirm -ieq "q") { Write-Host "  Cancelled." -ForegroundColor Gray; exit 0 }

# ==============================================================================
# 3. Dependency checks
# ==============================================================================

Write-SectionHeader "Checking Dependencies"

# --- 3a. PowerShell version --------------------------------------------------

Write-Step "PowerShell version..."
$psv = $PSVersionTable.PSVersion
if ($psv.Major -lt 5) {
  Write-Fail "PowerShell 5.1+ required. Found: $psv"
  Write-Host "  Please update Windows PowerShell and re-run." -ForegroundColor Red
  exit 1
}
Write-Ok "PowerShell $psv"

# --- 3b. Locate DaVinci Resolve executable -----------------------------------

Write-Step "Locating DaVinci Resolve..."

$resolve_exe     = $null
$resolve_version = $null

# 1) Registry - covers custom install paths
$reg_paths = @(
  "HKLM:\SOFTWARE\Blackmagic Design\DaVinci Resolve",
  "HKLM:\SOFTWARE\WOW6432Node\Blackmagic Design\DaVinci Resolve"
)
foreach ($rp in $reg_paths) {
  try {
    $key = Get-ItemProperty -Path $rp -ErrorAction Stop
    # Try common property names for the install path
    foreach ($prop in @("ExecutablePath","InstallDir","InstallPath","ApplicationPath")) {
      $val = $key.$prop
      if ($val -and (Test-Path $val)) {
        $resolve_exe = $val
        break
      }
    }
    if ($resolve_exe) { break }
    # Fallback: scan all string properties for something ending in Resolve.exe
    $key.PSObject.Properties |
      Where-Object { $_.Value -is [string] -and $_.Value -match "Resolve\.exe$" } |
      Select-Object -First 1 |
      ForEach-Object { $resolve_exe = $_.Value }
    if ($resolve_exe) { break }
  } catch {}
}

# 2) Well-known paths on common drive letters
if (-not $resolve_exe) {
  $candidates = @(
    "$env:ProgramFiles\Blackmagic Design\DaVinci Resolve\Resolve.exe",
    "C:\Program Files\Blackmagic Design\DaVinci Resolve\Resolve.exe",
    "D:\Program Files\Blackmagic Design\DaVinci Resolve\Resolve.exe",
    "E:\Program Files\Blackmagic Design\DaVinci Resolve\Resolve.exe",
    "F:\Program Files\Blackmagic Design\DaVinci Resolve\Resolve.exe"
  )
  # Add ProgramFiles(x86) safely (env var name contains parens)
  $pf86 = [System.Environment]::GetFolderPath("ProgramFilesX86")
  if ($pf86) {
    $candidates += "$pf86\Blackmagic Design\DaVinci Resolve\Resolve.exe"
  }
  foreach ($c in $candidates) {
    if (Test-Path $c) { $resolve_exe = $c; break }
  }
}

# 3) Full drive scan as last resort
if (-not $resolve_exe) {
  Write-Info "Searching all drives for Resolve.exe - this may take a moment..."
  Write-Log "Starting full-drive search for Resolve.exe"
  $drives = [System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.DriveType -eq "Fixed" } |
            Select-Object -ExpandProperty RootDirectory |
            Select-Object -ExpandProperty FullName
  foreach ($drive in $drives) {
    $found = Get-ChildItem -Path $drive -Filter "Resolve.exe" `
             -Recurse -Depth 6 -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { $resolve_exe = $found.FullName; break }
  }
}

if (-not $resolve_exe) {
  Write-Fail "DaVinci Resolve executable not found."
  Write-Host ""
  Write-Host "  DaVinci Resolve Studio 18+ is required." -ForegroundColor Red
  Write-Host "  Download: https://www.blackmagicdesign.com/products/davinciresolve" -ForegroundColor DarkGray
  Write-Log "Resolve.exe not found - aborting" "FAIL"
  Read-Host "  Press ENTER to close"
  exit 1
}

$resolve_version = (Get-Item $resolve_exe).VersionInfo.FileVersion
Write-Ok "Found: $resolve_exe"
Write-Info "Version: $resolve_version"

# --- 3c. Version check -------------------------------------------------------

$ver_major = 0
if ($resolve_version -match "^(\d+)") { $ver_major = [int]$Matches[1] }

if ($ver_major -lt 18) {
  Write-Warn "Version $resolve_version detected. CaptionPro requires Resolve 18+."
  Write-Warn "Some features may not work correctly."
  $cont = Read-Host "  Continue anyway? (y/n)"
  if ($cont -ine "y") { exit 0 }
} else {
  Write-Ok "Version $resolve_version is supported."
}

# --- 3d. Locate Scripts folder -----------------------------------------------

Write-Step "Locating Resolve Scripts folder..."

$scripts_candidates = @(
  "$env:APPDATA\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts",
  "$env:ProgramData\Blackmagic Design\DaVinci Resolve\Fusion\Scripts",
  "$env:APPDATA\Blackmagic Design\Fusion\Scripts"
)

# Derive from exe location for portable or non-standard installs
$resolve_install_dir = Split-Path $resolve_exe -Parent
$scripts_candidates += "$resolve_install_dir\Fusion\Scripts"
$scripts_candidates += (Split-Path $resolve_install_dir -Parent) + "\Fusion\Scripts"

$scripts_root = $null
foreach ($c in $scripts_candidates) {
  if (Test-Path $c) {
    $scripts_root = $c
    Write-Log "Scripts folder found: $c"
    break
  }
}

if (-not $scripts_root) {
  $default = "$env:APPDATA\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts"
  Write-Warn "Scripts folder not found (it may not have been created yet)."
  Write-Host ""
  Write-Host "  Default path: $default" -ForegroundColor DarkGray
  Write-Host ""
  $choice = Read-Host "  [1] Create at default path   [2] Enter custom path   [q] Quit"

  switch ($choice) {
    "1" {
      New-Item -ItemType Directory -Path $default -Force | Out-Null
      $scripts_root = $default
      Write-Ok "Created: $scripts_root"
    }
    "2" {
      $custom = (Read-Host "  Enter full Scripts folder path").Trim().Trim('"')
      if (-not (Test-Path $custom)) {
        New-Item -ItemType Directory -Path $custom -Force | Out-Null
        Write-Ok "Created: $custom"
      }
      $scripts_root = $custom
    }
    default { Write-Host "  Cancelled." -ForegroundColor Gray; exit 0 }
  }
}

Write-Ok "Scripts folder: $scripts_root"

# ==============================================================================
# 4. Confirm install plan
# ==============================================================================

Write-SectionHeader "Install Plan"
Write-Host ""
Write-Host "  Files will be placed at:" -ForegroundColor Gray
Write-Host "    Entry point : $scripts_root\Comp\CaptionPro.lua" -ForegroundColor DarkGray
Write-Host "    Lua modules : $scripts_root\CaptionPro_src\" -ForegroundColor DarkGray
Write-Host "    Macros      : $scripts_root\CaptionPro_macros\" -ForegroundColor DarkGray
Write-Host ""

$go = Read-Host "  Proceed with installation? (y/n)"
if ($go -ine "y") { Write-Host "  Cancelled." -ForegroundColor Gray; exit 0 }

# ==============================================================================
# 5. Copy files
# ==============================================================================

Write-SectionHeader "Installing Files"

$here        = $PSScriptRoot
$entry_src   = Join-Path $here "src\main.lua"
$modules_src = Join-Path $here "src"
$macros_src  = Join-Path $here "macros"

$comp_dir    = Join-Path $scripts_root "Comp"
$entry_dst   = Join-Path $comp_dir "CaptionPro.lua"
$modules_dst = Join-Path $scripts_root "CaptionPro_src"
$macros_dst  = Join-Path $scripts_root "CaptionPro_macros"

$copied = 0
$errors = @()

function Safe-Copy {
  param([string]$Src, [string]$Dst, [string]$Label)
  try {
    $dstDir = Split-Path $Dst -Parent
    if (-not (Test-Path $dstDir)) {
      New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    }
    Copy-Item -Path $Src -Destination $Dst -Force
    Write-Ok $Label
    Write-Log "Copied: $Src -> $Dst"
    $script:copied++
  } catch {
    Write-Fail "FAILED: $Label  ($_)"
    Write-Log "COPY ERROR: $Src -> $Dst  ($_)" "FAIL"
    $script:errors += $Label
  }
}

# Entry point
Write-Step "Entry point..."
Safe-Copy $entry_src $entry_dst "main.lua -> Comp\CaptionPro.lua"

# Lua modules
Write-Step "Lua source modules..."
$lua_files = Get-ChildItem -Path $modules_src -Recurse -Filter "*.lua" |
             Where-Object { $_.Name -ne "main.lua" }

foreach ($file in $lua_files) {
  $rel = $file.FullName.Substring($modules_src.Length).TrimStart('\','/')
  $dst = Join-Path $modules_dst $rel
  Safe-Copy $file.FullName $dst "src\$rel"
}

# Macros
Write-Step "Macro .setting files..."
if (Test-Path $macros_src) {
  foreach ($file in (Get-ChildItem -Path $macros_src -Filter "*.setting")) {
    $dst = Join-Path $macros_dst $file.Name
    Safe-Copy $file.FullName $dst "macros\$($file.Name)"
  }
} else {
  Write-Warn "macros\ folder not found in source - skipping."
}

# ==============================================================================
# 6. Verify
# ==============================================================================

Write-SectionHeader "Verifying Installation"

$verify_ok = $true
$checks = [ordered]@{
  "Entry point (Comp\CaptionPro.lua)" = $entry_dst
  "Module: subtitle_reader"           = Join-Path $modules_dst "resolve\subtitle_reader.lua"
  "Module: fusion_builder"            = Join-Path $modules_dst "resolve\fusion_builder.lua"
  "Module: highlight_analyzer"        = Join-Path $modules_dst "core\highlight_analyzer.lua"
  "Module: workflow"                  = Join-Path $modules_dst "core\workflow.lua"
  "Module: panel (UI)"                = Join-Path $modules_dst "ui\panel.lua"
}

foreach ($name in $checks.Keys) {
  $path = $checks[$name]
  if (Test-Path $path) {
    Write-Ok $name
  } else {
    Write-Fail "$name  [MISSING: $path]"
    $verify_ok = $false
    Write-Log "Verify FAILED: $path" "FAIL"
  }
}

# Bundled macros: verify at least one .setting landed (names are not hardcoded)
$macro_count = 0
if (Test-Path $macros_dst) {
  $macro_count = (Get-ChildItem -Path $macros_dst -Filter "*.setting" -ErrorAction SilentlyContinue |
                  Measure-Object).Count
}
if ($macro_count -gt 0) {
  Write-Ok "Bundled macros ($macro_count .setting file(s))"
} else {
  Write-Fail "Bundled macros  [MISSING: no .setting files in $macros_dst]"
  $verify_ok = $false
  Write-Log "Verify FAILED: no macros in $macros_dst" "FAIL"
}

# ==============================================================================
# 7. Result
# ==============================================================================

Write-Host ""

if ($verify_ok -and $errors.Count -eq 0) {

  Write-Host "  +--------------------------------------------------+" -ForegroundColor Green
  Write-Host "  |     CaptionPro installed successfully!           |" -ForegroundColor Green
  Write-Host "  |   $copied file(s) copied and verified.$((' ' * [Math]::Max(0, 19 - "$copied".Length)))           |" -ForegroundColor Green
  Write-Host "  +--------------------------------------------------+" -ForegroundColor Green
  Write-Host ""
  Write-Host "  Next steps:" -ForegroundColor White
  Write-Host "    1. Open (or restart) DaVinci Resolve Studio" -ForegroundColor Gray
  Write-Host "    2. Open a project that has a subtitle track" -ForegroundColor Gray
  Write-Host "    3. Workspace > Scripts > Comp > CaptionPro" -ForegroundColor Gray
  Write-Host ""
  Write-Host "  Bundled macros are in:" -ForegroundColor White
  Write-Host "    $macros_dst" -ForegroundColor DarkGray
  Write-Host "  Browse to any .setting there in the panel, or use your own." -ForegroundColor DarkGray
  Write-Host ""
  Write-Host "  Install log: $LogFile" -ForegroundColor DarkGray
  Write-Log "Installation completed successfully. $copied file(s) copied."

} else {

  Write-Host "  +--------------------------------------------------+" -ForegroundColor Red
  Write-Host "  |   Installation completed WITH ERRORS.            |" -ForegroundColor Red
  Write-Host "  |   $($errors.Count) step(s) failed - see details above.$((' ' * [Math]::Max(0, 13 - "$($errors.Count)".Length)))    |" -ForegroundColor Red
  Write-Host "  +--------------------------------------------------+" -ForegroundColor Red
  Write-Host ""
  if ($errors.Count -gt 0) {
    Write-Host "  Failed steps:" -ForegroundColor Red
    foreach ($e in $errors) { Write-Host "    - $e" -ForegroundColor DarkRed }
    Write-Host ""
  }
  Write-Host "  Please send the log file to the developer:" -ForegroundColor Yellow
  Write-Host "    $LogFile" -ForegroundColor White
  Write-Host "    Contact: aniket.bhattacharjee@gmail.com" -ForegroundColor DarkGray
  Write-Log "Installation finished with $($errors.Count) error(s)." "WARN"

}

Write-Host ""
Read-Host "  Press ENTER to close"
