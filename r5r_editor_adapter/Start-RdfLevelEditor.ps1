[CmdletBinding()]
param(
    [string]$GameRoot,
    [string]$Map = 'mp_rr_arena_phase_runner',
    [ValidateRange(1024,65535)][int]$HostPort = 37015,
    [switch]$VerifyLoad
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

function Assert-RdfEditorNoLinks([string]$Path) {
    $rdfProbe = [IO.Path]::GetFullPath($Path)
    while ($rdfProbe) {
        if ((Test-Path -LiteralPath $rdfProbe) -and ((Get-Item -LiteralPath $rdfProbe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Links/junctions are not supported for editor profile files: $rdfProbe"
        }
        $rdfParent = Split-Path -Parent $rdfProbe
        if ($rdfParent -eq $rdfProbe) { break }
        $rdfProbe = $rdfParent
    }
}

if (Get-Process r5apex,r5apex_ds -ErrorAction SilentlyContinue) {
    throw 'Close the existing R5R game and dedicated server before starting the editor. Nothing was stopped.'
}
$rdfGame = Resolve-RdfEditorGameRoot $GameRoot
$rdfBuild = Join-Path $rdfGame 'build.txt'
if (!(Test-Path -LiteralPath $rdfBuild -PathType Leaf) -or ([IO.File]::ReadAllText($rdfBuild).Trim() -ne 'R5R-v2.6.52')) {
    throw 'This editor profile requires build.txt to identify R5R-v2.6.52.'
}
if (!(Test-Path -LiteralPath (Join-Path $rdfGame 'r5apex.exe') -PathType Leaf)) {
    throw 'The selected LIVE directory has no r5apex.exe.'
}
if ($Map -notmatch '^[A-Za-z0-9_]+$') { throw 'Map must be a simple map identifier.' }
$rdfPlaylistFile = Join-Path $rdfGame 'platform\playlists_r5_patch.txt'
$rdfDevConfig = Join-Path $rdfGame 'platform\cfg\system\autoexec_dev.cfg'
if (!(Test-Path -LiteralPath $rdfPlaylistFile -PathType Leaf) -or !(Test-Path -LiteralPath $rdfDevConfig -PathType Leaf)) {
    throw 'The native playlists_r5_patch.txt or system/autoexec_dev.cfg is missing.'
}

# Native exec on this build must prefer platform/cfg. A copy inside mod/cfg is
# retained as source/package data, but it does not shadow the native exec file.
# Only fall back to a single mod copy when the native file is entirely absent.
$rdfConfigs = @()
$rdfNativeConfig = Join-Path $rdfGame 'platform\cfg\rdf_level_editor.cfg'
if ((Test-Path -LiteralPath $rdfNativeConfig) -and !(Test-Path -LiteralPath $rdfNativeConfig -PathType Leaf)) {
    throw 'The platform/cfg/rdf_level_editor.cfg path exists but is not a file.'
}
if (Test-Path -LiteralPath $rdfNativeConfig -PathType Leaf) {
    $rdfConfigs += $rdfNativeConfig
} else {
    $rdfMods = Join-Path $rdfGame 'mods'
    if (Test-Path -LiteralPath $rdfMods -PathType Container) {
        foreach ($rdfMod in Get-ChildItem -LiteralPath $rdfMods -Directory -Force) {
            $rdfModConfig = Join-Path $rdfMod.FullName 'cfg\rdf_level_editor.cfg'
            if (Test-Path -LiteralPath $rdfModConfig -PathType Leaf) { $rdfConfigs += $rdfModConfig }
        }
    }
}
if ($rdfConfigs.Count -ne 1) {
    throw 'Install platform/cfg/rdf_level_editor.cfg, or exactly one mod fallback copy, before starting. No files were changed.'
}
Assert-RdfEditorNoLinks $rdfConfigs[0]

$rdfUserProfile = [Environment]::GetFolderPath('UserProfile')
$rdfSavedGames = Join-Path $rdfUserProfile 'Saved Games\Respawn'
$rdfBackups = Join-Path $PSScriptRoot 'backups'
Assert-RdfEditorNoLinks $rdfBackups
New-Item -ItemType Directory -Path $rdfBackups -Force | Out-Null
$rdfSessionId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$rdfBackupRoot = Join-Path $rdfBackups $rdfSessionId
New-Item -ItemType Directory -Path $rdfBackupRoot | Out-Null
$rdfManifestPath = Join-Path $rdfBackupRoot 'manifest.json'
$rdfManifest = [ordered]@{
    Schema = 1; ToolId = 'rfd-level-editor-profile'; SessionId = $rdfSessionId
    CreatedUtc = [DateTime]::UtcNow.ToString('o'); UserProfile = $rdfUserProfile
    GameRoot = $rdfGame; Map = $Map; Config = $rdfConfigs[0]
    ConfigSha256 = (Get-FileHash -LiteralPath $rdfConfigs[0] -Algorithm SHA256).Hash
    BackupComplete = $false; Launched = $false; Restored = $false
    ProcessId = $null; ProcessStartTimeUtc = $null; RunStartedUtc = $null
    RunFile = $null; Files = @()
}
function Save-RdfEditorProfileManifest {
    $rdfManifest | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $rdfManifestPath -Encoding UTF8
}
Save-RdfEditorProfileManifest

foreach ($rdfProfileName in @('Apex_fnf','Apex')) {
    $rdfSettings = Join-Path $rdfSavedGames ($rdfProfileName + '\local\settings.cfg')
    Assert-RdfEditorNoLinks $rdfSettings
    if ((Test-Path -LiteralPath $rdfSettings) -and !(Test-Path -LiteralPath $rdfSettings -PathType Leaf)) {
        throw "Settings path is not a file: $rdfSettings"
    }
    $rdfExists = Test-Path -LiteralPath $rdfSettings -PathType Leaf
    $rdfRelativeBackup = 'files\' + $rdfProfileName + '\settings.cfg'
    $rdfBeforeHash = $null
    if ($rdfExists) {
        $rdfBeforeHash = (Get-FileHash -LiteralPath $rdfSettings -Algorithm SHA256).Hash
        $rdfBackupFile = Join-Path $rdfBackupRoot $rdfRelativeBackup
        New-Item -ItemType Directory -Path (Split-Path -Parent $rdfBackupFile) -Force | Out-Null
        Copy-Item -LiteralPath $rdfSettings -Destination $rdfBackupFile
        if ((Get-FileHash -LiteralPath $rdfBackupFile -Algorithm SHA256).Hash -ne $rdfBeforeHash -or
            (Get-FileHash -LiteralPath $rdfSettings -Algorithm SHA256).Hash -ne $rdfBeforeHash) {
            throw 'Settings changed during backup. The game was not started; keep the backup manifest.'
        }
    }
    $rdfManifest.Files += ,[ordered]@{ ProfileName=$rdfProfileName; Path=$rdfSettings; Existed=$rdfExists; BeforeSha256=$rdfBeforeHash; BackupRelativePath=$rdfRelativeBackup }
    Save-RdfEditorProfileManifest
}
$rdfManifest.BackupComplete = $true
Save-RdfEditorProfileManifest

# Self-contained launcher: this portable editor does not require the gameplay
# Mod's tools, RCON credentials, a helper server or another PowerShell script.
# -launcher prevents native startup_default from adding a competing playlist;
# -fnf explicitly selects the Saved Games profile backed up above. The remaining
# development arguments preserve the locally tested in-game editor environment.
$rdfRuntime = Join-Path $PSScriptRoot 'runtime'
Assert-RdfEditorNoLinks $rdfRuntime
New-Item -ItemType Directory -Path $rdfRuntime -Force | Out-Null
$rdfRunFile = Join-Path $rdfRuntime ($rdfSessionId+'-run.json')
$rdfLogRoot = Join-Path $rdfGame 'platform\logs'
$rdfPreviousLogs = @(if (Test-Path -LiteralPath $rdfLogRoot -PathType Container) {
    Get-ChildItem -LiteralPath $rdfLogRoot -Directory | ForEach-Object { $_.Name }
})
$rdfRun = [ordered]@{
    RunId=$rdfSessionId; StartedUtc=[DateTime]::UtcNow.ToString('o'); Role='LevelEditor'
    GameRoot=$rdfGame; Map=$Map; Playlist='survival_dev'; PlaylistFile='playlists_r5_patch.txt'
    HostPort=$HostPort; LogRoot=$rdfLogRoot; PreviousLogSessions=$rdfPreviousLogs
    BackupManifest=$rdfManifestPath; ProcessId=$null; ProcessStartTimeUtc=$null; LogSession=$null
}
$rdfRun | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $rdfRunFile -Encoding UTF8
$rdfEditorArguments = @(
    '-launcher','-fnf','-dev','-devsdk','-offline','-novid','-showdevmenu','-multiple',
    '-windowed','-w','1280','-h','720','-playlistfile','playlists_r5_patch.txt',
    '+exec','system/autoexec_dev.cfg','+hostport',"$HostPort",
    '+script_show_output','1','+script_show_warning','1',
    '+map',$Map,'+launchplaylist','survival_dev',
    '+rfd_editor_enabled','1','+rfd_editor_selftest',$(if($VerifyLoad){'1'}else{'0'}),
    '+exec','rdf_level_editor.cfg'
)
try {
    if (Get-Process r5apex,r5apex_ds -ErrorAction SilentlyContinue) { throw 'R5R started during profile backup. No second process was launched.' }
    # Visible interactive window is intentional: this is the user's editor.
    $rdfEditorProcess = Start-Process -FilePath (Join-Path $rdfGame 'r5apex.exe') -WorkingDirectory $rdfGame -ArgumentList $rdfEditorArguments -PassThru
    $rdfRun.ProcessId = $rdfEditorProcess.Id
    $rdfManifest.RunFile = $rdfRunFile
    $rdfManifest.ProcessId = $rdfEditorProcess.Id
    $rdfManifest.RunStartedUtc = $rdfRun.StartedUtc
    $rdfLiveProcess = Get-Process -Id $rdfManifest.ProcessId -ErrorAction SilentlyContinue
    if ($rdfLiveProcess -and $rdfLiveProcess.ProcessName -eq 'r5apex') {
        $rdfManifest.ProcessStartTimeUtc = $rdfLiveProcess.StartTime.ToUniversalTime().ToString('o')
        $rdfRun.ProcessStartTimeUtc = $rdfManifest.ProcessStartTimeUtc
    }
    # Associate the new engine log directory explicitly when it is unambiguous.
    for ($rdfAttempt=0; $rdfAttempt -lt 16; $rdfAttempt++) {
        $rdfNewLogs = @(if (Test-Path -LiteralPath $rdfLogRoot -PathType Container) {
            Get-ChildItem -LiteralPath $rdfLogRoot -Directory | Where-Object { $_.Name -notin $rdfPreviousLogs }
        })
        if ($rdfNewLogs.Count -gt 0) {
            if ($rdfNewLogs.Count -eq 1) { $rdfRun.LogSession = $rdfNewLogs[0].Name }
            break
        }
        if ($rdfEditorProcess.HasExited) { break }
        Start-Sleep -Milliseconds 250
    }
    $rdfRun | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $rdfRunFile -Encoding UTF8
    $rdfManifest.Launched = $true
    Save-RdfEditorProfileManifest
} catch {
    $rdfManifest.LaunchError = $_.Exception.Message
    $rdfRun.LaunchError = $_.Exception.Message
    $rdfRun | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $rdfRunFile -Encoding UTF8
    Save-RdfEditorProfileManifest
    throw "Editor launch did not complete. Settings backup retained at $rdfManifestPath. $($_.Exception.Message)"
}

# Keep a small explicit receipt next to the self-contained run metadata.
$rdfReceiptPath = Join-Path $rdfRuntime ($rdfSessionId + '.json')
[ordered]@{ SessionId=$rdfSessionId; RunFile=$rdfManifest.RunFile; ProcessId=$rdfManifest.ProcessId; ProcessStartTimeUtc=$rdfManifest.ProcessStartTimeUtc; BackupManifest=$rdfManifestPath; Map=$Map; CreatedUtc=$rdfManifest.CreatedUtc } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $rdfReceiptPath -Encoding UTF8
[pscustomobject]@{
    ProcessId=$rdfManifest.ProcessId; RunFile=$rdfManifest.RunFile; BackupManifest=$rdfManifestPath
    Receipt=$rdfReceiptPath; Map=$Map; LogRoot=$rdfLogRoot; LogSession=$rdfRun.LogSession
    HostPort=$HostPort; SettingsBackedUp=@($rdfManifest.Files | Where-Object { $_.Existed }).Count
    Note='Editor process requested. Verify compilation, tool controls and save/reload in the game; exit the game before restoring settings.'
}
