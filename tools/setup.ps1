# One-shot SkyCraft setup on a fresh Windows PC: checks (and installs) the build tools, fetches the
# dependencies, builds both halves and installs SkyCraft into Mod Organizer 2. Run it again any time
# to update: it only redoes what's needed.
#
#   setup.bat                  build a release and install it into MO2 (what players get)
#   setup.bat -Dev             developer setup: MO2 gets the plugin only, and Skyrim starts the dev
#                              Minecraft (fabric\gradlew runClient) instead of the bundled Prism
#   setup.bat -MO2 <folder>    the folder with ModOrganizer.exe (remembered for next time)
#   setup.bat -NoMO2           build only; the release lands in dist\ (for Vortex or manual install)
#   setup.bat -NoInstall       never install missing tools with winget, just say what's missing
param([switch]$Dev, [string]$MO2 = "", [switch]$NoMO2, [switch]$NoInstall)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$root = Split-Path -Parent $PSScriptRoot
$tools = "$root\.tools"
$configPath = "$tools\setup.json"
New-Item -ItemType Directory $tools -Force | Out-Null

function Step([string]$text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "    $text" -ForegroundColor Green }
function Note([string]$text) { Write-Host "    $text" -ForegroundColor Yellow }
function Fail([string]$text) { Write-Host ""; Write-Host "SkyCraft setup stopped: $text" -ForegroundColor Red; exit 1 }
function Run([string]$what) {
    # Runs a native command line passed as a script block string; stops on a non-zero exit code.
    & ([scriptblock]::Create($what))
    if ($LASTEXITCODE) { Fail "'$what' failed (exit code $LASTEXITCODE)" }
}

function Read-Config {
    if (Test-Path $configPath) { return Get-Content $configPath -Raw | ConvertFrom-Json }
    return [pscustomobject]@{}
}
# UTF-8 without a BOM (Windows PowerShell's Set-Content -Encoding UTF8 writes one).
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text) }
function Save-Config($config) { Write-Text $configPath ($config | ConvertTo-Json) }
$config = Read-Config

# Picks up tools winget just installed, without opening a new terminal.
function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Install-WithWinget([string]$name, [string]$id) {
    if ($NoInstall) { Fail "$name is missing. Install it, then run setup again." }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail "$name is missing, and winget (to install it) isn't available. Install $name, then run setup again."
    }
    Note "$name is missing; installing it with winget ($id)..."
    winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE) { Fail "winget couldn't install $name. Install it yourself, then run setup again." }
    Update-Path
}

# --- Build tools -------------------------------------------------------------------------------

Step "Checking build tools"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Install-WithWinget "Git" "Git.Git" }
Ok "Git: $((git --version) -replace 'git version ', '')"

if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { Install-WithWinget "CMake" "Kitware.CMake" }
$cmakeVersion = [version](((cmake --version)[0] -split ' ')[2] -replace '[^0-9.].*$', '')
if ($cmakeVersion -lt [version]"3.25") { Fail "CMake $cmakeVersion is too old (3.25 or newer needed)." }
Ok "CMake: $cmakeVersion"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = $null
if (Test-Path $vswhere) {
    $vs = & $vswhere -version "[18.0,19.0)" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
}
if (-not $vs) {
    Fail ("Visual Studio 2026 with C++ isn't installed. Get it (Community or Build Tools) from`n" +
        "    https://visualstudio.microsoft.com/downloads/`n" +
        "    and tick the 'Desktop development with C++' workload, then run setup again.")
}
Ok "Visual Studio 2026 (C++): $vs"

