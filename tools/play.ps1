# Starts Skyrim through Mod Organizer 2 and SKSE, with the MO2 that setup.bat found. SkyCraft's
# plugin then starts Minecraft by itself (the bundled Prism, or the dev client after setup -Dev).
#
#   play.bat                  start Skyrim (MO2's "SKSE" executable)
#   play.bat -Executable X    another MO2 executable, by its name in MO2's executables list
param([string]$Executable = "SKSE")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$configPath = "$root\.tools\setup.json"

$config = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { $null }
$mo2 = if ($env:SKYCRAFT_MO2) { $env:SKYCRAFT_MO2 } elseif ($config) { $config.mo2 } else { $null }
if (-not $mo2 -or -not (Test-Path "$mo2\ModOrganizer.exe")) {
    Write-Host "No Mod Organizer 2 set up yet: run setup.bat first (or set SKYCRAFT_MO2)." -ForegroundColor Red
    exit 1
}
# moshortcut://<instance>:<executable>; a portable instance has an empty name.
$instance = if ($config -and $config.mo2Instance) { $config.mo2Instance } else { "" }
Write-Host "Starting Skyrim ($Executable) through $mo2\ModOrganizer.exe"
Start-Process "$mo2\ModOrganizer.exe" -ArgumentList "`"moshortcut://${instance}:$Executable`""
