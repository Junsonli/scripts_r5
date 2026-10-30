[CmdletBinding()]
param([Parameter(Mandatory)][string]$Manifest)
$ErrorActionPreference = 'Stop'

function Assert-RdfEditorRestoreNoLinks([string]$Path) {
    $rdfProbe = [IO.Path]::GetFullPath($Path)
    while ($rdfProbe) {
        if ((Test-Path -LiteralPath $rdfProbe) -and ((Get-Item -LiteralPath $rdfProbe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Editor restore does not follow links/junctions: $rdfProbe"
        }
        $rdfParent = Split-Path -Parent $rdfProbe
        if ($rdfParent -eq $rdfProbe) { break }
        $rdfProbe = $rdfParent
    }
}

function Get-RdfEditorRestoreProtectedState([string]$Root) {
    foreach ($rdfRelative in @(
        'platform\scripts\vscripts\mp\_base_gametype.gnut',
        'platform\scripts\vscripts\gamemodes\survival\_gamemode_survival.nut',
        'platform\scripts\vscripts\scripts.rson',
        'mods\mods.vdf'
    )) {
        $rdfPath = Join-Path $Root $rdfRelative
        Assert-RdfEditorRestoreNoLinks $rdfPath
        if ((Test-Path -LiteralPath $rdfPath) -and !(Test-Path -LiteralPath $rdfPath -PathType Leaf)) { throw "Protected path is not a file: $rdfRelative" }
        $rdfExists = Test-Path -LiteralPath $rdfPath -PathType Leaf
        $rdfHash = if ($rdfExists) { (Get-FileHash -LiteralPath $rdfPath -Algorithm SHA256).Hash } else { $null }
        [pscustomobject]@{Path=$rdfRelative;Existed=$rdfExists;Sha256=$rdfHash}
    }
}

if (Get-Process r5apex,r5apex_ds -ErrorAction SilentlyContinue) {
    throw 'Close the R5R game and dedicated server before restoring editor files. No process was stopped.'
}
$rdfManifestPath = (Resolve-Path -LiteralPath $Manifest).Path
Assert-RdfEditorRestoreNoLinks $rdfManifestPath
$rdfBackupRoot = Split-Path -Parent $rdfManifestPath
$rdfExpectedBackups = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'backups')).TrimEnd('\')
if (!$rdfBackupRoot.StartsWith($rdfExpectedBackups+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $rdfManifestPath) -ne 'install.json') {
    throw 'Use an install.json from this editor tool backups directory.'
}
$rdfData = Get-Content -LiteralPath $rdfManifestPath -Raw | ConvertFrom-Json
if ($rdfData.Schema -ne 1 -or $rdfData.ToolId -ne 'rfd-editor-install') { throw 'Unrecognized editor installation manifest.' }
if ($rdfData.Restored) { throw 'This editor installation has already been restored.' }
$rdfGame = [IO.Path]::GetFullPath([string]$rdfData.GameRoot).TrimEnd('\')
$rdfTarget = [IO.Path]::GetFullPath([string]$rdfData.TargetRoot).TrimEnd('\')
$rdfExpectedTarget = [IO.Path]::GetFullPath((Join-Path $rdfGame 'mods\RfdEditorSupport')).TrimEnd('\')
if (!$rdfTarget.Equals($rdfExpectedTarget,[StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest target must be exactly GameRoot/mods/RfdEditorSupport.' }
Assert-RdfEditorRestoreNoLinks $rdfTarget
$rdfProtectedBefore = @(Get-RdfEditorRestoreProtectedState $rdfGame)

$rdfOperations = @()
$rdfSeen = @{}
$rdfEmptyCandidates = @{}
foreach ($rdfEntry in @($rdfData.Files)) {
    $rdfRelative = [string]$rdfEntry.RelativePath
    if ([string]::IsNullOrWhiteSpace($rdfRelative) -or [IO.Path]::IsPathRooted($rdfRelative) -or $rdfRelative.Contains(':') -or
        @($rdfRelative -split '[\\/]' | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_ -eq '' }).Count -gt 0) {
        throw 'Manifest contains an invalid relative editor path.'
    }
    $rdfNativeConfigEntry = $rdfRelative -eq '__game\platform\cfg\rdf_level_editor.cfg'
    if ($rdfNativeConfigEntry) {
        $rdfExpectedGameRelative = 'platform\cfg\rdf_level_editor.cfg'
        $rdfDestination = [IO.Path]::GetFullPath((Join-Path $rdfGame $rdfExpectedGameRelative))
    } else {
        if ($rdfRelative -like '__game\*') { throw 'The manifest may only include the one exact native editor cfg outside the mod.' }
        $rdfExpectedGameRelative = 'mods\RfdEditorSupport\'+$rdfRelative
        $rdfDestination = [IO.Path]::GetFullPath((Join-Path $rdfTarget $rdfRelative))
    }
    if ($rdfEntry.PSObject.Properties.Name -contains 'GameRelativePath' -and $rdfEntry.GameRelativePath -ne $rdfExpectedGameRelative) {
        throw 'Unexpected game-relative editor destination.'
    }
    if ((!$rdfNativeConfigEntry -and !$rdfDestination.StartsWith($rdfTarget+'\',[StringComparison]::OrdinalIgnoreCase)) -or $rdfSeen.ContainsKey($rdfDestination)) {
        throw 'Manifest path escaped the editor mod, or was listed twice.'
    }
    $rdfSeen[$rdfDestination] = $true
    Assert-RdfEditorRestoreNoLinks $rdfDestination
    if ((Test-Path -LiteralPath $rdfDestination) -and !(Test-Path -LiteralPath $rdfDestination -PathType Leaf)) { throw "Editor destination is not a file: $rdfRelative" }
    if ($rdfEntry.InstalledSha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Installed editor hash is missing or invalid.' }
    $rdfExpectedRelativeBackup = 'files\'+$rdfRelative
    if ($rdfEntry.PSObject.Properties.Name -contains 'BackupRelativePath' -and $rdfEntry.BackupRelativePath -ne $rdfExpectedRelativeBackup) {
        throw 'Unexpected editor backup path.'
    }
    $rdfBackup = [IO.Path]::GetFullPath((Join-Path $rdfBackupRoot $rdfExpectedRelativeBackup))
    if (!$rdfBackup.StartsWith($rdfBackupRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Backup escaped this installation directory.' }
    $rdfExists = Test-Path -LiteralPath $rdfDestination -PathType Leaf
    $rdfCurrentHash = if ($rdfExists) { (Get-FileHash -LiteralPath $rdfDestination -Algorithm SHA256).Hash } else { $null }
    if ($rdfEntry.Existed) {
        Assert-RdfEditorRestoreNoLinks $rdfBackup
        if ($rdfEntry.PreviousSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or !(Test-Path -LiteralPath $rdfBackup -PathType Leaf) -or
            (Get-FileHash -LiteralPath $rdfBackup -Algorithm SHA256).Hash -ne $rdfEntry.PreviousSha256) {
            throw "Editor backup is missing or changed: $rdfRelative"
        }
        if ($rdfExists -and $rdfCurrentHash -ne $rdfEntry.InstalledSha256 -and $rdfCurrentHash -ne $rdfEntry.PreviousSha256) {
            throw "Editor file changed after installation; refusing overwrite: $rdfRelative"
        }
    } elseif ($rdfExists -and $rdfCurrentHash -ne $rdfEntry.InstalledSha256) {
        throw "New editor file changed after installation; refusing deletion: $rdfRelative"
    }
    $rdfOperations += ,[pscustomobject]@{Entry=$rdfEntry;Destination=$rdfDestination;Backup=$rdfBackup;Exists=$rdfExists;CurrentSha256=$rdfCurrentHash}
    $rdfDirectory = Split-Path -Parent $rdfDestination
    while ($rdfDirectory -and $rdfDirectory.StartsWith($rdfTarget+'\',[StringComparison]::OrdinalIgnoreCase)) {
        $rdfEmptyCandidates[$rdfDirectory] = $true
        $rdfDirectory = Split-Path -Parent $rdfDirectory
    }
}
if (!$rdfOperations.Count) { throw 'The installation manifest has no file entries.' }
if (Get-Process r5apex,r5apex_ds -ErrorAction SilentlyContinue) { throw 'R5R started during restore preflight; no editor files were changed.' }
# Check every destination once more before restoring the first file.
foreach ($rdfOperation in $rdfOperations) {
    Assert-RdfEditorRestoreNoLinks $rdfOperation.Destination
    $rdfExistsNow = Test-Path -LiteralPath $rdfOperation.Destination -PathType Leaf
    $rdfHashNow = if ($rdfExistsNow) { (Get-FileHash -LiteralPath $rdfOperation.Destination -Algorithm SHA256).Hash } else { $null }
    if ($rdfExistsNow -ne $rdfOperation.Exists -or $rdfHashNow -ne $rdfOperation.CurrentSha256) { throw 'Editor files changed during preflight; nothing was restored.' }
}
foreach ($rdfOperation in $rdfOperations) {
    if ($rdfOperation.Entry.Existed) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $rdfOperation.Destination) -Force | Out-Null
        Copy-Item -LiteralPath $rdfOperation.Backup -Destination $rdfOperation.Destination -Force
        if ((Get-FileHash -LiteralPath $rdfOperation.Destination -Algorithm SHA256).Hash -ne $rdfOperation.Entry.PreviousSha256) { throw 'Restored editor hash mismatch.' }
    } elseif ($rdfOperation.Exists) {
        Remove-Item -LiteralPath $rdfOperation.Destination
    }
}
# Do not recurse-delete. Only remove known, now-empty directories beneath this
# one support mod; untracked files, native cfg directories and all
# rfd_editor_saves contents are retained.
foreach ($rdfDirectory in @($rdfEmptyCandidates.Keys | Sort-Object Length -Descending)) {
    Assert-RdfEditorRestoreNoLinks $rdfDirectory
    if ((Test-Path -LiteralPath $rdfDirectory -PathType Container) -and !(Get-ChildItem -LiteralPath $rdfDirectory -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $rdfDirectory
    }
}
if (!$rdfData.TargetExisted -and (Test-Path -LiteralPath $rdfTarget -PathType Container) -and !(Get-ChildItem -LiteralPath $rdfTarget -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $rdfTarget
}
$rdfProtectedAfter = @(Get-RdfEditorRestoreProtectedState $rdfGame)
for ($rdfIndex=0; $rdfIndex -lt $rdfProtectedBefore.Count; $rdfIndex++) {
    if ($rdfProtectedBefore[$rdfIndex].Sha256 -ne $rdfProtectedAfter[$rdfIndex].Sha256 -or $rdfProtectedBefore[$rdfIndex].Existed -ne $rdfProtectedAfter[$rdfIndex].Existed) {
        throw "A protected file changed during restore: $($rdfProtectedBefore[$rdfIndex].Path). This tool did not write it."
    }
}
$rdfData | Add-Member -NotePropertyName Restored -NotePropertyValue $true -Force
$rdfData | Add-Member -NotePropertyName RestoredUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
$rdfData | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $rdfManifestPath -Encoding UTF8
[pscustomobject]@{
    Status='Restored'; Manifest=$rdfManifestPath; Target=$rdfTarget; Files=$rdfOperations.Count
    SaveDirectory=(Join-Path $rdfGame 'platform\rfd_editor_saves'); ProtectedFilesUnchanged=$true
    Note='User saves are retained. Only the independent mod and its one native editor cfg were restored; native scripts, existing gameplay patches and mods.vdf were not written.'
}
