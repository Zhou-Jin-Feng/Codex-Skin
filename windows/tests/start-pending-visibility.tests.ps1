[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Root)

# A user who switches to a game while Codex restarts leaves the Codex window
# covered, and the renderer then reports itself hidden. Startup used to wait
# for that window until its 90-second deadline, close Codex and reopen it
# without the skin (C4.2). Now the injector reports exit code 4 when the skin is
# complete and only the window is not visible: startup must accept that as
# applied, must keep failed attempts in verify-failures.log, and may bring
# Codex forward (then verify once more) only while the user is looking at
# Dream Skin itself.

$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'scripts\localization-windows.ps1')
$startPath = Join-Path $Root 'scripts\start-dream-skin.ps1'
$rawSource = [System.IO.File]::ReadAllText($startPath)
$dotSourcePattern = '(?m)^\.\s+\(Join-Path \$PSScriptRoot ''(?:common-windows|theme-windows|localization-windows)\.ps1''\)\r?\n'
if ([regex]::Matches($rawSource, $dotSourcePattern).Count -ne 3) {
  throw 'Pending-visibility fixture could not isolate the three runtime imports.'
}
$rawSource = [regex]::Replace($rawSource, $dotSourcePattern, '')
$rawSource = $rawSource.Replace(
  '$Injector = Join-Path $PSScriptRoot ''injector.mjs''',
  '$Injector = ''mock-injector.mjs'''
)
$rawSource = $rawSource.Replace(
  '(Split-Path -Parent $PSScriptRoot)',
  '''mock-skill-root'''
)
if ($rawSource.Contains('$PSScriptRoot')) {
  throw 'Pending-visibility fixture left a real script-root dependency in the isolated source.'
}

$fixtureLocalAppData = Join-Path ([System.IO.Path]::GetTempPath()) ('dreamskin-pending-visibility-' + [guid]::NewGuid().ToString('N'))
$failureLog = Join-Path $fixtureLocalAppData 'CodexDreamSkin\verify-failures.log'

