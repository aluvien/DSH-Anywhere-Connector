$ErrorActionPreference = 'Stop'

# Served by Relay with a short-lived one-use enrollment grant. Usage:
# irm https://relay.example/install-windows | iex
$relayUrl = '__DSH_RELAY_URL__'
$enrollmentToken = '__DSH_ENROLLMENT_TOKEN__'
$sourceArchiveUrl = '__DSH_SOURCE_ARCHIVE_URL__'

if (-not $IsWindows -and $env:OS -ne 'Windows_NT') {
  throw 'This installer requires Windows.'
}

$supportDir = Join-Path $env:LOCALAPPDATA 'DSH Anywhere'
$configPath = Join-Path $supportDir 'connector.json'
$runtimeDir = Join-Path $supportDir 'runtime'
$bundleDir = Join-Path $supportDir 'app'
$nextBundle = Join-Path $supportDir ("app.next." + $PID)
$previousBundle = Join-Path $supportDir 'app.previous'
$temporaryDir = Join-Path ([IO.Path]::GetTempPath()) ("dsh-anywhere-install-" + [Guid]::NewGuid().ToString('N'))

function Assert-ExitCode([string]$operation) {
  if ($LASTEXITCODE -ne 0) { throw "$operation failed with exit code $LASTEXITCODE." }
}

