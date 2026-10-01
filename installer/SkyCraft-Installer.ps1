# Installateur SkyCraft pour joueurs : une fenêtre qui installe tout dans le Skyrim de Steam (sans
# gestionnaire de mods). SKSE64, Address Library et Alternate Start viennent de Nexus Mods : la page
# s'ouvre, le joueur clique « Manual download », et l'installateur prend le fichier dans
# Téléchargements tout seul. SkyCraft vient du zip posé à côté (dist\SkyCraft-Installer-<version>.zip,
# fait par tools\package.ps1), ou à défaut de la dernière release GitHub.
param([string]$Game = "")

# ===== À régler ==================================================================================
# Lien du tuto (vidéo, doc...). Vide : le bouton « Tutoriel » dit que le tuto arrive bientôt.
$TutorialUrl = ""
# Dépôt GitHub dont on prend la dernière release si aucun SkyCraft-<version>.zip n'est à côté.
$GitHubRepo = "Zeyrin/SkyCraft"
# =================================================================================================

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.IO.Compression.FileSystem
[Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$here = $PSScriptRoot
$work = Join-Path $env:TEMP "SkyCraft-Installer"
New-Item -ItemType Directory $work -Force | Out-Null

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

# Steam installe souvent Skyrim dans Program Files : il faut alors les droits administrateur.
function Restart-Elevated([string]$dir) {
    Start-Process powershell -Verb RunAs -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-WindowStyle", "Hidden",
        "-File", "`"$PSCommandPath`"", "-Game", "`"$dir`"")
    [Environment]::Exit(0)
}

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
    $dir = Get-DownloadsDir
    Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
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

# --- Étapes -----------------------------------------------------------------------------------

$App = @{ Game = $null; Version = $null; Running = $false; Busy = $false }

function VersionTag([string]$sep) { "{1}{0}{2}{0}{3}" -f $sep, $App.Version.Major, $App.Version.Minor, $App.Version.Build }
function SkseDll { Join-Path $App.Game ("skse64_{0}.dll" -f (VersionTag "_")) }
function AddressLibBin { Join-Path $App.Game ("Data\SKSE\Plugins\versionlib-{0}-0.bin" -f (VersionTag "-")) }

$steps = @(
    @{ Key = "skyrim"; Title = "Skyrim Special Edition"; Button = "Changer..." },
    @{ Key = "skse"; Title = "SKSE64 (Skyrim Script Extender)"; Button = "Choisir le fichier..."; Nexus = 30379
        Hint = "Sur la page : section « Main files », le build « Anniversary Edition » > Manual download." },
    @{ Key = "addrlib"; Title = "Address Library for SKSE Plugins"; Button = "Choisir le fichier..."; Nexus = 32444
        Hint = "Sur la page : « All in one (Anniversary Edition) » > Manual download." },
    @{ Key = "altstart"; Title = "Alternate Start (recommandé)"; Button = "Choisir le fichier..."; Skip = "Passer"; Nexus = 272
        Hint = "Sur la page : le fichier principal (Main files) > Manual download. Évite l'intro de Helgen, qui peut bloquer SkyCraft." },
    @{ Key = "skycraft"; Title = "SkyCraft" },
    @{ Key = "shortcut"; Title = "Raccourci « SkyCraft » sur le Bureau" }
)
foreach ($s in $steps) { $s.State = "todo"; $s.Bad = @(); $s.Picked = $null; $s.Opened = $false }
function Step([string]$key) { $steps | Where-Object { $_.Key -eq $key } | Select-Object -First 1 }

function Install-Skse([string]$archive) {
    $tmp = Join-Path $work "skse"
    Expand-Any $archive $tmp
    $loader = Get-ChildItem $tmp -Recurse -Filter "skse64_loader.exe" | Select-Object -First 1
    if (-not $loader) { throw "Ce fichier n'est pas SKSE64 (pas de skse64_loader.exe dedans)." }
    if (-not (Test-Path (Join-Path $loader.DirectoryName ([IO.Path]::GetFileName((SkseDll)))))) {
        throw "Ce SKSE n'est pas pour Skyrim $($App.Version). Prends le build « Anniversary Edition » le plus récent."
    }
    Copy-Merge $loader.DirectoryName $App.Game @("src")
}

function Install-AddressLib([string]$archive) {
    $tmp = Join-Path $work "addrlib"
    Expand-Any $archive $tmp
    $want = [IO.Path]::GetFileName((AddressLibBin))
    if (-not (Get-ChildItem $tmp -Recurse -Filter $want)) {
        throw "Ce n'est pas le bon fichier pour Skyrim $($App.Version) : prends « All in one (Anniversary Edition) »."
    }
    $plugins = Join-Path $App.Game "Data\SKSE\Plugins"
    New-Item -ItemType Directory $plugins -Force | Out-Null
    Get-ChildItem $tmp -Recurse -Filter "versionlib-*.bin" | Copy-Item -Destination $plugins -Force
}

function Install-AltStart([string]$archive) {
    $tmp = Join-Path $work "altstart"
    Expand-Any $archive $tmp
    $esp = Get-ChildItem $tmp -Recurse -Filter "AlternateStart.esp" | Select-Object -First 1
    if (-not $esp) { throw "Ce fichier n'est pas Alternate Start (pas d'AlternateStart.esp dedans)." }
    Copy-Merge $esp.DirectoryName (Join-Path $App.Game "Data") @("fomod")
    Enable-Plugin "AlternateStart.esp"
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

function Find-LocalSkyCraftZip {
    Get-ChildItem $here -Filter "SkyCraft-*.zip" -File | Where-Object { $_.Name -match '^SkyCraft-[\d.]+\.zip$' } |
        Sort-Object Name -Descending | Select-Object -First 1
}

# Une étape Nexus : déjà installée, ou fichier choisi, ou fichier trouvé dans Téléchargements, ou
# on ouvre la page et on attend.
function Invoke-NexusStep($s, [scriptblock]$installed, [scriptblock]$install) {
    if (& $installed) { Set-Detail $s "Déjà installé."; return "done" }
    if ($s.Skipped) { return "skip" }
    $file = $s.Picked
    if (-not $file) { $found = Find-NexusDownload $s.Nexus $s.Bad; if ($found) { $file = $found.FullName } }
    if (-not $file) {
        if (-not $s.Opened) {
            Start-Process "https://www.nexusmods.com/skyrimspecialedition/mods/$($s.Nexus)?tab=files"
            $s.Opened = $true
        }
        Set-Detail $s ("Page Nexus ouverte (compte gratuit nécessaire). " + $s.Hint + " J'attends le fichier dans Téléchargements...")
        return "wait"
    }
    Set-Detail $s "Installation de $([IO.Path]::GetFileName($file))..."
    try {
        & $install $file
    } catch {
        $s.Bad += $file
        $s.Picked = $null
        Set-Detail $s ("Mauvais fichier : " + $_.Exception.Message)
        return "wait"
    }
    Set-Detail $s "Installé."
    return "done"
}

function Invoke-Step($s) {
    switch ($s.Key) {
        "skyrim" {
            if (-not $App.Game) { Set-Detail $s "Skyrim introuvable : clique « Changer... » et choisis son dossier (celui avec SkyrimSE.exe)."; return "fail" }
            if ($App.Version -lt [version]"1.6.0") {
                Set-Detail $s "Skyrim $($App.Version) n'est pas supporté : il faut la version à jour de Steam (1.6 ou plus)."
                return "fail"
            }
            if (-not (Test-Writable $App.Game)) {
                if (Test-Admin) { Set-Detail $s "Impossible d'écrire dans $($App.Game)."; return "fail" }
                $answer = [Windows.Forms.MessageBox]::Show("Skyrim est dans un dossier protégé. L'installateur doit redémarrer en administrateur.", "SkyCraft", "OKCancel", "Information")
                if ($answer -eq "OK") { Restart-Elevated $App.Game }
                Set-Detail $s "Droits administrateur nécessaires pour écrire dans $($App.Game)."
                return "fail"
            }
            Set-Detail $s "$($App.Game)  (version $($App.Version))"
            return "done"
        }
        "skse" { return Invoke-NexusStep $s { (Test-Path (Join-Path $App.Game "skse64_loader.exe")) -and (Test-Path (SkseDll)) } { param($f) Install-Skse $f } }
        "addrlib" { return Invoke-NexusStep $s { Test-Path (AddressLibBin) } { param($f) Install-AddressLib $f } }
        "altstart" { return Invoke-NexusStep $s { Test-Path (Join-Path $App.Game "Data\AlternateStart.esp") } { param($f) Install-AltStart $f } }
        "skycraft" {
            if ($s.Download) {
                # Téléchargement GitHub en cours (asynchrone, pour ne pas figer la fenêtre).
                $task = $s.Download.Task
                if (-not $task.IsCompleted) {
                    if (Test-Path $s.Download.Path) { $progress.Value = [Math]::Min(100, [int](100 * (Get-Item $s.Download.Path).Length / $s.Download.Size)) }
                    return "wait"
                }
                $progress.Value = 0
                $path = $s.Download.Path
                $s.Download = $null
                if ($task.IsFaulted) { Set-Detail $s "Le téléchargement a échoué : $($task.Exception.InnerException.Message)"; return "fail" }
                $zip = $path
            } else {
                $local = Find-LocalSkyCraftZip
                if ($local) {
                    $zip = $local.FullName
                } else {
                    try {
                        $release = Invoke-RestMethod "https://api.github.com/repos/$GitHubRepo/releases/latest" -UseBasicParsing
                    } catch {
                        Set-Detail $s "Pas de SkyCraft-<version>.zip à côté de l'installateur, et la release GitHub est inaccessible. As-tu bien extrait tout le zip ?"
                        return "fail"
                    }
                    $asset = $release.assets | Where-Object { $_.name -match '^SkyCraft-[\d.]+\.zip$' } | Select-Object -First 1
                    if (-not $asset) { Set-Detail $s "La dernière release GitHub n'a pas de SkyCraft-<version>.zip."; return "fail" }
                    $path = Join-Path $work $asset.name
                    Remove-Item $path -ErrorAction SilentlyContinue
                    $client = New-Object Net.WebClient
                    $s.Download = @{ Task = $client.DownloadFileTaskAsync($asset.browser_download_url, $path); Path = $path; Size = [double]$asset.size }
                    Set-Detail $s "Téléchargement de $($asset.name)..."
                    return "wait"
                }
            }
            Set-Detail $s "Installation de $([IO.Path]::GetFileName($zip))..."
            Install-SkyCraft $zip
            Set-Detail $s "Installé ($([IO.Path]::GetFileNameWithoutExtension($zip)))."
            return "done"
        }
        "shortcut" {
            $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "SkyCraft.lnk"
            $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
            $lnk.TargetPath = Join-Path $App.Game "skse64_loader.exe"
            $lnk.WorkingDirectory = $App.Game
            $lnk.IconLocation = (Join-Path $App.Game "SkyrimSE.exe") + ",0"
            $lnk.Description = "Skyrim avec SkyCraft (via SKSE)"
            $lnk.Save()
            Set-Detail $s "Créé : lance toujours le jeu avec ce raccourci (pas depuis Steam)."
            return "done"
        }
    }
}

# --- Fenêtre ----------------------------------------------------------------------------------

$font = New-Object Drawing.Font("Segoe UI", 9)
$form = New-Object Windows.Forms.Form
$form.Text = "SkyCraft - Installation"
$form.ClientSize = New-Object Drawing.Size(760, 600)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.Font = $font
$form.BackColor = [Drawing.Color]::White

function Add-Label([int]$x, [int]$y, [int]$w, [int]$h, [string]$text, $f = $font, $color = [Drawing.Color]::Black) {
    $l = New-Object Windows.Forms.Label
    $l.SetBounds($x, $y, $w, $h)
    $l.Text = $text
    $l.Font = $f
    $l.ForeColor = $color
    $form.Controls.Add($l)
    return $l
}
function Add-Button([int]$x, [int]$y, [int]$w, [int]$h, [string]$text) {
    $b = New-Object Windows.Forms.Button
    $b.SetBounds($x, $y, $w, $h)
    $b.Text = $text
    $form.Controls.Add($b)
    return $b
}

Add-Label 20 14 720 32 "SkyCraft - Installation" (New-Object Drawing.Font("Segoe UI", 16, [Drawing.FontStyle]::Bold)) | Out-Null
Add-Label 20 50 720 40 ("Il te faut Skyrim Special Edition sur Steam (à jour) et Minecraft: Java Edition sur ton compte Microsoft. " +
    "Un compte Nexus Mods gratuit sert à télécharger 3 petits mods : l'installateur ouvre les pages, tu cliques, il fait le reste.") $font ([Drawing.Color]::DimGray) | Out-Null

$gray = [Drawing.Color]::DimGray
$symbolFont = New-Object Drawing.Font("Segoe UI Symbol", 14)
$boldFont = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$y = 100
foreach ($s in $steps) {
    $s.Icon = Add-Label 20 ($y + 2) 32 30 ([string][char]0x25CB) $symbolFont $gray
    Add-Label 60 $y 410 20 $s.Title $boldFont | Out-Null
    $s.Detail = Add-Label 60 ($y + 21) 420 40 "" $font $gray
    if ($s.Button) { $s.ButtonControl = Add-Button 490 ($y + 4) 125 28 $s.Button }
    if ($s.Skip) { $s.SkipControl = Add-Button 620 ($y + 4) 120 28 $s.Skip }
    $y += 64
}

$progress = New-Object Windows.Forms.ProgressBar
$progress.SetBounds(20, 492, 720, 14)
$form.Controls.Add($progress)
$status = Add-Label 20 512 720 22 "Clique « Installer » pour commencer." $font

$tutorialButton = Add-Button 20 545 170 40 "Tutoriel"
$installButton = Add-Button 390 545 170 40 "Installer"
$playButton = Add-Button 570 545 170 40 "Jouer"
$installButton.Font = $boldFont
$playButton.Font = $boldFont
$playButton.Enabled = $false

function Set-Detail($s, [string]$text) { $s.Detail.Text = $text; [Windows.Forms.Application]::DoEvents() }
function Set-State($s, [string]$state) {
    $s.State = $state
    switch ($state) {
        "todo" { $s.Icon.Text = [string][char]0x25CB; $s.Icon.ForeColor = $gray }
        "wait" { $s.Icon.Text = [string][char]0x25CF; $s.Icon.ForeColor = [Drawing.Color]::DarkOrange }
        "done" { $s.Icon.Text = [string][char]0x2714; $s.Icon.ForeColor = [Drawing.Color]::ForestGreen }
        "skip" { $s.Icon.Text = [string][char]0x2013; $s.Icon.ForeColor = $gray }
        "fail" { $s.Icon.Text = [string][char]0x2716; $s.Icon.ForeColor = [Drawing.Color]::Firebrick }
    }
}

function Set-Game([string]$dir) {
    $App.Game = $dir
    $App.Version = if ($dir) { Get-GameVersion $dir } else { $null }
    $sky = Step "skyrim"
    if ($dir) { Set-Detail $sky "$dir  (version $($App.Version))" } else { Set-Detail $sky "Pas trouvé automatiquement : clique « Changer... »." }
    foreach ($s in $steps) { if ($s.State -ne "skip") { Set-State $s "todo" } }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.add_Tick({
    if ($App.Busy) { return }
    $App.Busy = $true
    try {
        $current = $steps | Where-Object { $_.State -eq "todo" -or $_.State -eq "wait" } | Select-Object -First 1
        if (-not $current) {
            $timer.Stop()
            $App.Running = $false
            $installButton.Enabled = $true
            $installButton.Text = "Réinstaller"
            $playButton.Enabled = $true
            $status.Text = "Tout est prêt ! Lance le jeu avec « Jouer » ou le raccourci SkyCraft du Bureau."
            [Windows.Forms.MessageBox]::Show(("SkyCraft est installé !`n`n" +
                "Au premier lancement, une petite fenêtre Prism Launcher demande de te connecter avec ton compte Microsoft (celui qui a Minecraft). " +
                "Fais Alt-Tab, connecte-toi, puis reviens dans Skyrim : Minecraft se télécharge (quelques minutes, une seule fois).`n`n" +
                "Commence une nouvelle partie : Alternate Start te laisse choisir où tu démarres."), "SkyCraft", "OK", "Information") | Out-Null
            return
        }
        $status.Text = "En cours : $($current.Title)"
        # Le dernier objet : un appel oublié qui écrit dans le pipeline ne fausse pas le résultat.
        $result = Invoke-Step $current | Select-Object -Last 1
        Set-State $current $result
        if ($result -eq "fail") {
            $timer.Stop()
            $App.Running = $false
            $installButton.Enabled = $true
            $installButton.Text = "Réessayer"
            $status.Text = "Bloqué à « $($current.Title) » : voir le message à côté."
        }
    } catch {
        $timer.Stop()
        $App.Running = $false
        $installButton.Enabled = $true
        $installButton.Text = "Réessayer"
        if ($current) { Set-State $current "fail"; Set-Detail $current $_.Exception.Message }
        $status.Text = "Erreur : $($_.Exception.Message)"
    } finally { $App.Busy = $false }
})

$installButton.add_Click({
    foreach ($s in $steps) { if ($s.State -ne "skip") { Set-State $s "todo" } }
    $installButton.Enabled = $false
    $playButton.Enabled = $false
    $App.Running = $true
    $timer.Start()
})

$tutorialButton.add_Click({
    if ($TutorialUrl) { Start-Process $TutorialUrl }
    else { [Windows.Forms.MessageBox]::Show("Le tuto arrive bientôt !", "SkyCraft", "OK", "Information") | Out-Null }
})

$playButton.add_Click({
    Start-Process (Join-Path $App.Game "skse64_loader.exe") -WorkingDirectory $App.Game
    $form.Close()
})

(Step "skyrim").ButtonControl.add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Le dossier de Skyrim Special Edition (celui qui contient SkyrimSE.exe)"
    if ($dialog.ShowDialog() -ne "OK") { return }
    if (-not (Test-Path (Join-Path $dialog.SelectedPath "SkyrimSE.exe"))) { Show-Error "Pas de SkyrimSE.exe dans ce dossier."; return }
    Set-Game $dialog.SelectedPath.TrimEnd('\')
})

# Les boutons retrouvent leur étape par Tag (pas de GetNewClosure : il ne voit pas les fonctions du script).
foreach ($s in $steps | Where-Object { $_.Nexus }) {
    $s.ButtonControl.Tag = $s.Key
    $s.ButtonControl.add_Click({
        param($sender)
        $step = Step $sender.Tag
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Filter = "Archives (*.7z;*.zip)|*.7z;*.zip"
        $dialog.InitialDirectory = Get-DownloadsDir
        if ($dialog.ShowDialog() -ne "OK") { return }
        $step.Picked = $dialog.FileName
        $step.Skipped = $false
        $step.Bad = @($step.Bad | Where-Object { $_ -ne $dialog.FileName })
        if (-not $App.Running) { Set-State $step "todo"; Set-Detail $step "Fichier choisi : clique « Installer »." }
    })
    if ($s.SkipControl) {
        $s.SkipControl.Tag = $s.Key
        $s.SkipControl.add_Click({
            param($sender)
            $step = Step $sender.Tag
            $step.Skipped = $true
            Set-State $step "skip"
            Set-Detail $step "Passé. Sans lui, commence depuis une sauvegarde faite après Helgen."
        })
    }
}

try {
    if ($Game) { Set-Game $Game } else { Set-Game (Find-Skyrim) }
    # Relancé en administrateur : on reprend directement.
    if ($Game) { $installButton.PerformClick() }
    [void]$form.ShowDialog()
} catch {
    Show-Error "L'installateur a planté : $($_.Exception.Message)"
}