function Invoke-DreamSkinPendingFixture {
  param(
    [Parameter(Mandatory = $true)][int[]]$VerifyExitCodes,
    [Parameter(Mandatory = $true)][int]$OnceExitCode,
    [bool]$ActivationAllowed = $false
  )

  $script:daemon = [pscustomobject]@{ Id = 4242; HasExited = $false }
  $script:daemon | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    param([int]$Milliseconds)
    return $this.HasExited
  }
  $script:dateCall = 0
  $script:cdpReady = $false
  $script:codexProcessRunning = $false
  $script:codexStopped = $false
  $script:onceCalls = 0
  $script:verifyCalls = 0
  $script:verifyArguments = @()
  $script:onceArguments = @()
  $script:activations = 0
  $script:appearanceCompleted = 0
  $script:hostMessages = @()
  $script:stages = @()
  $script:stateRemoved = $false
  $script:lastError = $null

  function Enter-DreamSkinOperationLock { param([int]$TimeoutMilliseconds); return 'mock-lock' }
  function Exit-DreamSkinOperationLock { param([object]$Mutex) }
  function Start-DreamSkinTiming { param([string]$Source, [string]$Operation, [string]$StateRoot) }
  function Write-DreamSkinTimingMark { param([string]$Stage); $script:stages += $Stage }
  function Assert-DreamSkinPort { param([int]$Port) }
  function Get-DreamSkinNodeRuntime {
    return [pscustomobject]@{ Path = 'mock-node.exe'; Version = '22.23.1' }
  }
  function Get-DreamSkinCodexInstall {
    return [pscustomobject]@{
      Executable = 'C:\Program Files\WindowsApps\OpenAI.Codex\app\ChatGPT.exe'
      PackageRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex'
      PackageFullName = 'OpenAI.Codex_fixture'
      PackageFamilyName = 'OpenAI.Codex_fixture'
      Version = '26.930.3930.0'
    }
  }
  function Get-DreamSkinThemePaths {
    param([string]$StateRoot)
    return [pscustomobject]@{
      Root = $StateRoot
      Active = (Join-Path $StateRoot 'active-theme')
      PauseFile = (Join-Path $StateRoot 'paused')
    }
  }
  function Ensure-DreamSkinManagedDirectory { param([string]$Path, [string]$Root) }
  function Initialize-DreamSkinThemeStore {
    param([string]$SkillRoot, [string]$StateRoot)
    return Get-DreamSkinThemePaths -StateRoot $StateRoot
  }
  function Test-DreamSkinPaused { param([string]$StateRoot); return $false }
  function Test-DreamSkinPendingAppearanceTransaction { param([string]$BackupPath); return $false }
  function Read-DreamSkinState { param([string]$Path); return $null }
  function Get-DreamSkinCodexStatePathCandidate { param([object]$State); return $null }
  function Get-DreamSkinCodexInstallFromState { param([object]$State); return $null }
  function Test-DreamSkinPathEqual { param([string]$Left, [string]$Right); return $true }
  function Stop-DreamSkinRecordedInjector { param([object]$State); return $true }
  function Set-DreamSkinPaused { param([bool]$Paused, [string]$StateRoot); return $true }
  function Test-DreamSkinCodexActivationAllowed { return $ActivationAllowed }
  function Invoke-DreamSkinCodexWindowActivation { param([object]$Codex); $script:activations += 1; return $true }
  function ConvertTo-DreamSkinProcessArgument { param([string]$Value); return $Value }
  function Get-DreamSkinProcessStartedAt { param([int]$ProcessId); return '2026-10-07T00:00:00.0000000Z' }
  function Get-DreamSkinRuntimeFingerprint { param([string]$SkillRoot); return 'fixture-fingerprint' }
  function Write-DreamSkinState { param([string]$Path, [object]$State) }
  function Write-DreamSkinUtf8FileAtomically { param([string]$Path, [string]$Content) }
  function Sync-DreamSkinProfileStatsigIdentity { param([object]$Codex, [string]$ProfilePath); return 'skipped (fixture)' }
  function Get-DreamSkinCodexProcesses {
    param([object]$Codex)
    if ($script:codexProcessRunning) { return @([pscustomobject]@{ ProcessId = 909 }) }
    return @()
  }
  function Get-DreamSkinVerifiedCdpIdentity {
    param([int]$Port, [object]$Codex)
    if (-not $script:cdpReady) { return $null }
    return [pscustomobject]@{ BrowserId = 'fixture-browser' }
  }
  function Get-DreamSkinVerifiedCdpIdentityForAnyRegistered { param([int]$Port); return $null }
  function Test-DreamSkinPortAvailable { param([int]$Port); return $true }
  function Get-DreamSkinActiveThemeAppearance { param([string]$ThemeDirectory); return 'dark' }
  function Install-DreamSkinBaseTheme {
    param(
      [string]$ConfigPath, [string]$BackupPath, [string]$AppearanceTheme,
      [switch]$PassThruTransaction
    )
    return [pscustomobject]@{ SchemaVersion = 1 }
  }
  function Restore-DreamSkinManagedAppearanceSnapshot {
    param([string]$ConfigPath, [string]$BackupPath, [object]$Transaction)
    return [pscustomobject]@{ ConflictedKeys = @(); MarkerStatus = 'restored' }
  }
  function Complete-DreamSkinAppearanceTransaction {
    param([string]$BackupPath, [object]$Transaction)
    $script:appearanceCompleted += 1
  }
  function Start-DreamSkinCodexForDebugging {
    param([object]$Codex, [string[]]$Arguments, [int]$Port, [int[]]$PreserveProcessIds)
    $script:cdpReady = $true
    $script:codexProcessRunning = $true
    return [pscustomobject]@{ Strategy = 'package-activation' }
  }
  function Stop-DreamSkinCodex {
    param([object]$Codex, [int[]]$PreserveProcessIds, [switch]$AllowForce)
    $script:codexStopped = $true
    $script:cdpReady = $false
    $script:codexProcessRunning = $false
  }
  function Start-DreamSkinCodex { param([object]$Codex); return [pscustomobject]@{ Id = 909 } }
  function Invoke-DreamSkinNative {
    param([string]$FilePath, [object[]]$ArgumentList, [switch]$DiscardStderr)
    if ($ArgumentList -contains '--verify') {
      $script:verifyArguments = @($ArgumentList)
      $code = $VerifyExitCodes[[Math]::Min($script:verifyCalls, $VerifyExitCodes.Count - 1)]
      $script:verifyCalls += 1
      return [pscustomobject]@{ ExitCode = $code; Output = @("{""mode"":""verify"",""exit"":$code}") }
    }
    if ($ArgumentList -contains '--once') {
      $script:onceCalls += 1
      $script:onceArguments = @($ArgumentList)
      return [pscustomobject]@{ ExitCode = $OnceExitCode; Output = @("{""mode"":""once"",""exit"":$OnceExitCode}") }
    }
    if ($ArgumentList -contains '--remove') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
    throw 'The pending-visibility fixture received an unexpected native command.'
  }
  function Start-Process {
    [CmdletBinding()]
    param(
      [string]$FilePath,
      [object[]]$ArgumentList,
      [string]$WindowStyle,
      [switch]$PassThru,
      [string]$RedirectStandardOutput,
      [string]$RedirectStandardError
    )
    return $script:daemon
  }
  function Stop-Process {
    [CmdletBinding()]
    param([object]$InputObject, [switch]$Force)
    $InputObject.HasExited = $true
  }
  function Remove-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [switch]$Force)
    if ([System.IO.Path]::GetFileName($LiteralPath) -ceq 'state.json') { $script:stateRemoved = $true }
  }
  function Write-Host {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Object)
    $script:hostMessages += ($Object -join ' ')
  }
  # Stay inside the shared budget until the forced apply has run, then expire.
  function Get-Date {
    $script:dateCall += 1
    $elapsedSeconds = $script:dateCall
    if ($script:onceCalls -gt 0) { $elapsedSeconds += 120 }
    return [DateTime]::new(2026, 10, 7, 0, 0, 0, [DateTimeKind]::Utc).AddSeconds($elapsedSeconds)
  }
  function Start-Sleep { param([int]$Milliseconds, [int]$Seconds) }

  $originalLocalAppData = $env:LOCALAPPDATA
  $env:LOCALAPPDATA = $fixtureLocalAppData
  try {
    $startBlock = [scriptblock]::Create($rawSource)
    try { & $startBlock -Port 9335 } catch { $script:lastError = $_.Exception.Message }
  } finally {
    $env:LOCALAPPDATA = $originalLocalAppData
  }
  return [pscustomobject]@{
    LastError = $script:lastError
    Active = @($script:hostMessages | Where-Object { $_ -like 'Codex Dream Skin is active*' }).Count -gt 0
    Pending = @($script:hostMessages | Where-Object { $_ -like 'DREAM_SKIN_PENDING_VISIBILITY:*' }).Count -gt 0
    Stages = @($script:stages)
    OnceCalls = $script:onceCalls
    VerifyCalls = $script:verifyCalls
    VerifyArguments = @($script:verifyArguments)
    OnceArguments = @($script:onceArguments)
    Activations = $script:activations
    AppearanceCompleted = $script:appearanceCompleted
    CodexStopped = $script:codexStopped
    StateRemoved = $script:stateRemoved
  }
}

