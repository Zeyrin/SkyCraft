# Installateur SkyCraft pour joueurs : un assistant en 4 écrans qui installe tout dans le Skyrim de
# Steam (sans gestionnaire de mods) et explique chaque clic.
#   1. Bienvenue : trouve Skyrim, dit ce qu'il faut.
#   2. Les mods : SKSE64, Address Library et Alternate Start viennent de Nexus Mods. La page s'ouvre,
#      le joueur clique « Manual download », l'installateur prend le fichier dans Téléchargements et
#      passe tout seul au suivant.
#   3. Compte Minecraft : installe SkyCraft, prépare son Minecraft (comme le plugin le ferait au
#      premier lancement) et ouvre Prism pour la connexion Microsoft, détectée toute seule.
#   4. Prêt : raccourci sur le Bureau, rappel des touches, bouton Jouer.
# Distribué en un seul fichier, « Installer SkyCraft.exe » (installer\Launcher.cs, fait par
# tools\package.ps1) : il dépose ce script et SkyCraft-<version>.zip dans %LOCALAPPDATA%\SkyCraft\installer
# et le lance avec -Launcher <lui-même>. Le raccourci du Bureau pointe vers cet exe (--play), qui
# vérifie avant chaque partie que SKSE et Address Library suivent la version de Skyrim.
# Sans exe (lancé depuis le dépôt) : SkyCraft vient de la dernière release GitHub.
param([string]$Game = "", [int]$Page = 1, [string]$Launcher = "", [int]$NewGame = -1)

