[CmdletBinding()]
param([string]$GameRoot, [string]$Map = 'mp_rr_arena_phase_runner')
$ErrorActionPreference = 'Stop'
try {
    $rdfInstall = & (Join-Path $PSScriptRoot 'Install-RdfLevelEditor.ps1') -GameRoot $GameRoot
    $rdfSession = & (Join-Path $PSScriptRoot 'Start-RdfLevelEditor.ps1') -GameRoot $rdfInstall.GameRoot -Map $Map
    $rdfSession | Format-List
    Write-Host 'Close the welcome message, then press Q to equip the editor.'
    Write-Host 'Keep this launcher open. Your original key settings will be restored after the game exits.'
    $rdfProcess = Get-Process -Id $rdfSession.ProcessId -ErrorAction SilentlyContinue
    if ($rdfProcess -and $rdfProcess.ProcessName -eq 'r5apex') { $rdfProcess.WaitForExit() }
    & (Join-Path $PSScriptRoot 'Restore-RdfEditorSettings.ps1') -Manifest $rdfSession.BackupManifest
} catch {
    Write-Error $_
    exit 1
}