function Get-JavaMajor([string]$java) {
    if (-not $java -or -not (Test-Path $java)) { return 0 }
    # java -version writes to stderr, which Windows PowerShell turns into errors under "Stop".
    $ErrorActionPreference = "Continue"
    $line = (& $java -version 2>&1 | Select-Object -First 1) -as [string]
    if ($line -match 'version "(\d+)') { return [int]$Matches[1] }
    return 0
}
function Find-Jdk25 {
    $candidates = @()
    if ($env:JAVA_HOME) { $candidates += $env:JAVA_HOME }
    $onPath = Get-Command javac -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += Split-Path (Split-Path $onPath.Source) }
    foreach ($dir in @("$env:ProgramFiles\Eclipse Adoptium", "$env:ProgramFiles\Java", "$env:ProgramFiles\Microsoft")) {
        if (Test-Path $dir) { $candidates += (Get-ChildItem $dir -Directory -Filter "*25*" | ForEach-Object FullName) }
    }
    foreach ($jdkHome in $candidates) {
        if ((Test-Path "$jdkHome\bin\javac.exe") -and (Get-JavaMajor "$jdkHome\bin\java.exe") -ge 25) { return $jdkHome }
    }
    return $null
}
$jdk = Find-Jdk25
if (-not $jdk) {
    Install-WithWinget "JDK 25" "EclipseAdoptium.Temurin.25.JDK"
    $jdk = Find-Jdk25
    if (-not $jdk) { Fail "JDK 25 still isn't found. Set JAVA_HOME to a JDK 25, then run setup again." }
}
$env:JAVA_HOME = $jdk
Ok "JDK 25: $jdk"

# --- Sources and dependencies ------------------------------------------------------------------

Step "Fetching sources and dependencies"

Push-Location $root
try { Run "git submodule update --init --recursive" } finally { Pop-Location }
Ok "CommonLibSSE-NG submodule ready"