# ===== À régler ==================================================================================
# Lien du tuto (vidéo, doc...). Vide : le bouton « Tuto vidéo » dit que le tuto arrive bientôt.
$TutorialUrl = ""
# Dépôt GitHub dont on prend la dernière release si aucun SkyCraft-<version>.zip n'est à côté.
$GitHubRepo = "Zeyrin/SkyCraft"
# La version de Skyrim la plus récente sur laquelle SkyCraft a été testé. Au-delà, l'installateur
# prévient que Skyrim vient d'être mis à jour (SKSE peut ne pas suivre tout de suite).
$LatestTested = [version]"1.7.104"
# =================================================================================================

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.IO.Compression.FileSystem
[Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here = $PSScriptRoot
$work = Join-Path $env:TEMP "SkyCraft-Installer"
$mcDir = Join-Path $env:LOCALAPPDATA "SkyCraft"
New-Item -ItemType Directory $work -Force | Out-Null

$App = @{ Game = $null; Version = $null; Page = 0; Busy = $false; Mod = $null; Mc = "install"; Download = $null; Unpack = $null; Prism = $null }

function Show-Error([string]$text) {
    [Windows.Forms.MessageBox]::Show($text, "SkyCraft", "OK", "Error") | Out-Null
}

# --- Skyrim -----------------------------------------------------------------------------------

function Find-Skyrim {
    $dirs = @()
    $bethesda = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Bethesda Softworks\Skyrim Special Edition" -ErrorAction SilentlyContinue
    if ($bethesda -and $bethesda."installed path") { $dirs += $bethesda."installed path" }
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $libs = @($steam.Replace('/', '\'))
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $m.Groups[1].Value.Replace('\\', '\') }
        }
        foreach ($lib in $libs) { $dirs += Join-Path $lib "steamapps\common\Skyrim Special Edition" }
    }
    foreach ($d in $dirs) {
        if ($d -and (Test-Path (Join-Path $d "SkyrimSE.exe"))) { return (Resolve-Path $d).Path.TrimEnd('\') }
    }
    return $null
}

function Get-GameVersion([string]$dir) {
    $v = (Get-Item (Join-Path $dir "SkyrimSE.exe")).VersionInfo
    return [version]("{0}.{1}.{2}" -f $v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart)
}

function Test-Writable([string]$dir) {
    try {
        $f = Join-Path $dir ".skycraft-write-test"
        [IO.File]::WriteAllText($f, "")
        Remove-Item $f
        return $true
    } catch { return $false }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Steam installe parfois Skyrim dans un dossier protégé : il faut alors les droits administrateur.
function Restart-Elevated([string]$dir, [int]$page) {
    $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-WindowStyle", "Hidden",
        "-File", "`"$PSCommandPath`"", "-Game", "`"$dir`"", "-Page", $page, "-NewGame", [int]$newGameBox.Checked)
    if ($Launcher) { $psArgs += @("-Launcher", "`"$Launcher`"") }
    Start-Process powershell -Verb RunAs -ArgumentList $psArgs
    [Environment]::Exit(0)
}

function VersionTag([string]$sep) { "{1}{0}{2}{0}{3}" -f $sep, $App.Version.Major, $App.Version.Minor, $App.Version.Build }
function SkseDll { Join-Path $App.Game ("skse64_{0}.dll" -f (VersionTag "_")) }
function AddressLibBin { Join-Path $App.Game ("Data\SKSE\Plugins\versionlib-{0}-0.bin" -f (VersionTag "-")) }

# --- Fichiers ---------------------------------------------------------------------------------

function Get-DownloadsDir {
    try {
        $p = (New-Object -ComObject Shell.Application).NameSpace("shell:Downloads").Self.Path
        if ($p -and (Test-Path $p)) { return $p }
    } catch {}
    return Join-Path $env:USERPROFILE "Downloads"
}

# Le dernier fichier de ce mod Nexus dans Téléchargements. Les noms Nexus contiennent l'id du mod
# (« Nom-30379-2-3-1-1755000000.7z »). Firefox crée le fichier vide et écrit dans un .part à côté.
function Find-NexusDownload([int]$id, [string[]]$bad) {
    Get-ChildItem (Get-DownloadsDir) -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "-$id-" -and $_.Extension -match '^\.(7z|zip)$' -and $_.Length -gt 0 -and
            -not (Test-Path "$($_.FullName).part") -and $bad -notcontains $_.FullName } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Expand-Any([string]$archive, [string]$dest) {
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory $dest -Force | Out-Null
    $fs = [IO.File]::OpenRead($archive)
    $b = New-Object byte[] 2
    [void]$fs.Read($b, 0, 2)
    $fs.Dispose()
    if ($b[0] -eq 0x50 -and $b[1] -eq 0x4B) {
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $dest)
    } elseif ($b[0] -eq 0x37 -and $b[1] -eq 0x7A) {
        # Les .7z : 7zr.exe, la version autonome officielle de 7-Zip (600 Ko).
        $sevenZip = Join-Path $work "7zr.exe"
        if (-not (Test-Path $sevenZip)) { (New-Object Net.WebClient).DownloadFile("https://www.7-zip.org/a/7zr.exe", $sevenZip) }
        $p = Start-Process $sevenZip -ArgumentList @("x", "-y", "-o`"$dest`"", "`"$archive`"") -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode) { throw "7-Zip n'a pas pu extraire $([IO.Path]::GetFileName($archive))." }
    } else {
        throw "$([IO.Path]::GetFileName($archive)) n'est ni un .zip ni un .7z."
    }
}

# Copie un dossier dans un autre en fusionnant (robocopy : codes de sortie 0-7 = réussi).
function Copy-Merge([string]$from, [string]$to, [string[]]$excludeDirs = @()) {
    $rcArgs = @("`"$from`"", "`"$to`"", "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP")
    if ($excludeDirs) { $rcArgs += "/XD"; $rcArgs += $excludeDirs }
    $p = Start-Process robocopy -ArgumentList $rcArgs -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ge 8) { throw "La copie vers $to a échoué (robocopy $($p.ExitCode))." }
}

function Enable-Plugin([string]$name) {
    $dir = Join-Path $env:LOCALAPPDATA "Skyrim Special Edition"
    New-Item -ItemType Directory $dir -Force | Out-Null
    $file = Join-Path $dir "Plugins.txt"
    $lines = @()
    if (Test-Path $file) { $lines = @(Get-Content $file | Where-Object { $_.TrimStart('*') -ne $name }) }
    Set-Content $file ($lines + "*$name") -Encoding ASCII
}

# --- Les 3 mods Nexus ---------------------------------------------------------------------------

function Install-Skse([string]$archive) {
    $tmp = Join-Path $work "skse"
    Expand-Any $archive $tmp
    $loader = Get-ChildItem $tmp -Recurse -Filter "skse64_loader.exe" | Select-Object -First 1
    if (-not $loader) { throw "ce fichier n'est pas SKSE64." }
    if (-not (Test-Path (Join-Path $loader.DirectoryName ([IO.Path]::GetFileName((SkseDll)))))) {
        throw ("ce SKSE n'est pas pour ton Skyrim ($($App.Version)). Prends le fichier « Anniversary Edition » le plus récent. " +
            "S'il n'existe pas encore pour cette version (Skyrim vient d'être mis à jour), réessaie dans quelques jours.")
    }
    Copy-Merge $loader.DirectoryName $App.Game @("src")
}

function Install-AddressLib([string]$archive) {
    $tmp = Join-Path $work "addrlib"
    Expand-Any $archive $tmp
    if (-not (Get-ChildItem $tmp -Recurse -Filter ([IO.Path]::GetFileName((AddressLibBin))))) {
        throw ("ce n'est pas le bon fichier. Prends « All in one (Anniversary Edition) ». " +
            "Si c'est déjà lui, il n'est pas encore à jour pour ton Skyrim ($($App.Version)) : réessaie dans quelques jours.")
    }
    $plugins = Join-Path $App.Game "Data\SKSE\Plugins"
    New-Item -ItemType Directory $plugins -Force | Out-Null
    Get-ChildItem $tmp -Recurse -Filter "versionlib-*.bin" | Copy-Item -Destination $plugins -Force
}

function Install-AltStart([string]$archive) {
    $tmp = Join-Path $work "altstart"
    Expand-Any $archive $tmp
    $esp = Get-ChildItem $tmp -Recurse -Filter "AlternateStart.esp" | Select-Object -First 1
    if (-not $esp) { throw "ce fichier n'est pas Alternate Start." }
    Copy-Merge $esp.DirectoryName (Join-Path $App.Game "Data") @("fomod")
    Enable-Plugin "AlternateStart.esp"
}

$mods = @(
    @{ Key = "skse"; Name = "SKSE64"; Nexus = 30379; File = "le fichier « Anniversary Edition » le plus récent (Main files)"
        Installed = { (Test-Path (Join-Path $App.Game "skse64_loader.exe")) -and (Test-Path (SkseDll)) }; Install = { param($f) Install-Skse $f } },
    @{ Key = "addrlib"; Name = "Address Library"; Nexus = 32444; File = "« All in one (Anniversary Edition) »"
        Installed = { Test-Path (AddressLibBin) }; Install = { param($f) Install-AddressLib $f } },
    @{ Key = "altstart"; Name = "Alternate Start"; Nexus = 272; File = "« Alternate Start - Live Another Life » (Main files)"
        Installed = { Test-Path (Join-Path $App.Game "Data\AlternateStart.esp") }; Install = { param($f) Install-AltStart $f } }
)
foreach ($m in $mods) { $m.State = "todo"; $m.Bad = @(); $m.Picked = $null; $m.Opened = $false; $m.Error = "" }
function Get-Mod([string]$key) { $mods | Where-Object { $_.Key -eq $key } | Select-Object -First 1 }
function Open-NexusPage($m) { Start-Process "https://www.nexusmods.com/skyrimspecialedition/mods/$($m.Nexus)?tab=files"; $m.Opened = $true }

# --- SkyCraft et son Minecraft ------------------------------------------------------------------

function Find-LocalSkyCraftZip {
    Get-ChildItem $here -Filter "SkyCraft-*.zip" -File | Where-Object { $_.Name -match '^SkyCraft-[\d.]+\.zip$' } |
        Sort-Object Name -Descending | Select-Object -First 1
}

function Install-SkyCraft([string]$zip) {
    $data = Join-Path $App.Game "Data"
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($entry in $archive.Entries) {
            if (-not $entry.Name) { continue }
            $target = Join-Path $data ($entry.FullName.Replace('/', '\'))
            if ($entry.Name -eq "SkyCraft.ini" -and (Test-Path $target)) { continue }  # garde les réglages du joueur
            New-Item -ItemType Directory (Split-Path $target) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $archive.Dispose() }
}

# Dépaquette le Minecraft de SkyCraft dans %LOCALAPPDATA%\SkyCraft exactement comme le plugin
# (Launcher.cpp, EnsureBundle) : même dossier, même bundle.stamp (taille + date du zip en FILETIME),
# donc le plugin ne le refait pas. S'ils différaient, il le referait en gardant le compte connecté.
function Get-BundleStamp {
    $bundle = Join-Path $App.Game "Data\SKSE\Plugins\SkyCraft\SkyCraft-Minecraft.zip"
    "{0} {1}" -f (Get-Item $bundle).Length, [IO.File]::GetLastWriteTimeUtc($bundle).ToFileTimeUtc()
}
function Start-Unpack {
    $stampFile = Join-Path $mcDir "bundle.stamp"
    if ((Test-Path $stampFile) -and (Test-Path "$mcDir\Prism\prismlauncher.exe") -and (Get-Content $stampFile -Raw).Trim() -eq (Get-BundleStamp)) { return $null }
    New-Item -ItemType Directory $mcDir -Force | Out-Null
    Get-ChildItem "$mcDir\Prism\instances\SkyCraft\.minecraft\mods" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(skycraft-|fabric-api-|e4mc-)' } | Remove-Item -Force
    Copy-Item (Join-Path $App.Game "Data\SKSE\Plugins\SkyCraft\SkyCraft-Minecraft.zip") "$mcDir\bundle.zip" -Force
    return Start-Process "$env:SystemRoot\System32\tar.exe" -ArgumentList @("-xf", "`"$mcDir\bundle.zip`"", "-C", "`"$mcDir`"") -PassThru -WindowStyle Hidden
}
function Complete-Unpack {
    Remove-Item "$mcDir\bundle.zip" -ErrorAction SilentlyContinue
    if (-not (Test-Path "$mcDir\Prism\prismlauncher.exe")) { throw "le Minecraft de SkyCraft n'a pas pu être dépaqueté." }
    if (-not (Test-Path "$mcDir\Prism\prismlauncher.cfg")) { Copy-Item "$mcDir\defaults\prismlauncher.cfg" "$mcDir\Prism\prismlauncher.cfg" }
    [IO.File]::WriteAllText("$mcDir\bundle.stamp", (Get-BundleStamp))
}

function Test-MinecraftAccount {
    $f = "$mcDir\Prism\accounts.json"
    if (-not (Test-Path $f)) { return $false }
    try { return @((Get-Content $f -Raw | ConvertFrom-Json).accounts).Count -gt 0 } catch { return $false }
}

# Le raccourci passe par l'exe de l'installateur (--play) quand il y en a un : il vérifie les
# versions avant de lancer skse64_loader.exe, et explique quoi faire après une mise à jour de Skyrim.
function New-Shortcut {
    New-Item -ItemType Directory $mcDir -Force | Out-Null
    [IO.File]::WriteAllText("$mcDir\game.txt", $App.Game)
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "SkyCraft.lnk"))
    if ($Launcher -and (Test-Path $Launcher)) {
        $lnk.TargetPath = $Launcher
        $lnk.Arguments = "--play"
    } else {
        $lnk.TargetPath = Join-Path $App.Game "skse64_loader.exe"
    }
    $lnk.WorkingDirectory = $App.Game
    $lnk.IconLocation = (Join-Path $App.Game "SkyrimSE.exe") + ",0"
    $lnk.Description = "Skyrim avec SkyCraft"
    $lnk.Save()
}

# --- Fenêtre ----------------------------------------------------------------------------------

$green = [Drawing.Color]::FromArgb(60, 133, 39)
$dark = [Drawing.Color]::FromArgb(31, 35, 41)
$gray = [Drawing.Color]::FromArgb(100, 106, 115)
$light = [Drawing.Color]::FromArgb(243, 244, 246)
$red = [Drawing.Color]::Firebrick
$fontText = New-Object Drawing.Font("Segoe UI", 10)
$fontSmall = New-Object Drawing.Font("Segoe UI", 9)
$fontBold = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$fontTitle = New-Object Drawing.Font("Segoe UI", 15, [Drawing.FontStyle]::Bold)
$fontBig = New-Object Drawing.Font("Segoe UI", 12)
$fontSymbol = New-Object Drawing.Font("Segoe UI Symbol", 13)
$check = [string][char]0x2714; $cross = [string][char]0x2716; $dot = [string][char]0x25CF; $circle = [string][char]0x25CB

$form = New-Object Windows.Forms.Form
$form.Text = "Installer SkyCraft"
$form.ClientSize = New-Object Drawing.Size(720, 560)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.BackColor = [Drawing.Color]::White
$form.Font = $fontText

function New-Label($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, $font = $fontText, $color = $dark) {
    $l = New-Object Windows.Forms.Label
    $l.SetBounds($x, $y, $w, $h)
    $l.Text = $text
    $l.Font = $font
    $l.ForeColor = $color
    $l.BackColor = [Drawing.Color]::Transparent
    $parent.Controls.Add($l)
    return $l
}
function New-Link($parent, [int]$x, [int]$y, [int]$w, [string]$text, [scriptblock]$onClick) {
    $l = New-Object Windows.Forms.LinkLabel
    $l.SetBounds($x, $y, $w, 22)
    $l.Text = $text
    $l.Font = $fontSmall
    $l.LinkColor = $green
    $l.BackColor = [Drawing.Color]::Transparent
    $l.add_LinkClicked($onClick)
    $parent.Controls.Add($l)
    return $l
}
function New-Button($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, [bool]$primary) {
    $b = New-Object Windows.Forms.Button
    $b.SetBounds($x, $y, $w, $h)
    $b.Text = $text
    $b.FlatStyle = "Flat"
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    if ($primary) {
        $b.BackColor = $green; $b.ForeColor = [Drawing.Color]::White; $b.Font = $fontBold
        $b.FlatAppearance.BorderSize = 0
    } else {
        $b.BackColor = [Drawing.Color]::White; $b.ForeColor = $dark; $b.Font = $fontText
        $b.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(200, 204, 210)
    }
    $parent.Controls.Add($b)
    return $b
}
function New-Box($parent, [int]$x, [int]$y, [int]$w, [int]$h, $color) {
    $p = New-Object Windows.Forms.Panel
    $p.SetBounds($x, $y, $w, $h)
    $p.BackColor = $color
    $parent.Controls.Add($p)
    return $p
}

# En-tête : titre, étape, tuto. Pied : bouton secondaire à gauche, bouton principal à droite.
$header = New-Box $form 0 0 720 78 $dark
New-Label $header 24 12 400 32 "SkyCraft" (New-Object Drawing.Font("Segoe UI", 17, [Drawing.FontStyle]::Bold)) ([Drawing.Color]::White) | Out-Null
$stepLabel = New-Label $header 26 46 420 22 "" $fontSmall ([Drawing.Color]::FromArgb(180, 186, 194))
$tutoButton = New-Button $header 556 20 140 38 ([string][char]0x25B6 + "  Tuto vidéo") $false
$tutoButton.add_Click({
    if ($TutorialUrl) { Start-Process $TutorialUrl }
    else { [Windows.Forms.MessageBox]::Show("Le tuto vidéo arrive bientôt !", "SkyCraft", "OK", "Information") | Out-Null }
})

$footer = New-Box $form 0 480 720 80 $light
$primary = New-Button $footer 476 18 220 44 "" $true
$secondary = New-Button $footer 24 18 160 44 "" $false
$primary.add_Click({ if ($App.OnPrimary) { & $App.OnPrimary } })
$secondary.add_Click({ if ($App.OnSecondary) { & $App.OnSecondary } })

$pages = @{}
foreach ($n in 1..4) { $pages[$n] = New-Box $form 0 78 720 402 ([Drawing.Color]::White); $pages[$n].Visible = $false }
$pageNames = @{ 1 = "Bienvenue"; 2 = "Les mods"; 3 = "Ton compte Minecraft"; 4 = "C'est prêt" }

function Set-Footer([string]$primaryText, [scriptblock]$onPrimary, [string]$secondaryText, [scriptblock]$onSecondary) {
    $primary.Text = $primaryText; $primary.Visible = [bool]$primaryText; $primary.Enabled = $true
    $App.OnPrimary = $onPrimary
    $secondary.Text = $secondaryText; $secondary.Visible = [bool]$secondaryText
    $App.OnSecondary = $onSecondary
}

# --- Écran 1 : Bienvenue ----------------------------------------------------------------------

$p1 = $pages[1]
New-Label $p1 32 22 660 32 "Salut ! On installe SkyCraft." $fontTitle | Out-Null
New-Label $p1 32 60 660 24 "Environ 5 minutes. Tu n'as que 3 choses à faire, je t'explique chaque clic :" $fontText $gray | Out-Null
$lines = @("Télécharger 2 petits mods sur Nexus Mods", "Te connecter à ton compte Minecraft", "Jouer !")
$lineLabels = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    $y = 92 + 36 * $i
    $badge = New-Label $p1 34 $y 30 30 ([string]($i + 1)) $fontBold ([Drawing.Color]::White)
    $badge.BackColor = $green; $badge.TextAlign = "MiddleCenter"
    $lineLabels += New-Label $p1 76 ($y + 3) 600 26 $lines[$i] $fontBig
}

# Alternate Start : seulement pour une nouvelle partie (l'intro de Helgen peut bloquer SkyCraft).
# Coché d'office si le joueur n'a encore aucune sauvegarde.
$newGameBox = New-Object Windows.Forms.CheckBox
$newGameBox.SetBounds(34, 200, 650, 24)
$newGameBox.Font = $fontText
$newGameBox.Text = "Je commence une nouvelle partie (ajoute Alternate Start, pour sauter l'intro de Helgen)"
$saves = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "My Games\Skyrim Special Edition\Saves"
$newGameBox.Checked = if ($NewGame -ge 0) { [bool]$NewGame } else { -not (Get-ChildItem $saves -Filter "*.ess" -ErrorAction SilentlyContinue | Select-Object -First 1) }
$newGameBox.add_CheckedChanged({ Update-ModCount })
$p1.Controls.Add($newGameBox)
function Update-ModCount {
    $count = if ($newGameBox.Checked) { 3 } else { 2 }
    $lineLabels[0].Text = "Télécharger $count petits mods sur Nexus Mods"
    $modsTitle.Text = "Étape 1 : télécharge $count mods"
    $alt = Get-Mod "altstart"
    if ($alt.State -ne "done") {
        $alt.State = if ($newGameBox.Checked) { "todo" } else { "skip" }
        Update-Mod $alt $(if ($newGameBox.Checked) { "" } else { "Pas besoin : tu continues une partie déjà commencée." })
    }
}
$needBox = New-Box $p1 32 234 656 100 $light
New-Label $needBox 16 10 620 22 "Il te faut :" $fontBold | Out-Null
New-Label $needBox 16 34 620 20 ([string][char]0x2022 + "  Skyrim Special Edition sur Steam, à jour, lancé au moins une fois") $fontSmall | Out-Null
New-Label $needBox 16 54 620 20 ([string][char]0x2022 + "  Minecraft: Java Edition sur ton compte Microsoft") $fontSmall | Out-Null
New-Label $needBox 16 74 165 20 ([string][char]0x2022 + "  un compte Nexus Mods") $fontSmall | Out-Null
New-Link $needBox 180 73 200 "(gratuit, créer ici)" { Start-Process "https://users.nexusmods.com/register" } | Out-Null

$skyIcon = New-Label $p1 32 346 30 30 "" $fontSymbol
$skyText = New-Label $p1 64 348 520 50 "" $fontSmall
$skyLink = New-Link $p1 590 348 110 "Changer..." {
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Le dossier de Skyrim Special Edition (celui qui contient SkyrimSE.exe)"
    if ($dialog.ShowDialog() -ne "OK") { return }
    if (-not (Test-Path (Join-Path $dialog.SelectedPath "SkyrimSE.exe"))) { Show-Error "Pas de SkyrimSE.exe dans ce dossier."; return }
    Set-Game $dialog.SelectedPath.TrimEnd('\')
}

function Set-Game([string]$dir) {
    $App.Game = $dir
    $App.Version = if ($dir) { Get-GameVersion $dir } else { $null }
    $ok = $false
    if (-not $dir) {
        $skyText.Text = "Je ne trouve pas Skyrim Special Edition. Clique « Changer... » et choisis son dossier."
    } elseif ($App.Version -lt [version]"1.6.0") {
        $skyText.Text = "Ton Skyrim ($($App.Version)) est trop ancien : mets-le à jour sur Steam."
    } elseif ($App.Version -gt $LatestTested) {
        $skyText.Text = ("Skyrim trouvé, mais Steam vient de le mettre à jour (version $($App.Version)). SKSE et SkyCraft " +
            "mettent parfois quelques jours à suivre : tu peux essayer, sinon réessaie un peu plus tard.`n$dir")
        $ok = $true
    } else {
        $skyText.Text = "Skyrim trouvé (version $($App.Version))`n$dir"
        $ok = $true
    }
    $skyIcon.Text = if (-not $ok) { $cross } elseif ($App.Version -gt $LatestTested) { "!" } else { $check }
    $skyIcon.ForeColor = if (-not $ok) { $red } elseif ($App.Version -gt $LatestTested) { [Drawing.Color]::DarkOrange } else { $green }
    $skyLink.Text = if ($dir) { "Changer..." } else { "Choisir..." }
    if ($App.Page -eq 1) { $primary.Enabled = $ok }
}

# --- Écran 2 : les mods -----------------------------------------------------------------------

$p2 = $pages[2]
$modsTitle = New-Label $p2 32 22 660 32 "Étape 1 : télécharge 3 mods" $fontTitle
New-Label $p2 32 60 660 40 ("Pour chaque mod, j'ouvre sa page Nexus dans ton navigateur (connecte-toi la première fois). " +
    "Dès que le fichier arrive dans Téléchargements, je l'installe et je passe au suivant.") $fontText $gray | Out-Null
$howBox = New-Box $p2 32 110 656 160 ([Drawing.Color]::FromArgb(255, 248, 225))
$howTitle = New-Label $howBox 16 12 620 24 "" $fontBold
$howSteps = New-Label $howBox 16 40 620 80 "" $fontText
$howError = New-Label $howBox 16 118 400 36 "" $fontSmall $red
New-Link $howBox 430 128 110 "Rouvrir la page" { if ($App.Mod) { Open-NexusPage $App.Mod } } | Out-Null
New-Link $howBox 530 128 120 "J'ai déjà le fichier..." {
    if (-not $App.Mod) { return }
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Filter = "Archives (*.7z;*.zip)|*.7z;*.zip"
    $dialog.InitialDirectory = Get-DownloadsDir
    if ($dialog.ShowDialog() -eq "OK") {
        $App.Mod.Picked = $dialog.FileName
        $App.Mod.Bad = @($App.Mod.Bad | Where-Object { $_ -ne $dialog.FileName })
    }
} | Out-Null
$y = 286
foreach ($m in $mods) {
    $m.Icon = New-Label $p2 32 $y 30 30 $circle $fontSymbol $gray
    New-Label $p2 64 ($y + 4) 170 24 $m.Name $fontBold | Out-Null
    $m.Status = New-Label $p2 236 ($y + 5) 360 24 "" $fontSmall $gray
    $y += 36
}

function Update-Mod($m, [string]$status) {
    switch ($m.State) {
        "todo" { $m.Icon.Text = $circle; $m.Icon.ForeColor = $gray }
        "wait" { $m.Icon.Text = $dot; $m.Icon.ForeColor = [Drawing.Color]::DarkOrange }
        "done" { $m.Icon.Text = $check; $m.Icon.ForeColor = $green }
        "skip" { $m.Icon.Text = [string][char]0x2013; $m.Icon.ForeColor = $gray }
    }
    $m.Status.Text = $status
}

function Show-ModHelp($m) {
    $howTitle.Text = "$($m.Name) : sur la page qui vient de s'ouvrir"
    $howSteps.Text = ("1.  Onglet « Files »`n" +
        "2.  Sous $($m.File), clique « Manual download »`n" +
        "3.  Clique « Slow download » (gratuit) et attends quelques secondes`n" +
        "C'est tout, je m'occupe du reste.")
    $howError.Text = ""
}

function Step-Mods {
    foreach ($m in $mods) {
        if ($m.State -eq "done" -or $m.State -eq "skip") { continue }
        if (& $m.Installed) { $m.State = "done"; Update-Mod $m "Installé"; continue }
        if ($App.Mod -ne $m) {
            $App.Mod = $m
            $m.State = "wait"
            Update-Mod $m "En attente du téléchargement..."
            Show-ModHelp $m
            if (-not $m.Opened) { Open-NexusPage $m }
        }
        $file = $m.Picked
        if (-not $file) { $found = Find-NexusDownload $m.Nexus $m.Bad; if ($found) { $file = $found.FullName } }
        if (-not $file) { return }
        Update-Mod $m "Installation..."
        [Windows.Forms.Application]::DoEvents()
        try {
            & $m.Install $file
            $m.State = "done"
            Update-Mod $m "Installé"
        } catch {
            $m.Bad += $file
            $m.Picked = $null
            Update-Mod $m "En attente du bon fichier..."
            $howError.Text = "Oups, $([IO.Path]::GetFileName($file)) : $($_.Exception.Message)"
            return
        }
    }
    $App.Mod = $null
    Show-Page 3
}

# --- Écran 3 : compte Minecraft ---------------------------------------------------------------

$p3 = $pages[3]
New-Label $p3 32 22 660 32 "Étape 2 : ton compte Minecraft" $fontTitle | Out-Null
$prepIcon = New-Label $p3 32 64 30 30 $dot $fontSymbol ([Drawing.Color]::DarkOrange)
$prepText = New-Label $p3 64 68 620 24 "Installation de SkyCraft..." $fontText
$progress = New-Object Windows.Forms.ProgressBar
$progress.SetBounds(64, 96, 400, 10)
$progress.Visible = $false
$p3.Controls.Add($progress)
$signBox = New-Box $p3 32 120 656 200 ([Drawing.Color]::FromArgb(255, 248, 225))
New-Label $signBox 16 12 620 24 "Une fenêtre « Prism Launcher » va s'ouvrir. Dedans :" $fontBold | Out-Null
New-Label $signBox 16 42 620 120 ("1.  En haut à droite, clique « Accounts », puis « Manage Accounts... »`n" +
    "2.  Clique « Add Microsoft »`n" +
    "3.  Suis le lien et entre le code affiché, avec le compte Microsoft qui a Minecraft`n" +
    "4.  C'est tout : je vois quand c'est bon et je ferme Prism moi-même.") $fontText | Out-Null
New-Label $signBox 16 160 620 36 "Tu ne fais ça qu'une fois. Minecraft, lui, se télécharge tout seul au premier lancement du jeu." $fontSmall $gray | Out-Null
$signBox.Visible = $false
$signIcon = New-Label $p3 32 334 30 30 "" $fontSymbol
$signText = New-Label $p3 64 338 620 40 "" $fontText

function Open-Prism {
    if ($App.Prism -and -not $App.Prism.HasExited) { return }
    $App.Prism = Start-Process "$mcDir\Prism\prismlauncher.exe" -WorkingDirectory "$mcDir\Prism" -PassThru
}

function Set-Prep([string]$state, [string]$text) {
    $prepText.Text = $text
    switch ($state) {
        "wait" { $prepIcon.Text = $dot; $prepIcon.ForeColor = [Drawing.Color]::DarkOrange }
        "done" { $prepIcon.Text = $check; $prepIcon.ForeColor = $green }
        "fail" { $prepIcon.Text = $cross; $prepIcon.ForeColor = $red }
    }
    [Windows.Forms.Application]::DoEvents()
}

# install (SkyCraft, éventuellement téléchargé) > unpack (son Minecraft) > signin (Prism) > page 4
function Step-Minecraft {
    switch ($App.Mc) {
        "install" {
            $zip = $null
            if ($App.Download) {
                $task = $App.Download.Task
                if (-not $task.IsCompleted) {
                    if (Test-Path $App.Download.Path) { $progress.Value = [Math]::Min(100, [int](100 * (Get-Item $App.Download.Path).Length / $App.Download.Size)) }
                    return
                }
                $progress.Visible = $false
                $path = $App.Download.Path
                $App.Download = $null
                if ($task.IsFaulted) { throw "le téléchargement de SkyCraft a échoué ($($task.Exception.InnerException.Message))." }
                $zip = $path
            } else {
                $local = Find-LocalSkyCraftZip
                if ($local) { $zip = $local.FullName }
                else {
                    try { $release = Invoke-RestMethod "https://api.github.com/repos/$GitHubRepo/releases/latest" -UseBasicParsing }
                    catch { throw "SkyCraft-<version>.zip n'est pas à côté de l'installateur. As-tu bien extrait tout le zip ?" }
                    $asset = $release.assets | Where-Object { $_.name -match '^SkyCraft-[\d.]+\.zip$' } | Select-Object -First 1
                    if (-not $asset) { throw "pas de SkyCraft-<version>.zip dans la dernière release GitHub." }
                    $path = Join-Path $work $asset.name
                    Remove-Item $path -ErrorAction SilentlyContinue
                    $App.Download = @{ Task = (New-Object Net.WebClient).DownloadFileTaskAsync($asset.browser_download_url, $path); Path = $path; Size = [double]$asset.size }
                    $progress.Value = 0
                    $progress.Visible = $true
                    Set-Prep "wait" "Téléchargement de SkyCraft..."
                    return
                }
            }
            Set-Prep "wait" "Installation de SkyCraft..."
            Install-SkyCraft $zip
            Set-Prep "wait" "Préparation de Minecraft..."
            $App.Unpack = Start-Unpack
            $App.Mc = "unpack"
        }
        "unpack" {
            if ($App.Unpack) {
                if (-not $App.Unpack.HasExited) { return }
                if ($App.Unpack.ExitCode) { throw "le Minecraft de SkyCraft n'a pas pu être dépaqueté (tar $($App.Unpack.ExitCode))." }
                Complete-Unpack
                $App.Unpack = $null
            }
            Set-Prep "done" "SkyCraft est installé."
            if (Test-MinecraftAccount) { Show-Page 4; return }
            $signBox.Visible = $true
            $signIcon.Text = $dot; $signIcon.ForeColor = [Drawing.Color]::DarkOrange
            $signText.Text = "En attente de ta connexion dans Prism..."
            Set-Footer "Rouvrir Prism" { Open-Prism } "Plus tard" { Show-Page 4 }
            Open-Prism
            $App.Mc = "signin"
        }
        "signin" {
            if (-not (Test-MinecraftAccount)) { return }
            $signIcon.Text = $check; $signIcon.ForeColor = $green
            $signText.Text = "Compte Minecraft connecté !"
            if ($App.Prism -and -not $App.Prism.HasExited) { [void]$App.Prism.CloseMainWindow() }
            $App.Mc = "done"
            Show-Page 4
        }
    }
}

# --- Écran 4 : prêt ---------------------------------------------------------------------------

$p4 = $pages[4]
New-Label $p4 32 22 660 32 "C'est prêt !" $fontTitle | Out-Null
$readyText = New-Label $p4 32 62 660 70 "" $fontText
$tipsBox = New-Box $p4 32 140 656 240 $light
New-Label $tipsBox 16 12 620 24 "Bon à savoir" $fontBold | Out-Null
$tipsText = New-Label $tipsBox 16 38 624 196 "" $fontSmall

function Enter-Ready {
    New-Shortcut
    $bullet = [string][char]0x2022 + "  "
    $start = if (Test-Path (Join-Path $App.Game "Data\AlternateStart.esp")) { "Nouvelle partie : tu te réveilles dans une cellule, prie la statue de Mara pour choisir où tu commences." }
             else { "Charge une sauvegarde faite après Helgen (l'intro de Skyrim peut bloquer SkyCraft)." }
    $tipsText.Text = ($bullet + "Lance toujours le jeu avec le raccourci « SkyCraft » du Bureau (pas depuis Steam).`n" +
        $bullet + "Premier lancement : Minecraft se télécharge en arrière-plan (quelques minutes). Les messages en haut à gauche de Skyrim disent quand c'est prêt.`n" +
        $bullet + $start + "`n" +
        $bullet + "Touches : G parler / ouvrir (Skyrim), E inventaire, O menu Minecraft, Échap menu Skyrim.`n" +
        $bullet + "Conseil : dans Steam, clic droit sur Skyrim > Propriétés > Mises à jour > « Ne mettre à jour ce jeu que lorsque je le lance ». Comme tu passes par le raccourci, Steam ne cassera plus SKSE avec une mise à jour surprise.")
    $readyText.Text = if (Test-MinecraftAccount) {
        "Tout est installé et ton compte Minecraft est connecté. Raccourci « SkyCraft » ajouté sur le Bureau."
    } else {
        "Tout est installé. Raccourci « SkyCraft » ajouté sur le Bureau. Au premier lancement, une fenêtre Prism te demandera de te connecter à ton compte Microsoft (Alt-Tab)."
    }
}

# --- Navigation -------------------------------------------------------------------------------

function Show-Page([int]$n) {
    $App.Page = $n
    foreach ($k in $pages.Keys) { $pages[$k].Visible = ($k -eq $n) }
    $stepLabel.Text = "Étape $n sur 4  " + [string][char]0x2022 + "  " + $pageNames[$n]
    switch ($n) {
        1 {
            Set-Footer "Commencer" {
                if (-not (Test-Writable $App.Game)) {
                    if (Test-Admin) { Show-Error "Impossible d'écrire dans $($App.Game)."; return }
                    $answer = [Windows.Forms.MessageBox]::Show("Skyrim est dans un dossier protégé : je dois redémarrer en administrateur (Windows va te demander l'autorisation).", "SkyCraft", "OKCancel", "Information")
                    if ($answer -eq "OK") { Restart-Elevated $App.Game 2 }
                    return
                }
                Show-Page 2
            } "" $null
            Set-Game $App.Game
        }
        2 { Set-Footer "" $null "" $null }
        3 { Set-Footer "" $null "" $null }
        4 {
            Enter-Ready
            Set-Footer "Jouer" {
                if ($Launcher -and (Test-Path $Launcher)) { Start-Process $Launcher -ArgumentList "--play" }
                else { Start-Process (Join-Path $App.Game "skse64_loader.exe") -WorkingDirectory $App.Game }
                $form.Close()
            } "Fermer" { $form.Close() }
        }
    }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 800
$timer.add_Tick({
    if ($App.Busy) { return }
    $App.Busy = $true
    try {
        if ($App.Page -eq 2) { Step-Mods }
        elseif ($App.Page -eq 3 -and $App.Mc -ne "failed") { Step-Minecraft }
    } catch {
        if ($App.Page -eq 3) {
            $App.Mc = "failed"
            Set-Prep "fail" ("Problème : " + $_.Exception.Message)
            Set-Footer "Réessayer" { $App.Mc = "install"; Set-Footer "" $null "" $null } "" $null
        } else {
            $howError.Text = "Problème : " + $_.Exception.Message
        }
    } finally { $App.Busy = $false }
})

try {
    if (-not $Game) { $Game = Find-Skyrim }
    Set-Game $Game
    Update-ModCount
    Show-Page $(if ($Game -and $Page -gt 1) { $Page } else { 1 })
    $timer.Start()
    [void]$form.ShowDialog()
} catch {
    Show-Error "L'installateur a planté : $($_.Exception.Message)"
}
