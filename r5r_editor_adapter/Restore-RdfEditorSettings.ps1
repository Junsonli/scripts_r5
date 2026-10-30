[CmdletBinding()]
param([Parameter(Mandatory)][string]$Manifest)
$ErrorActionPreference = 'Stop'

function Assert-RdfEditorNoLinks([string]$Path) {
    $rdfProbe = [IO.Path]::GetFullPath($Path)
    while ($rdfProbe) {
        if ((Test-Path -LiteralPath $rdfProbe) -and ((Get-Item -LiteralPath $rdfProbe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to follow link/junction: $rdfProbe"
        }
        $rdfParent = Split-Path -Parent $rdfProbe
        if ($rdfParent -eq $rdfProbe) { break }
        $rdfProbe = $rdfParent
    }
}

function Convert-RdfEditorUtc($Value) {
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    return [DateTime]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

$rdfManifestPath = (Resolve-Path -LiteralPath $Manifest).Path
Assert-RdfEditorNoLinks $rdfManifestPath
$rdfBackupRoot = Split-Path -Parent $rdfManifestPath
$rdfExpectedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'backups')).TrimEnd('\')
if (!$rdfBackupRoot.StartsWith($rdfExpectedRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $rdfManifestPath) -ne 'manifest.json') {
    throw 'Manifest must be an editor profile manifest inside this tool backups directory.'
}
$rdfData = Get-Content -LiteralPath $rdfManifestPath -Raw | ConvertFrom-Json
if ($rdfData.Schema -ne 1 -or $rdfData.ToolId -ne 'rfd-level-editor-profile' -or !$rdfData.BackupComplete) {
    throw 'Unrecognized or incomplete editor settings backup.'
}
if ($rdfData.Restored) { throw 'This editor settings backup has already been restored.' }
$rdfUserProfile = [Environment]::GetFolderPath('UserProfile')
if (![IO.Path]::GetFullPath([string]$rdfData.UserProfile).TrimEnd('\').Equals($rdfUserProfile.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) {
    throw 'This backup belongs to a different Windows user profile.'
}

# Never use a saved PID to stop a process. Verify its birth time to distinguish
# the original editor from PID reuse, then reject any still-running R5R process.
$rdfOriginalSessionRunning = $false
if ($rdfData.ProcessId -and $rdfData.ProcessStartTimeUtc) {
    $rdfRecordedProcess = Get-Process -Id ([int]$rdfData.ProcessId) -ErrorAction SilentlyContinue
    if ($rdfRecordedProcess -and $rdfRecordedProcess.ProcessName -eq 'r5apex') {
        $rdfRecordedUtc = Convert-RdfEditorUtc $rdfData.ProcessStartTimeUtc
        $rdfOriginalSessionRunning = $rdfRecordedProcess.StartTime.ToUniversalTime().Ticks -eq $rdfRecordedUtc.Ticks
    }
}
if ($rdfOriginalSessionRunning) { throw 'The recorded editor session is still running. Exit it before restoring settings.' }
if (Get-Process r5apex,r5apex_ds -ErrorAction SilentlyContinue) {
    throw 'Close all R5R game/server processes before restoring settings. No process was stopped.'
}

# Restoring nested editing sessions out of order can overwrite a newer baseline.
$rdfCreatedUtc = Convert-RdfEditorUtc $rdfData.CreatedUtc
foreach ($rdfOther in Get-ChildItem -LiteralPath $rdfExpectedRoot -Directory) {
    $rdfOtherManifest = Join-Path $rdfOther.FullName 'manifest.json'
    if ($rdfOtherManifest -eq $rdfManifestPath -or !(Test-Path -LiteralPath $rdfOtherManifest -PathType Leaf)) { continue }
    Assert-RdfEditorNoLinks $rdfOtherManifest
    $rdfOtherData = Get-Content -LiteralPath $rdfOtherManifest -Raw | ConvertFrom-Json
    if ($rdfOtherData.ToolId -eq 'rfd-level-editor-profile' -and $rdfOtherData.BackupComplete -and !$rdfOtherData.Restored -and
        [string]$rdfOtherData.UserProfile -eq [string]$rdfData.UserProfile -and (Convert-RdfEditorUtc $rdfOtherData.CreatedUtc) -gt $rdfCreatedUtc) {
        throw "Restore newer editor settings backups first: $rdfOtherManifest"
    }
}

$rdfOperations = @()
$rdfSeen = @{}
foreach ($rdfEntry in @($rdfData.Files)) {
    if ($rdfEntry.ProfileName -notin @('Apex_fnf','Apex') -or $rdfSeen.ContainsKey([string]$rdfEntry.ProfileName)) {
        throw 'Unexpected or duplicate profile entry.'
    }
    $rdfSeen[[string]$rdfEntry.ProfileName] = $true
    $rdfExpectedSettings = Join-Path $rdfUserProfile ('Saved Games\Respawn\'+$rdfEntry.ProfileName+'\local\settings.cfg')
    $rdfDestination = [IO.Path]::GetFullPath([string]$rdfEntry.Path)
    $rdfRelativeBackup = 'files\'+$rdfEntry.ProfileName+'\settings.cfg'
    if (!$rdfDestination.Equals($rdfExpectedSettings,[StringComparison]::OrdinalIgnoreCase) -or $rdfEntry.BackupRelativePath -ne $rdfRelativeBackup) {
        throw 'The manifest may only restore the two exact saved-game settings.cfg paths.'
    }
    Assert-RdfEditorNoLinks $rdfDestination
    if ((Test-Path -LiteralPath $rdfDestination) -and !(Test-Path -LiteralPath $rdfDestination -PathType Leaf)) {
        throw "Settings destination is not a file: $rdfDestination"
    }
    $rdfBackup = Join-Path $rdfBackupRoot $rdfRelativeBackup
    if ($rdfEntry.Existed) {
        Assert-RdfEditorNoLinks $rdfBackup
        if ($rdfEntry.BeforeSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or !(Test-Path -LiteralPath $rdfBackup -PathType Leaf) -or
            (Get-FileHash -LiteralPath $rdfBackup -Algorithm SHA256).Hash -ne $rdfEntry.BeforeSha256) {
            throw "Backup is missing or changed: $($rdfEntry.ProfileName)"
        }
    }
    $rdfCurrentExists = Test-Path -LiteralPath $rdfDestination -PathType Leaf
    $rdfCurrentHash = if ($rdfCurrentExists) { (Get-FileHash -LiteralPath $rdfDestination -Algorithm SHA256).Hash } else { $null }
    $rdfOperations += ,[pscustomobject]@{ Entry=$rdfEntry; Destination=$rdfDestination; Backup=$rdfBackup; CurrentExists=$rdfCurrentExists; CurrentSha256=$rdfCurrentHash }
}
if ($rdfOperations.Count -ne 2) { throw 'The complete two-profile backup manifest is required.' }

# Archive the *current* settings before restoring either destination. These may
# contain the user's intended editor binds and must remain independently usable.
$rdfSnapshotId = 'pre-restore-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$rdfSnapshotRoot = Join-Path $rdfBackupRoot $rdfSnapshotId
New-Item -ItemType Directory -Path $rdfSnapshotRoot | Out-Null
$rdfSnapshotFiles = @()
foreach ($rdfOperation in $rdfOperations) {
    $rdfSnapshotRelative = 'files\'+$rdfOperation.Entry.ProfileName+'\settings.cfg'
    if ($rdfOperation.CurrentExists) {
        $rdfSnapshotFile = Join-Path $rdfSnapshotRoot $rdfSnapshotRelative
        New-Item -ItemType Directory -Path (Split-Path -Parent $rdfSnapshotFile) -Force | Out-Null
        Copy-Item -LiteralPath $rdfOperation.Destination -Destination $rdfSnapshotFile
        if ((Get-FileHash -LiteralPath $rdfSnapshotFile -Algorithm SHA256).Hash -ne $rdfOperation.CurrentSha256) {
            throw 'Current settings changed during preservation; nothing was restored.'
        }
    }
    $rdfSnapshotFiles += ,[ordered]@{ ProfileName=$rdfOperation.Entry.ProfileName; Path=$rdfOperation.Destination; Existed=$rdfOperation.CurrentExists; Sha256=$rdfOperation.CurrentSha256; BackupRelativePath=$rdfSnapshotRelative }
}
$rdfSnapshotManifest = Join-Path $rdfSnapshotRoot 'snapshot.json'
[ordered]@{ Schema=1; ToolId='rfd-editor-settings-pre-restore'; CreatedUtc=[DateTime]::UtcNow.ToString('o'); SourceManifest=$rdfManifestPath; Files=$rdfSnapshotFiles } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $rdfSnapshotManifest -Encoding UTF8

# Final whole-batch race check immediately before the first overwrite.
if (Get-Process r5apex,r5apex_ds -ErrorAction SilentlyContinue) { throw 'R5R started during preflight; nothing was restored.' }
foreach ($rdfOperation in $rdfOperations) {
    Assert-RdfEditorNoLinks $rdfOperation.Destination
    $rdfExistsNow = Test-Path -LiteralPath $rdfOperation.Destination -PathType Leaf
    $rdfHashNow = if ($rdfExistsNow) { (Get-FileHash -LiteralPath $rdfOperation.Destination -Algorithm SHA256).Hash } else { $null }
    if ($rdfExistsNow -ne $rdfOperation.CurrentExists -or $rdfHashNow -ne $rdfOperation.CurrentSha256) {
        throw 'Settings changed during restore preflight; preserved snapshot retained and nothing was restored.'
    }
}
$rdfRestoredCount = 0
foreach ($rdfOperation in $rdfOperations) {
    # If the game created a profile that did not exist before launch, preserve it
    # as-is. The tool never deletes a settings file or invents replacement binds.
    if (!$rdfOperation.Entry.Existed) { continue }
    New-Item -ItemType Directory -Path (Split-Path -Parent $rdfOperation.Destination) -Force | Out-Null
    Copy-Item -LiteralPath $rdfOperation.Backup -Destination $rdfOperation.Destination -Force
    if ((Get-FileHash -LiteralPath $rdfOperation.Destination -Algorithm SHA256).Hash -ne $rdfOperation.Entry.BeforeSha256) {
        throw "Restored hash mismatch. Current-before-restore settings remain in $rdfSnapshotManifest"
    }
    $rdfRestoredCount++
}
$rdfData.Restored = $true
$rdfData | Add-Member -NotePropertyName RestoredUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
$rdfData | Add-Member -NotePropertyName PreRestoreSnapshot -NotePropertyValue $rdfSnapshotManifest -Force
$rdfData | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $rdfManifestPath -Encoding UTF8
[pscustomobject]@{ Status='Restored'; ProfilesRestored=$rdfRestoredCount; Manifest=$rdfManifestPath; PreservedEditorSettings=$rdfSnapshotManifest; Note='Settings bytes restored after exit; profiles absent before editing were preserved, never deleted.' }
