[CmdletBinding()]
param(
    [string]$GameRoot,
    [string]$SourceRoot = (Join-Path $PSScriptRoot 'src\RfdEditorSupport')
)
$ErrorActionPreference = 'Stop'

function Resolve-RdfEditorGameRoot([string]$ExplicitPath) {
    if (![string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return (Resolve-Path -LiteralPath $ExplicitPath).Path.TrimEnd('\')
    }
    # Narrow discovery only: adjacent LIVE folders, common installation layouts,
    # the launcher's library setting, and this tool's own install receipts.
    # Never recurse over a user's drives or guess between multiple valid games.
    $rdfCandidatePaths = New-Object 'System.Collections.Generic.List[string]'
    $rdfLauncherConfigs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rdfBase in @($PSScriptRoot,(Get-Location).Path)) {
        $rdfWalk = [IO.Path]::GetFullPath($rdfBase)
        while ($rdfWalk) {
            foreach ($rdfSuffix in @('', 'LIVE', 'R5R Library\LIVE', 'R5Reloaded\R5R Library\LIVE')) {
                $rdfCandidate = if ($rdfSuffix) { Join-Path $rdfWalk $rdfSuffix } else { $rdfWalk }
                $rdfCandidatePaths.Add($rdfCandidate)
            }
            $rdfLauncherConfigs.Add((Join-Path $rdfWalk 'launcher_data\cfg\launcherConfig.ini'))
            $rdfLauncherConfigs.Add((Join-Path $rdfWalk 'R5R Launcher\launcher_data\cfg\launcherConfig.ini'))
            $rdfNext = Split-Path -Parent $rdfWalk
            if ($rdfNext -eq $rdfWalk) { break }
            $rdfWalk = $rdfNext
        }
    }
    foreach ($rdfDrive in [IO.DriveInfo]::GetDrives()) {
        if ($rdfDrive.DriveType -ne [IO.DriveType]::Fixed -or !$rdfDrive.IsReady) { continue }
        foreach ($rdfSuffix in @('R5Reloaded\R5R Library\LIVE','R5R Library\LIVE')) {
            $rdfCandidatePaths.Add((Join-Path $rdfDrive.RootDirectory.FullName $rdfSuffix))
        }
        foreach ($rdfSuffix in @('R5Reloaded\R5R Launcher\launcher_data\cfg\launcherConfig.ini','R5R Launcher\launcher_data\cfg\launcherConfig.ini')) {
            $rdfLauncherConfigs.Add((Join-Path $rdfDrive.RootDirectory.FullName $rdfSuffix))
        }
    }
    foreach ($rdfConfig in @($rdfLauncherConfigs | Sort-Object -Unique)) {
        if (!(Test-Path -LiteralPath $rdfConfig -PathType Leaf)) { continue }
        $rdfLibraryLine = Get-Content -LiteralPath $rdfConfig |
            Where-Object { $_ -match '^\s*Library_Location\s*=' } | Select-Object -First 1
        if (!$rdfLibraryLine) { continue }
        $rdfLibrary = ([string]$rdfLibraryLine -split '=',2)[1].Trim().Trim('"')
        if ([IO.Path]::IsPathRooted($rdfLibrary)) {
            $rdfCandidatePaths.Add($rdfLibrary)
            $rdfCandidatePaths.Add((Join-Path $rdfLibrary 'LIVE'))
            $rdfCandidatePaths.Add((Join-Path $rdfLibrary 'R5R Library\LIVE'))
        }
    }
    $rdfOwnBackups = Join-Path $PSScriptRoot 'backups'
    if (Test-Path -LiteralPath $rdfOwnBackups -PathType Container) {
        foreach ($rdfPrevious in Get-ChildItem -LiteralPath $rdfOwnBackups -Directory |
            Sort-Object CreationTimeUtc -Descending | Select-Object -First 20) {
            $rdfPreviousManifest = Join-Path $rdfPrevious.FullName 'install.json'
            if (!(Test-Path -LiteralPath $rdfPreviousManifest -PathType Leaf)) { continue }
            try {
                $rdfPreviousData = Get-Content -LiteralPath $rdfPreviousManifest -Raw | ConvertFrom-Json
                if ($rdfPreviousData.ToolId -eq 'rfd-editor-install' -and $rdfPreviousData.GameRoot) {
                    $rdfCandidatePaths.Add([string]$rdfPreviousData.GameRoot)
                }
            } catch { continue }
        }
    }
    $rdfValidGames = @()
    foreach ($rdfCandidate in @($rdfCandidatePaths | Sort-Object -Unique)) {
        try {
            $rdfCandidateFull = [IO.Path]::GetFullPath($rdfCandidate).TrimEnd('\')
            $rdfCandidateBuild = Join-Path $rdfCandidateFull 'build.txt'
            if ((Test-Path -LiteralPath (Join-Path $rdfCandidateFull 'r5apex.exe') -PathType Leaf) -and
                (Test-Path -LiteralPath $rdfCandidateBuild -PathType Leaf) -and
                [IO.File]::ReadAllText($rdfCandidateBuild).Trim() -eq 'R5R-v2.6.52') {
                $rdfValidGames += (Resolve-Path -LiteralPath $rdfCandidateFull).Path.TrimEnd('\')
            }
        } catch { continue }
    }
    $rdfValidGames = @($rdfValidGames | Sort-Object -Unique)
    if ($rdfValidGames.Count -eq 1) { return $rdfValidGames[0] }
    if ($rdfValidGames.Count -gt 1) {
        throw ('Multiple R5R-v2.6.52 LIVE directories found. Supply -GameRoot explicitly: ' + ($rdfValidGames -join ', '))
    }
    throw "No R5R-v2.6.52 LIVE directory found. Supply -GameRoot 'X:\path\to\LIVE'."
}

function Assert-RdfEditorInstallNoLinks([string]$Path) {
    $rdfProbe = [IO.Path]::GetFullPath($Path)
    while ($rdfProbe) {
        if ((Test-Path -LiteralPath $rdfProbe) -and ((Get-Item -LiteralPath $rdfProbe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Editor installation does not follow links/junctions: $rdfProbe"
        }
        $rdfParent = Split-Path -Parent $rdfProbe
        if ($rdfParent -eq $rdfProbe) { break }
        $rdfProbe = $rdfParent
    }
}

function Get-RdfEditorProtectedState([string]$Root) {
    foreach ($rdfRelative in @(
        'platform\scripts\vscripts\mp\_base_gametype.gnut',
        'platform\scripts\vscripts\gamemodes\survival\_gamemode_survival.nut',
        'platform\scripts\vscripts\scripts.rson',
        'mods\mods.vdf'
    )) {
        $rdfPath = Join-Path $Root $rdfRelative
        Assert-RdfEditorInstallNoLinks $rdfPath
        if ((Test-Path -LiteralPath $rdfPath) -and !(Test-Path -LiteralPath $rdfPath -PathType Leaf)) {
            throw "Protected path is not a file: $rdfRelative"
        }
        $rdfExists = Test-Path -LiteralPath $rdfPath -PathType Leaf
        $rdfHash = if ($rdfExists) { (Get-FileHash -LiteralPath $rdfPath -Algorithm SHA256).Hash } else { $null }
        [pscustomobject]@{ Path=$rdfRelative; Existed=$rdfExists; Sha256=$rdfHash }
    }
}

if (Get-Process r5apex,r5apex_ds -ErrorAction SilentlyContinue) {
    throw 'Close the R5R game and dedicated server before installing the editor. No process was stopped.'
}
$rdfGame = Resolve-RdfEditorGameRoot $GameRoot
$rdfSource = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
$rdfTarget = [IO.Path]::GetFullPath((Join-Path $rdfGame 'mods\RfdEditorSupport')).TrimEnd('\')
$rdfSaves = [IO.Path]::GetFullPath((Join-Path $rdfGame 'platform\rfd_editor_saves'))
$rdfNativeConfig = [IO.Path]::GetFullPath((Join-Path $rdfGame 'platform\cfg\rdf_level_editor.cfg'))
$rdfSourceConfig = Join-Path $rdfSource 'cfg\rdf_level_editor.cfg'
$rdfBuild = Join-Path $rdfGame 'build.txt'
if (!(Test-Path -LiteralPath $rdfBuild -PathType Leaf) -or [IO.File]::ReadAllText($rdfBuild).Trim() -ne 'R5R-v2.6.52') {
    throw 'Editor installation requires R5R-v2.6.52.'
}
if (!(Test-Path -LiteralPath $rdfSource -PathType Container) -or !(Test-Path -LiteralPath (Join-Path $rdfSource 'mod.vdf') -PathType Leaf)) {
    throw 'SourceRoot must contain the standalone editor support mod.'
}
if ([IO.File]::ReadAllText((Join-Path $rdfSource 'mod.vdf')) -notmatch '"id"\s+"rfdeditor"') {
    throw 'Expected editor mod id rfdeditor.'
}
if (!(Test-Path -LiteralPath $rdfSourceConfig -PathType Leaf)) { throw 'The editor source must include cfg/rdf_level_editor.cfg.' }
if ([IO.Path]::GetFullPath($rdfSourceConfig).Equals($rdfNativeConfig,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'The editor source config must not be the installed native config.'
}
if ($rdfSource.Equals($rdfTarget,[StringComparison]::OrdinalIgnoreCase) -or $rdfSource.StartsWith($rdfTarget+'\',[StringComparison]::OrdinalIgnoreCase) -or $rdfTarget.StartsWith($rdfSource+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source and installed mod directories must not overlap.'
}
foreach ($rdfGuardPath in @($rdfSource,$rdfTarget,$rdfSaves,$rdfNativeConfig,(Join-Path $PSScriptRoot 'backups'))) {
    Assert-RdfEditorInstallNoLinks $rdfGuardPath
}
if ((Test-Path -LiteralPath $rdfTarget) -and !(Test-Path -LiteralPath $rdfTarget -PathType Container)) { throw 'Editor mod target is not a directory.' }
if ((Test-Path -LiteralPath $rdfSaves) -and !(Test-Path -LiteralPath $rdfSaves -PathType Container)) { throw 'Editor save path is not a directory.' }
if ((Test-Path -LiteralPath $rdfNativeConfig) -and !(Test-Path -LiteralPath $rdfNativeConfig -PathType Leaf)) { throw 'Native editor config path is not a file.' }
$rdfSourceItems = @(Get-ChildItem -LiteralPath $rdfSource -Recurse -Force)
if (@($rdfSourceItems | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
    throw 'Editor mod source contains a link/junction.'
}
$rdfSourceFiles = @($rdfSourceItems | Where-Object { !$_.PSIsContainer } | Sort-Object FullName)
if (!$rdfSourceFiles.Count) { throw 'Editor mod source is empty.' }
$rdfProtectedBefore = @(Get-RdfEditorProtectedState $rdfGame)
$rdfPlan = @()
foreach ($rdfSourceFile in $rdfSourceFiles) {
    $rdfRelative = $rdfSourceFile.FullName.Substring($rdfSource.Length+1)
    if (($rdfRelative -split '[\\/]')[0] -eq '__game') { throw 'The source mod cannot use the reserved __game manifest namespace.' }
    $rdfDestination = [IO.Path]::GetFullPath((Join-Path $rdfTarget $rdfRelative))
    if (!$rdfDestination.StartsWith($rdfTarget+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Source file escaped editor target directory.' }
    Assert-RdfEditorInstallNoLinks $rdfDestination
    if ((Test-Path -LiteralPath $rdfDestination) -and !(Test-Path -LiteralPath $rdfDestination -PathType Leaf)) { throw "Destination is not a file: $rdfRelative" }
    $rdfExisted = Test-Path -LiteralPath $rdfDestination -PathType Leaf
    $rdfPreviousHash = if ($rdfExisted) { (Get-FileHash -LiteralPath $rdfDestination -Algorithm SHA256).Hash } else { $null }
    $rdfPlan += ,[pscustomobject]@{
        Source=$rdfSourceFile.FullName; Destination=$rdfDestination
        GameRelativePath=('mods\RfdEditorSupport\'+$rdfRelative)
        RelativePath=$rdfRelative; Existed=$rdfExisted; PreviousSha256=$rdfPreviousHash
        InstalledSha256=(Get-FileHash -LiteralPath $rdfSourceFile.FullName -Algorithm SHA256).Hash
        BackupRelativePath=('files\'+$rdfRelative)
    }
}
# v2.6.52 exec did not execute mod/cfg in the engine test. Install one exact
# native cfg copy, independently backed up, instead of modifying autoexec or
# any native script. Keep the mod copy for distribution and provenance.
$rdfNativeExisted = Test-Path -LiteralPath $rdfNativeConfig -PathType Leaf
$rdfNativePreviousHash = if ($rdfNativeExisted) { (Get-FileHash -LiteralPath $rdfNativeConfig -Algorithm SHA256).Hash } else { $null }
$rdfPlan += ,[pscustomobject]@{
    Source=$rdfSourceConfig; Destination=$rdfNativeConfig
    RelativePath='__game\platform\cfg\rdf_level_editor.cfg'; GameRelativePath='platform\cfg\rdf_level_editor.cfg'
    Existed=$rdfNativeExisted; PreviousSha256=$rdfNativePreviousHash
    InstalledSha256=(Get-FileHash -LiteralPath $rdfSourceConfig -Algorithm SHA256).Hash
    BackupRelativePath='files\__game\platform\cfg\rdf_level_editor.cfg'
}

$rdfBackupParent = Join-Path $PSScriptRoot 'backups'
New-Item -ItemType Directory -Path $rdfBackupParent -Force | Out-Null
$rdfInstallId = (Get-Date -Format 'yyyyMMdd-HHmmss')+'-install-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$rdfBackupRoot = Join-Path $rdfBackupParent $rdfInstallId
New-Item -ItemType Directory -Path $rdfBackupRoot | Out-Null
$rdfManifestPath = Join-Path $rdfBackupRoot 'install.json'
$rdfManifest = [ordered]@{
    Schema=1; ToolId='rfd-editor-install'; InstallId=$rdfInstallId
    CreatedUtc=[DateTime]::UtcNow.ToString('o'); GameRoot=$rdfGame; TargetRoot=$rdfTarget; SourceRoot=$rdfSource
    TargetExisted=(Test-Path -LiteralPath $rdfTarget); Completed=$false; Restored=$false
    SaveDirectory=$rdfSaves; SaveDirectoryCreated=$false; Files=@(); Protected=$rdfProtectedBefore
}
function Save-RdfEditorInstallManifest {
    $rdfManifest | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $rdfManifestPath -Encoding UTF8
}
foreach ($rdfFile in $rdfPlan) {
    $rdfManifest.Files += ,[ordered]@{
        RelativePath=$rdfFile.RelativePath; GameRelativePath=$rdfFile.GameRelativePath; Existed=$rdfFile.Existed; PreviousSha256=$rdfFile.PreviousSha256
        InstalledSha256=$rdfFile.InstalledSha256; BackupRelativePath=$rdfFile.BackupRelativePath
    }
}
Save-RdfEditorInstallManifest

try {
    # Back up the entire overwrite set before the first game-file modification.
    foreach ($rdfFile in $rdfPlan) {
        if (!$rdfFile.Existed) { continue }
        $rdfBackupFile = Join-Path $rdfBackupRoot $rdfFile.BackupRelativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $rdfBackupFile) -Force | Out-Null
        Copy-Item -LiteralPath $rdfFile.Destination -Destination $rdfBackupFile
        if ((Get-FileHash -LiteralPath $rdfBackupFile -Algorithm SHA256).Hash -ne $rdfFile.PreviousSha256) {
            throw "Backup changed during installation: $($rdfFile.RelativePath)"
        }
    }
    if (Get-Process r5apex,r5apex_ds -ErrorAction SilentlyContinue) { throw 'R5R started during preflight. Editor files were not installed.' }
    foreach ($rdfFile in $rdfPlan) {
        $rdfCurrentExists = Test-Path -LiteralPath $rdfFile.Destination -PathType Leaf
        $rdfCurrentHash = if ($rdfCurrentExists) { (Get-FileHash -LiteralPath $rdfFile.Destination -Algorithm SHA256).Hash } else { $null }
        if ($rdfCurrentExists -ne $rdfFile.Existed -or $rdfCurrentHash -ne $rdfFile.PreviousSha256 -or
            (Get-FileHash -LiteralPath $rdfFile.Source -Algorithm SHA256).Hash -ne $rdfFile.InstalledSha256) {
            throw 'A source/destination changed during preflight. Nothing should overwrite it.'
        }
    }
    foreach ($rdfFile in $rdfPlan) {
        Assert-RdfEditorInstallNoLinks $rdfFile.Destination
        New-Item -ItemType Directory -Path (Split-Path -Parent $rdfFile.Destination) -Force | Out-Null
        # Stage beside the destination, verify bytes, then atomically replace or
        # move. A failed copy must not leave an existing script half-written.
        $rdfTemp = Join-Path (Split-Path -Parent $rdfFile.Destination) ('.rfd-editor-'+[guid]::NewGuid().ToString('N')+'.tmp')
        if (Test-Path -LiteralPath $rdfTemp) { throw 'Unique staging path unexpectedly exists.' }
        try {
            Copy-Item -LiteralPath $rdfFile.Source -Destination $rdfTemp
            if ((Get-FileHash -LiteralPath $rdfTemp -Algorithm SHA256).Hash -ne $rdfFile.InstalledSha256) { throw 'Editor staging hash mismatch.' }
            if ($rdfFile.Existed) {
                if ((Get-FileHash -LiteralPath $rdfFile.Destination -Algorithm SHA256).Hash -ne $rdfFile.PreviousSha256) { throw 'Destination changed before replacement.' }
                # A nonempty backup path also works on PowerShell runtimes
                # that marshal a null string to an invalid empty path.
                $rdfAtomicBackup = Join-Path (Split-Path -Parent $rdfManifestPath) ('atomic-old-' + [guid]::NewGuid().ToString('N') + '.bak')
                [IO.File]::Replace($rdfTemp,$rdfFile.Destination,$rdfAtomicBackup)
            } else {
                [IO.File]::Move($rdfTemp,$rdfFile.Destination)
            }
        } finally {
            # Only this unique, newly created staging file can be removed.
            if (Test-Path -LiteralPath $rdfTemp -PathType Leaf) { Remove-Item -LiteralPath $rdfTemp }
        }
        if ((Get-FileHash -LiteralPath $rdfFile.Destination -Algorithm SHA256).Hash -ne $rdfFile.InstalledSha256) { throw 'Installed editor file hash mismatch.' }
    }
    if (!(Test-Path -LiteralPath $rdfSaves -PathType Container)) {
        New-Item -ItemType Directory -Path $rdfSaves | Out-Null
        $rdfManifest.SaveDirectoryCreated = $true
    }
    New-Item -ItemType Directory -Path (Join-Path $rdfGame 'platform\cfg\rfd_editor_saves') -Force | Out-Null
    $rdfProtectedAfter = @(Get-RdfEditorProtectedState $rdfGame)
    for ($rdfIndex=0; $rdfIndex -lt $rdfProtectedBefore.Count; $rdfIndex++) {
        if ($rdfProtectedBefore[$rdfIndex].Sha256 -ne $rdfProtectedAfter[$rdfIndex].Sha256 -or $rdfProtectedBefore[$rdfIndex].Existed -ne $rdfProtectedAfter[$rdfIndex].Existed) {
            throw "Protected file changed during install: $($rdfProtectedBefore[$rdfIndex].Path). It was not written by this tool."
        }
    }
    $rdfManifest.Completed = $true
    Save-RdfEditorInstallManifest
} catch {
    $rdfManifest.Error = $_.Exception.Message
    Save-RdfEditorInstallManifest
    throw "Editor install did not complete. Preserve backup manifest $rdfManifestPath. $($_.Exception.Message)"
}
[pscustomobject]@{
    Status='Installed and SHA256 verified; engine test still required'
    Manifest=$rdfManifestPath; GameRoot=$rdfGame; Target=$rdfTarget; FileCount=$rdfPlan.Count; SaveDirectory=$rdfSaves
    ProtectedFilesUnchanged=$true
    Note='Installed the independent editor mod plus its one native exec cfg. Native scripts, existing gameplay patches and mods.vdf were not written.'
}
