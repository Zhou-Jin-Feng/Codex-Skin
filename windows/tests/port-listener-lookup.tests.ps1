[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Root)

$ErrorActionPreference = 'Stop'

function Assert-Equal {
  param($Expected, $Actual, [string]$Message)
  if ("$Expected" -cne "$Actual") { throw "$Message Expected '$Expected', got '$Actual'." }
}

function Assert-SamePath {
  param([string]$Expected, [string]$Actual, [string]$Message)
  if (-not (Test-DreamSkinPathEqual -Left $Expected -Right $Actual)) { throw "$Message Expected '$Expected', got '$Actual'." }
}

. (Join-Path $Root 'scripts\common-windows.ps1')

# Real loopback listeners owned by this PowerShell process stand in for the
# Codex debugging endpoint; loopback binds never raise a firewall prompt.
$ownPath = (Get-Process -Id $PID).Path
$self = [pscustomobject]@{ Executable = $ownPath }
$other = [pscustomobject]@{ Executable = (Join-Path $env:SystemRoot 'System32\notepad.exe') }

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
try {
  $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  $rows = @(Get-DreamSkinPortListeners -Port $port)
  Assert-Equal 1 $rows.Count 'One IPv4 loopback listener must be reported.'
  if (-not ($rows[0] -is [CodexDreamSkin.TcpListenerEntry])) {
    throw 'The listener rows must come from the native listener table.'
  }
  Assert-Equal '127.0.0.1' $rows[0].LocalAddress 'The IPv4 listener address must be formatted like Get-NetTCPConnection.'
  Assert-Equal $port $rows[0].LocalPort 'The listener port must be decoded from network byte order.'
  Assert-Equal $PID $rows[0].OwningProcess 'The listener must report its owning process.'
  if (Test-DreamSkinPortAvailable -Port $port) { throw 'A port with a listener must not be available.' }
  Assert-SamePath $ownPath ([CodexDreamSkin.LoopbackListenerTable]::ProcessImagePath($PID)) `
    'The native image path must name this process executable.'
  # Parity with the CIM query the lookup replaces.
  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    $expected = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
      ForEach-Object { "$($_.LocalAddress)|$($_.OwningProcess)" } | Sort-Object) -join ','
    $actual = @($rows | ForEach-Object { "$($_.LocalAddress)|$($_.OwningProcess)" } | Sort-Object) -join ','
    Assert-Equal $expected $actual 'The native listener rows must match Get-NetTCPConnection.'
  }

  # Win32_Process stays the final word whenever the fast path is not a match.
  $script:cimProcessQueries = 0
  $script:cimProcessPaths = @{}
  function Get-CimInstance {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    $script:cimProcessQueries += 1
    if ($Filter -match '^ProcessId = (\d+)$' -and $script:cimProcessPaths.ContainsKey([int]$Matches[1])) {
      [pscustomobject]@{ ProcessId = [int]$Matches[1]; ExecutablePath = $script:cimProcessPaths[[int]$Matches[1]] }
    }
  }
  if (-not (Test-DreamSkinCodexPortOwner -Port $port -Codex $self)) {
    throw 'A loopback listener owned by the expected executable must be accepted.'
  }
  Assert-Equal 0 $script:cimProcessQueries 'A native path match must not need Win32_Process.'
  $script:cimProcessPaths[$PID] = $ownPath
  if (Test-DreamSkinCodexPortOwner -Port $port -Codex $other) {
    throw 'A listener owned by another executable must be rejected.'
  }
  Assert-Equal 1 $script:cimProcessQueries 'A native path mismatch must be confirmed by Win32_Process.'
  # An install behind a junction: the launch path WMI reports differs from the
  # final path, and the launch path is what the registered package names.
  $launchPath = 'C:\DreamSkinJunction\app\ChatGPT.exe'
  $script:cimProcessPaths[$PID] = $launchPath
  if (-not (Test-DreamSkinCodexPortOwner -Port $port -Codex ([pscustomobject]@{ Executable = $launchPath }))) {
    throw 'A listener launched through a junction must still be accepted by its launch path.'
  }
} finally {
  $listener.Stop()
}
if (-not (Test-DreamSkinPortAvailable -Port $port)) { throw 'A closed listener must leave its port available.' }
if (Test-DreamSkinCodexPortOwner -Port $port -Codex $self) { throw 'A port without listeners has no owner.' }

# No native answer (no such process): Win32_Process decides.
$missingPid = 2147483644
if ($null -ne [CodexDreamSkin.LoopbackListenerTable]::ProcessImagePath($missingPid)) {
  throw 'A missing process has no native image path.'
}
$script:cimProcessPaths[$missingPid] = $ownPath
if (-not (Test-DreamSkinListenerProcess -ProcessId $missingPid -Executable $ownPath)) {
  throw 'Without a native image path the Win32_Process path must decide.'
}
if (Test-DreamSkinListenerProcess -ProcessId 0 -Executable $ownPath) { throw 'The idle process id never matches.' }

# An exited process kept alive by an open handle has no native image path.
$exited = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList '/c', 'exit 0' `
  -WindowStyle Hidden -PassThru
$null = $exited.Handle
try {
  if (-not $exited.WaitForExit(10000)) { throw 'The short-lived helper process did not exit.' }
  if ($null -ne [CodexDreamSkin.LoopbackListenerTable]::ProcessImagePath($exited.Id)) {
    throw 'An exited process must not report a native image path.'
  }
} finally {
  $exited.Dispose()
}

$listener6 = $null
try {
  $listener6 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::IPv6Loopback, 0)
  $listener6.Start()
} catch {
  $listener6 = $null
}
if ($null -ne $listener6) {
  try {
    $port6 = ([System.Net.IPEndPoint]$listener6.LocalEndpoint).Port
    $rows6 = @(Get-DreamSkinPortListeners -Port $port6)
    Assert-Equal 1 $rows6.Count 'One IPv6 loopback listener must be reported.'
    Assert-Equal '::1' $rows6[0].LocalAddress 'The IPv6 listener address must be formatted like Get-NetTCPConnection.'
    Assert-Equal $PID $rows6[0].OwningProcess 'The IPv6 listener must report its owning process.'
    if (-not (Test-DreamSkinCodexPortOwner -Port $port6 -Codex $self)) {
      throw 'An IPv6 loopback listener owned by the expected executable must be accepted.'
    }
  } finally {
    $listener6.Stop()
  }
} else {
  Write-Host 'SKIP: IPv6 loopback is unavailable; IPv6 listener rows were not checked.'
}