function Read-FailureRecords {
  if (-not (Test-Path -LiteralPath $failureLog -PathType Leaf)) { return @() }
  return @([System.IO.File]::ReadAllLines($failureLog) | Where-Object { $_ -like '=== *' })
}

New-Item -ItemType Directory -Path (Split-Path -Parent $failureLog) -Force | Out-Null
try {
  # Complete skin, window covered by another program: accepted without waiting
  # out the deadline, without the forced apply and without pulling Codex over it.
  $hidden = Invoke-DreamSkinPendingFixture -VerifyExitCodes 4 -OnceExitCode 2
  if ($hidden.LastError -or -not $hidden.Active -or -not $hidden.Pending -or $hidden.OnceCalls -ne 0 -or
    $hidden.VerifyCalls -ne 1 -or
    $hidden.CodexStopped -or $hidden.StateRemoved -or $hidden.AppearanceCompleted -ne 1 -or
    $hidden.Activations -ne 0 -or $hidden.VerifyArguments -notcontains '--accept-hidden' -or
    $hidden.Stages -notcontains 'renderer verified (pending visibility)' -or @(Read-FailureRecords).Count -ne 0) {
    throw "A complete skin behind another window must be reported as applied and pending visibility. Error: $($hidden.LastError)"
  }

  # The user is looking at Dream Skin: Codex is brought forward once and
  # verified again; still hidden afterwards, it is reported as pending.
  $watching = Invoke-DreamSkinPendingFixture -VerifyExitCodes 4 -OnceExitCode 2 -ActivationAllowed $true
  if ($watching.LastError -or $watching.Activations -ne 1 -or $watching.VerifyCalls -ne 2 -or
    -not $watching.Pending -or $watching.OnceCalls -ne 0) {
    throw 'A hidden Codex must be brought forward once and verified again while Dream Skin is in the foreground.'
  }

  # Brought forward successfully: an ordinary verified start without the hint.
  $shown = Invoke-DreamSkinPendingFixture -VerifyExitCodes 4, 0 -OnceExitCode 2 -ActivationAllowed $true
  if ($shown.LastError -or -not $shown.Active -or $shown.Pending -or $shown.Activations -ne 1 -or
    $shown.VerifyCalls -ne 2 -or $shown.Stages -notcontains 'renderer verified') {
    throw 'A Codex window shown after activation must verify as an ordinary start.'
  }

  # The verify fails, the forced apply finds the skin complete but hidden.
  $forced = Invoke-DreamSkinPendingFixture -VerifyExitCodes 2 -OnceExitCode 4 -ActivationAllowed $true
  $records = @(Read-FailureRecords)
  if ($forced.LastError -or -not $forced.Pending -or $forced.OnceCalls -ne 1 -or $forced.CodexStopped -or
    $forced.OnceArguments -notcontains '--accept-hidden' -or $forced.Activations -ne 1 -or
    $records.Count -ne 1 -or $records[0] -notlike '*verify (exit 2)') {
    throw "A forced apply that finds a complete hidden skin must be accepted after recording the failed verify. Error: $($forced.LastError)"
  }

  # Both probes fail: the existing rollback still runs and both failures are kept.
  Remove-Item -LiteralPath $failureLog -Force
  $broken = Invoke-DreamSkinPendingFixture -VerifyExitCodes 2 -OnceExitCode 2
  $records = @(Read-FailureRecords)
  if ($broken.LastError -notlike 'Dream Skin verification failed.*' -or $broken.Active -or $broken.Pending -or
    -not $broken.CodexStopped -or -not $broken.StateRemoved -or $broken.Activations -ne 0 -or
    $records.Count -ne 2 -or $records[0] -notlike '*verify (exit 2)' -or $records[1] -notlike '*forced apply (exit 2)') {
    throw "A broken renderer must still roll back, with both failed attempts recorded. Error: $($broken.LastError)"
  }
} finally {
  Remove-Item -LiteralPath $fixtureLocalAppData -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'PASS: startup accepts a complete skin behind another window, keeps failed attempts, and only pulls Codex forward from Dream Skin'