$vcpkg = "$tools\vcpkg"
if (-not (Test-Path "$vcpkg\.git")) { Run "git clone https://github.com/microsoft/vcpkg `"$vcpkg`"" }
if (-not (Test-Path "$vcpkg\vcpkg.exe")) { Run "& `"$vcpkg\bootstrap-vcpkg.bat`" -disableMetrics" }
Ok "vcpkg ready (the C++ libraries download on the first build, which takes a while)"

# --- Mod Organizer 2 ---------------------------------------------------------------------------

# Reads one key from an MO2 ini (Qt format: @ByteArray(...) values, doubled backslashes).
function Get-IniValue([string]$path, [string]$key) {
    if (-not (Test-Path $path)) { return $null }
    foreach ($line in Get-Content $path) {
        if ($line -match "^\s*$([regex]::Escape($key))\s*=\s*(.*)$") {
            $value = $Matches[1].Trim()
            if ($value -match '^@ByteArray\((.*)\)$') { $value = $Matches[1] }
            return $value.Replace('\\', '\').Replace('/', '\')
        }
    }
    return $null
}

$mo2Dir = $null
$modDir = $null
$profileDir = $null
if (-not $NoMO2) {
    Step "Finding Mod Organizer 2"
    $candidates = @($MO2, $env:SKYCRAFT_MO2, $config.mo2,
        "$env:ProgramFiles\Mod Organizer 2", "${env:ProgramFiles(x86)}\Mod Organizer 2",
        "C:\Modding\MO2", "C:\MO2", "$env:USERPROFILE\MO2", "$env:LOCALAPPDATA\Programs\Mod Organizer 2")
    foreach ($c in $candidates) {
        if ($c -and (Test-Path "$c\ModOrganizer.exe")) { $mo2Dir = (Resolve-Path $c).Path; break }
    }
    while (-not $mo2Dir) {
        $answer = Read-Host "    Folder with ModOrganizer.exe (leave empty to skip MO2 and only build)"
        if (-not $answer) { $NoMO2 = $true; break }
        $answer = $answer.Trim('"')
        if (Test-Path "$answer\ModOrganizer.exe") { $mo2Dir = (Resolve-Path $answer).Path }
        else { Note "No ModOrganizer.exe in $answer" }
    }
}
if ($mo2Dir) {
    # A portable instance lives next to ModOrganizer.exe; otherwise it's a global instance in
    # %LOCALAPPDATA%\ModOrganizer: MO2's current one if it's Skyrim SE, else the first Skyrim SE one.
    $instanceName = ""
    $instance = $null
    if (Test-Path "$mo2Dir\portable.txt") {
        $instance = $mo2Dir
    } else {
        $globalDir = "$env:LOCALAPPDATA\ModOrganizer"
        $current = (Get-ItemProperty "HKCU:\Software\Mod Organizer Team\Mod Organizer" -Name CurrentInstance -ErrorAction SilentlyContinue).CurrentInstance
        $names = @($current) + @(Get-ChildItem $globalDir -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
        foreach ($name in $names) {
            if ($name -and (Get-IniValue "$globalDir\$name\ModOrganizer.ini" "gameName") -eq "Skyrim Special Edition") {
                $instanceName = $name; $instance = "$globalDir\$name"; break
            }
        }
    }
    $instanceIni = "$instance\ModOrganizer.ini"
    if (-not $instance -or -not (Test-Path $instanceIni)) {
        Fail "MO2 has no Skyrim Special Edition instance yet. Start MO2 once and create one, then run setup again."
    }
    $base = Get-IniValue $instanceIni "base_directory"
    if (-not $base) { $base = $instance }
    $modDir = Get-IniValue $instanceIni "mod_directory"
    if (-not $modDir) { $modDir = "$base\mods" }
    $modDir = $modDir.Replace("%BASE_DIR%", $base)
    $profiles = Get-IniValue $instanceIni "profiles_directory"
    if (-not $profiles) { $profiles = "$base\profiles" }
    $profiles = $profiles.Replace("%BASE_DIR%", $base)
    $profileName = Get-IniValue $instanceIni "selected_profile"
    if (-not $profileName) { $profileName = "Default" }
    $profileDir = "$profiles\$profileName"
    $config | Add-Member -NotePropertyName mo2 -NotePropertyValue $mo2Dir -Force
    $config | Add-Member -NotePropertyName mo2Instance -NotePropertyValue $instanceName -Force
    Save-Config $config
    Ok "MO2: $mo2Dir"
    Ok "Mods folder: $modDir (profile '$profileName')"

    # What SkyCraft needs in Skyrim. Only warnings: they can be installed after setup.
    $game = Get-IniValue $instanceIni "gamePath"
    if ($game -and -not (Test-Path "$game\skse64_loader.exe")) {
        Note "SKSE64 isn't installed in $game yet: https://skse.silverlock.org/"
    }
    $addressLib = @(Get-ChildItem "$modDir\*\SKSE\Plugins\versionlib-1-*.bin" -ErrorAction SilentlyContinue)
    if ($game) { $addressLib += @(Get-ChildItem "$game\Data\SKSE\Plugins\versionlib-1-*.bin" -ErrorAction SilentlyContinue) }
    if (-not $addressLib) {
        Note "Address Library for SKSE Plugins (All in one, AE) isn't installed yet: https://www.nexusmods.com/skyrimspecialedition/mods/32444"
    }
}
$skyMod = if ($modDir) { "$modDir\SkyCraft" } else { $null }

# The dev preset (CMakeUserPresets.json, not committed) copies each plugin build into MO2.
$userPresets = [ordered]@{
    version = 6
    configurePresets = @([ordered]@{
        name = "dev"; inherits = "default"
        cacheVariables = [ordered]@{ SKYCRAFT_DEPLOY_DIR = $(if ($skyMod) { $skyMod.Replace('\', '/') } else { "" }) }
    })
    buildPresets = @([ordered]@{ name = "dev"; configurePreset = "dev"; configuration = "RelWithDebInfo" })
}
Write-Text "$root\skse\CMakeUserPresets.json" ($userPresets | ConvertTo-Json -Depth 5)

# --- Build and install -------------------------------------------------------------------------

if ($skyMod) { New-Item -ItemType Directory "$skyMod\SKSE\Plugins" -Force | Out-Null }
# MO2 rewrites its mod list when it closes, which would undo enabling SkyCraft below.
while ($skyMod -and (Get-Process ModOrganizer -ErrorAction SilentlyContinue)) {
    Read-Host "    Mod Organizer is running. Close it, then press Enter" | Out-Null
}

$version = (Select-String -Path "$root\fabric\gradle.properties" -Pattern '^version=(.+)$').Matches[0].Groups[1].Value.Trim()

if ($Dev) {
    Step "Building the SKSE plugin (the first build also builds the C++ libraries: 10-30 min)"
    Push-Location "$root\skse"
    try { Run "cmake --preset dev"; Run "cmake --build --preset dev" } finally { Pop-Location }
    Ok "skse\build\RelWithDebInfo\SkyCraft.dll"

    Step "Building the Fabric mod"
    Push-Location "$root\fabric"
    try { Run ".\gradlew.bat build" } finally { Pop-Location }
    Ok "fabric\build\libs\skycraft-$version.jar"

    if ($skyMod) {
        Step "Installing the dev build into MO2"
        # The build already copied the DLL (SKYCRAFT_DEPLOY_DIR); this also covers a no-op rebuild.
        Copy-Item "$root\skse\build\RelWithDebInfo\SkyCraft.dll", "$root\skse\build\RelWithDebInfo\SkyCraft.pdb" "$skyMod\SKSE\Plugins\" -Force
        # No bundle zip in dev: Skyrim starts the dev Minecraft through tools\launch_minecraft.bat.
        Remove-Item "$skyMod\SKSE\Plugins\SkyCraft\SkyCraft-Minecraft.zip" -ErrorAction SilentlyContinue
        $ini = (Get-Content "$root\skse\SkyCraft.ini" -Raw) `
            -replace '(?m)^sLauncher =[^\r\n]*', "sLauncher = $root\tools\launch_minecraft.bat" `
            -replace '(?m)^sArguments =[^\r\n]*', 'sArguments ='
        Write-Text "$skyMod\SKSE\Plugins\SkyCraft.ini" $ini
        Ok "$skyMod (Skyrim starts the dev Minecraft: fabric\gradlew runClient)"
    }
} else {
    Step "Building and packaging the release (the first build also builds the C++ libraries: 10-30 min)"
    Run "& `"$root\tools\package.ps1`""
    $zip = "$root\dist\SkyCraft-$version.zip"

    if ($skyMod) {
        Step "Installing the release into MO2"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            foreach ($entry in $archive.Entries) {
                $target = Join-Path $skyMod ($entry.FullName.Replace('/', '\'))
                # Keep the player's own SkyCraft.ini (a dev setup's points at the dev launcher: reset it).
                if ($entry.Name -eq "SkyCraft.ini" -and (Test-Path $target) -and -not (Select-String -Path $target -Pattern 'launch_minecraft\.bat' -Quiet)) { continue }
                New-Item -ItemType Directory (Split-Path $target) -Force | Out-Null
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        } finally { $archive.Dispose() }
        Ok "$skyMod"
    } else {
        Ok "Install $zip with Vortex or MO2."
    }
}

# Turn the mod on in the selected MO2 profile (top of modlist.txt = highest priority).
if ($profileDir -and (Test-Path "$profileDir\modlist.txt")) {
    $modlist = @(Get-Content "$profileDir\modlist.txt")
    if ($modlist -notcontains "+SkyCraft") {
        $modlist = @($modlist | Where-Object { $_ -ne "-SkyCraft" })
        $header = @($modlist | Where-Object { $_ -like "#*" })
        $rest = @($modlist | Where-Object { $_ -notlike "#*" })
        Set-Content "$profileDir\modlist.txt" ($header + "+SkyCraft" + $rest)
        Ok "Enabled SkyCraft in the MO2 profile"
    }
}

# --- Done --------------------------------------------------------------------------------------

Step "Done"
Write-Host @"
    Still needed in Skyrim (once): SKSE64, Address Library for SKSE Plugins (All in one, AE), and
    heavily recommended, Alternate Start - Live Another Life. See README.md > Requirements.

    Play: play.bat (starts Skyrim through MO2 + SKSE).
"@
if (-not $Dev) {
    Write-Host "    The first time, sign in with your Microsoft account in the Prism Launcher window (Alt-Tab)."
} else {
    Write-Host "    Rebuild the plugin: cd skse; cmake --build --preset dev   (copies into MO2 by itself)"
    Write-Host "    Rebuild the mod:    the dev Minecraft runs from fabric\ sources, just restart it."
}
