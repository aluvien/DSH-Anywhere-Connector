param(
  [Parameter(Mandatory = $true)][ValidateSet('bridge', 'connector')][string]$Mode,
  [Parameter(Mandatory = $true)][string]$ProjectRoot,
  [Parameter(Mandatory = $true)][string]$ConfigPath,
  [Parameter(Mandatory = $true)][string]$NodePath,
  [Parameter(Mandatory = $true)][string]$DshEntry
)

$ErrorActionPreference = 'Stop'
$supportDir = Split-Path -Parent $ConfigPath
$logDir = Join-Path $supportDir 'logs'
$supervisorPidPath = Join-Path $supportDir "$Mode-supervisor.pid"
$childPidPath = Join-Path $supportDir "$Mode-child.pid"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

if (Test-Path $supervisorPidPath) {
  $existingPid = 0
  if ([int]::TryParse((Get-Content $supervisorPidPath -Raw).Trim(), [ref]$existingPid)) {
    $existing = Get-CimInstance Win32_Process -Filter "ProcessId = $existingPid" -ErrorAction SilentlyContinue
    if ($existing -and $existing.CommandLine -like '*run-windows-service.ps1*' -and $existing.CommandLine -like "*-Mode*$Mode*") { exit 0 }
  }
}
Set-Content -Path $supervisorPidPath -Value $PID -Encoding ascii

$env:DSH_ANYWHERE_CONFIG = $ConfigPath
$env:DSH_ANYWHERE_SKIP_BUILD = '1'
$env:DSH_ANYWHERE_NODE_BIN = $NodePath
if ($Mode -eq 'bridge') {
  $bridgeEnv = Join-Path $supportDir 'bridge.env'
  if (Test-Path $bridgeEnv) {
    foreach ($line in Get-Content $bridgeEnv) {
      if ($line -match '^DSH_ANYWHERE_CONNECTOR_TOKEN=(.+)$') {
        $env:DSH_ANYWHERE_CONNECTOR_TOKEN = $Matches[1]
      }
    }
  }
}

$stdoutPath = Join-Path $logDir "$Mode.log"
$stderrPath = Join-Path $logDir "$Mode.err.log"
try {
  while ($true) {
    if ($Mode -eq 'bridge') {
      $arguments = @(
        $DshEntry, 'web', '--patch',
        (Join-Path $ProjectRoot 'packages\dsh-anywhere-plugin\cordis.patch.yml'),
        '--port', '3080', '--no-open'
      )
    } else {
      $arguments = @(
        (Join-Path $ProjectRoot 'packages\connector\lib\cli.js'),
        'start', '--config', $ConfigPath
      )
    }
    $argumentLine = ($arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    $child = Start-Process -FilePath $NodePath -ArgumentList $argumentLine `
      -WorkingDirectory $ProjectRoot -PassThru -NoNewWindow `
      -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    Set-Content -Path $childPidPath -Value $child.Id -Encoding ascii
    $child.WaitForExit()
    Remove-Item $childPidPath -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
  }
} finally {
  if ($null -ne $child -and -not $child.HasExited) {
    Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
  }
  Remove-Item $childPidPath, $supervisorPidPath -Force -ErrorAction SilentlyContinue
}
