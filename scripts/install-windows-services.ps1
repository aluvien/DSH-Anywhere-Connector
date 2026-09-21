param(
  [Parameter(Mandatory = $true)][string]$ConfigPath,
  [Parameter(Mandatory = $true)][string]$NodePath,
  [Parameter(Mandatory = $true)][string]$DshEntry
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$startupDir = [Environment]::GetFolderPath('Startup')
$runnerPath = Join-Path $PSScriptRoot 'run-windows-service.ps1'
$powershellPath = (Get-Command powershell.exe -ErrorAction Stop).Source

function Quote-CmdArgument([string]$value) {
  return '"' + $value.Replace('"', '""') + '"'
}

New-Item -ItemType Directory -Force -Path $startupDir | Out-Null
Remove-Item (Join-Path $startupDir 'DSH Anywhere.cmd') -Force -ErrorAction SilentlyContinue
$common = @(
  '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
  '-ExecutionPolicy', 'Bypass', '-File', $runnerPath
)
$serviceArguments = @(
  '-ProjectRoot', $projectRoot, '-ConfigPath', $ConfigPath,
  '-NodePath', $NodePath, '-DshEntry', $DshEntry
)

$shell = New-Object -ComObject WScript.Shell
foreach ($mode in @('bridge', 'connector')) {
  $arguments = $common + @('-Mode', $mode) + $serviceArguments
  $encoded = ($arguments | ForEach-Object { Quote-CmdArgument $_ }) -join ' '
  $shortcut = $shell.CreateShortcut((Join-Path $startupDir "DSH Anywhere $mode.lnk"))
  $shortcut.TargetPath = $powershellPath
  $shortcut.Arguments = $encoded
  $shortcut.WorkingDirectory = $projectRoot
  $shortcut.WindowStyle = 7
  $shortcut.Save()
}

foreach ($mode in @('bridge', 'connector')) {
  $arguments = $common + @('-Mode', $mode) + $serviceArguments
  $encoded = ($arguments | ForEach-Object { Quote-CmdArgument $_ }) -join ' '
  Start-Process -FilePath $powershellPath -ArgumentList $encoded -WindowStyle Hidden | Out-Null
}

Write-Host 'Installed and started DSH Anywhere background services for this Windows user.'