# Without the native helper the original CIM queries answer instead.
$script:cimListenerQueries = 0
$script:cimProcessQueries = 0
$script:cimProcessPaths = @{ 4242 = $ownPath }
function Get-NetTCPConnection {
  [CmdletBinding()] param([string]$State, [int]$LocalPort)
  $script:cimListenerQueries += 1
  [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = $LocalPort; OwningProcess = 4242 }
}
$script:DreamSkinListenerLookupUnavailable = $true
try {
  $fallbackRows = @(Get-DreamSkinPortListeners -Port 9335)
  Assert-Equal 1 $script:cimListenerQueries 'The listener query must fall back to Get-NetTCPConnection.'
  Assert-Equal 4242 $fallbackRows[0].OwningProcess 'The fallback must return the CIM listener rows.'
  if (-not (Test-DreamSkinCodexPortOwner -Port 9335 -Codex $self)) {
    throw 'The CIM fallback must still accept the expected owner.'
  }
  Assert-Equal 1 $script:cimProcessQueries 'The owner path must fall back to Win32_Process.'
} finally {
  $script:DreamSkinListenerLookupUnavailable = $false
}

# A listener that is not bound to loopback is never trusted, whoever owns it.
function Get-DreamSkinPortListeners {
  param([int]$Port)
  [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = $Port; OwningProcess = $PID }
}
if (Test-DreamSkinCodexPortOwner -Port 9335 -Codex $self) { throw 'A listener on all interfaces must be rejected.' }

Write-Host 'PASS: CDP port ownership reads the listener tables natively, matches Get-NetTCPConnection, and lets CIM decide every non-match'