function Stop-ExistingServices {
  foreach ($name in @('bridge-child', 'connector-child', 'bridge-supervisor', 'connector-supervisor')) {
    $pidPath = Join-Path $supportDir "$name.pid"
    if (-not (Test-Path $pidPath)) { continue }
    $processId = 0
    if ([int]::TryParse((Get-Content $pidPath -Raw).Trim(), [ref]$processId)) {
      Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 500
}

New-Item -ItemType Directory -Force -Path $supportDir, $runtimeDir, $temporaryDir | Out-Null
$bundleSwapped = $false
$nodeCommand = $null
$dshEntry = $null
try {
  $nodeCommand = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
  $nodeUsable = $false
  if ($nodeCommand) {
    & $nodeCommand -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)'
    $nodeUsable = $LASTEXITCODE -eq 0
  }

  if (-not $nodeUsable) {
    $nodeVersion = 'v22.19.0'
    $architecture = switch -Regex ($env:PROCESSOR_ARCHITECTURE) {
      '^(AMD64|x86_64)$' { 'x64'; break }
      '^(ARM64|aarch64)$' { 'arm64'; break }
      default { throw "Unsupported Windows architecture: $env:PROCESSOR_ARCHITECTURE" }
    }
    $nodeHome = Join-Path $runtimeDir "node-$nodeVersion-win-$architecture"
    $nodeCommand = Join-Path $nodeHome 'node.exe'
    if (-not (Test-Path $nodeCommand)) {
      $nodeArchive = "node-$nodeVersion-win-$architecture.zip"
      $nodeBase = "https://nodejs.org/dist/$nodeVersion"
      $archivePath = Join-Path $temporaryDir $nodeArchive
      $checksumsPath = Join-Path $temporaryDir 'SHASUMS256.txt'
      Write-Host 'Installing the private Node.js runtime…'
      Invoke-WebRequest -UseBasicParsing -Uri "$nodeBase/$nodeArchive" -OutFile $archivePath
      Invoke-WebRequest -UseBasicParsing -Uri "$nodeBase/SHASUMS256.txt" -OutFile $checksumsPath
      $checksumLine = Get-Content $checksumsPath | Where-Object { $_ -match "\s$([regex]::Escape($nodeArchive))$" } | Select-Object -First 1
      if (-not $checksumLine) { throw 'The Node.js checksum was not published.' }
      $expectedHash = ($checksumLine -split '\s+')[0].ToUpperInvariant()
      $actualHash = (Get-FileHash -Algorithm SHA256 $archivePath).Hash.ToUpperInvariant()
      if ($expectedHash -ne $actualHash) { throw 'Node.js download verification failed.' }
      $extractRoot = Join-Path $temporaryDir 'node'
      Expand-Archive -Path $archivePath -DestinationPath $extractRoot
      $extracted = Get-ChildItem -Path $extractRoot -Directory | Select-Object -First 1
      if (-not $extracted) { throw 'The Node.js archive is empty.' }
      Move-Item -Path $extracted.FullName -Destination $nodeHome
    }
  }

  $nodeBinDir = Split-Path -Parent $nodeCommand
  $npmCommand = Join-Path $nodeBinDir 'npm.cmd'
  if (-not (Test-Path $npmCommand)) {
    $npmCommand = (Get-Command npm.cmd -ErrorAction Stop).Source
  }
  $toolsPrefix = Join-Path $runtimeDir 'tools'
  Write-Host 'Preparing DSH Anywhere tools…'
  & $npmCommand install --global --prefix $toolsPrefix --silent pnpm@11.9.0 '@deepseek-ai/dsh@0.1.5-rc.2'
  Assert-ExitCode 'Tool installation'
  $pnpmCommand = Join-Path $toolsPrefix 'pnpm.cmd'
  $dshEntry = Join-Path $toolsPrefix 'node_modules\@deepseek-ai\dsh\lib\bin.js'

  Write-Host 'Downloading DSH Anywhere…'
  $sourcePath = Join-Path $temporaryDir 'source.tar.gz'
  Invoke-WebRequest -UseBasicParsing -Uri $sourceArchiveUrl -OutFile $sourcePath
  New-Item -ItemType Directory -Force -Path $nextBundle | Out-Null
  & tar.exe -xzf $sourcePath -C $nextBundle --strip-components 1
  Assert-ExitCode 'Source extraction'
  & $pnpmCommand --dir $nextBundle install --frozen-lockfile --config.confirmModulesPurge=false
  Assert-ExitCode 'Dependency installation'
  & $pnpmCommand --dir $nextBundle build
  Assert-ExitCode 'DSH Anywhere build'

  Stop-ExistingServices
  if (Test-Path $previousBundle) { Remove-Item $previousBundle -Recurse -Force }
  if (Test-Path $bundleDir) { Move-Item $bundleDir $previousBundle }
  Move-Item $nextBundle $bundleDir
  $bundleSwapped = $true

  if (-not (Test-Path $configPath)) {
    Write-Host 'Registering this Windows computer…'
    $env:DSH_ANYWHERE_ENROLLMENT_TOKEN = $enrollmentToken
    try {
      & $nodeCommand (Join-Path $bundleDir 'packages\connector\lib\cli.js') enroll `
        --relay $relayUrl --machine-name ([Environment]::MachineName) --config $configPath
      Assert-ExitCode 'Machine enrollment'
    } finally {
      Remove-Item Env:DSH_ANYWHERE_ENROLLMENT_TOKEN -ErrorAction SilentlyContinue
    }
  }

  try {
    & (Join-Path $bundleDir 'scripts\install-windows-services.ps1') `
      -ConfigPath $configPath -NodePath $nodeCommand -DshEntry $dshEntry
  } catch {
    Stop-ExistingServices
    if (Test-Path $previousBundle) {
      Remove-Item $bundleDir -Recurse -Force -ErrorAction SilentlyContinue
      Move-Item $previousBundle $bundleDir
      $bundleSwapped = $false
      & (Join-Path $bundleDir 'scripts\install-windows-services.ps1') `
        -ConfigPath $configPath -NodePath $nodeCommand -DshEntry $dshEntry
    }
    throw
  }
  if (Test-Path $previousBundle) { Remove-Item $previousBundle -Recurse -Force }
  $bundleSwapped = $false

  Write-Host ''
  Write-Host 'Scan this one-time QR code with DSH Anywhere on iPhone:'
  & $nodeCommand (Join-Path $bundleDir 'packages\connector\lib\cli.js') pair-qr --config $configPath
  Assert-ExitCode 'Pairing code generation'

  $pairingPage = 'http://127.0.0.1:3080/dsh-anywhere/v1/pairing'
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    try {
      Invoke-WebRequest -UseBasicParsing -Uri $pairingPage -TimeoutSec 2 | Out-Null
      break
    } catch { Start-Sleep -Seconds 1 }
  }
  Start-Process $pairingPage
  Write-Host ''
  Write-Host 'DSH Anywhere is installed and running for this Windows user.'
} catch {
  if ($bundleSwapped -and (Test-Path $previousBundle)) {
    Stop-ExistingServices
    Remove-Item $bundleDir -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item $previousBundle $bundleDir -ErrorAction SilentlyContinue
    if ((Test-Path $configPath) -and $nodeCommand -and $dshEntry) {
      & (Join-Path $bundleDir 'scripts\install-windows-services.ps1') `
        -ConfigPath $configPath -NodePath $nodeCommand -DshEntry $dshEntry
    }
  }
  throw
} finally {
  Remove-Item $temporaryDir, $nextBundle -Recurse -Force -ErrorAction SilentlyContinue
}
