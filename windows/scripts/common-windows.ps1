. (Join-Path $PSScriptRoot 'config-utf8.ps1')
$runtimeVersionScript = Join-Path $PSScriptRoot 'runtime-version.ps1'
if (Test-Path -LiteralPath $runtimeVersionScript -PathType Leaf) {
  . $runtimeVersionScript
}

$script:DreamSkinStartResultCategories = @(
  'none',
  'cdp-launch-failed',
  'cdp-direct-access-denied',
  'cdp-endpoint-unavailable',
  'port-unavailable',
  'state-reconciliation-failed',
  'injector-start-failed',
  'renderer-verification-failed',
  'superseded',
  'internal-start-failure'
)
$script:DreamSkinStartAppearanceRecoveryStates = @(
  'not-needed',
  'retained',
  'restored',
  'conflict-preserved',
  'blocked',
  'preserved-rendered'
)

$script:DreamSkinTimingStopwatch = $null
$script:DreamSkinTimingRoot = ''
$script:DreamSkinTimingSource = ''
$script:DreamSkinTimingOperation = ''
$script:DreamSkinTimingMaxBytes = 512KB

# Stage timings shared with the manager in timing.log under the caller's state
# root. Diagnostic only: a full disk or a locked log must never change the
# outcome of the measured operation.
function Start-DreamSkinTiming {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Operation,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $script:DreamSkinTimingRoot = $StateRoot
  $script:DreamSkinTimingSource = $Source
  $script:DreamSkinTimingOperation = $Operation
  $script:DreamSkinTimingStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  Write-DreamSkinTimingMark -Stage 'start'
}

function Write-DreamSkinTimingMark {
  param([Parameter(Mandatory = $true)][string]$Stage)
  try {
    if ($null -eq $script:DreamSkinTimingStopwatch) { return }
    $root = $script:DreamSkinTimingRoot
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { return }
    $path = Join-Path $root 'timing.log'
    $existing = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($null -ne $existing -and $existing.Length -gt $script:DreamSkinTimingMaxBytes) {
      Move-Item -LiteralPath $path -Destination ($path + '.1') -Force -ErrorAction SilentlyContinue
    }
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $line = [string]::Format($invariant, "{0} [{1}#{2}] {3} :: {4} (+{5} ms)`r`n",
      (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', $invariant),
      $script:DreamSkinTimingSource, $PID, $script:DreamSkinTimingOperation, $Stage,
      $script:DreamSkinTimingStopwatch.ElapsedMilliseconds)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($line)
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write,
      ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
  } catch {}
}

function New-DreamSkinStartException {
  param(
    [Parameter(Mandatory = $true)][string]$Category,
    [Parameter(Mandatory = $true)][string]$Message,
    [AllowNull()][System.Exception]$InnerException
  )
  if ($script:DreamSkinStartResultCategories -cnotcontains $Category -or $Category -ceq 'none') {
    throw 'Invalid Dream Skin start failure category.'
  }
  $exception = if ($null -ne $InnerException) {
    [System.InvalidOperationException]::new($Message, $InnerException)
  } else {
    [System.InvalidOperationException]::new($Message)
  }
  $exception.Data['DreamSkinStartCategory'] = $Category
  return $exception
}

function Get-DreamSkinStartFailureCategory {
  param(
    [Parameter(Mandatory = $true)][System.Exception]$Exception,
    [ValidateSet(
      'cdp-launch-failed', 'cdp-direct-access-denied', 'cdp-endpoint-unavailable',
      'port-unavailable', 'state-reconciliation-failed', 'injector-start-failed',
      'renderer-verification-failed', 'superseded', 'internal-start-failure'
    )]
    [string]$FallbackCategory = 'internal-start-failure'
  )
  $current = $Exception
  while ($null -ne $current) {
    $category = "$($current.Data['DreamSkinStartCategory'])"
    if ($script:DreamSkinStartResultCategories -ccontains $category -and $category -cne 'none') {
      return $category
    }
    $current = $current.InnerException
  }
  return $FallbackCategory
}

function Get-DreamSkinStartResultPath {
  param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$Token
  )
  if ($Token -cnotmatch '\A[a-f0-9]{32}\z') {
    throw 'Dream Skin start result token is invalid.'
  }
  $root = [System.IO.Path]::GetFullPath($StateRoot)
  return Join-Path $root ('.start-result-' + $Token + '.json')
}

function Write-DreamSkinStartResult {
  param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][ValidateSet('success', 'failure')][string]$Outcome,
    [Parameter(Mandatory = $true)][string]$Category,
    [Parameter(Mandatory = $true)][string]$AppearanceRecovery
  )
  if ($script:DreamSkinStartResultCategories -cnotcontains $Category -or
    $script:DreamSkinStartAppearanceRecoveryStates -cnotcontains $AppearanceRecovery -or
    ($Outcome -ceq 'success' -and $Category -cne 'none') -or
    ($Outcome -ceq 'failure' -and $Category -ceq 'none')) {
    throw 'Dream Skin start result fields are invalid.'
  }
  $path = Get-DreamSkinStartResultPath -StateRoot $StateRoot -Token $Token
  [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetFullPath($StateRoot)) | Out-Null
  if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $path
  }
  $result = [ordered]@{
    schemaVersion = 1
    token = $Token
    outcome = $Outcome
    category = $Category
    appearanceRecovery = $AppearanceRecovery
  }
  $content = (($result | ConvertTo-Json -Compress) + "`r`n")
  if ($script:DreamSkinUtf8NoBom.GetByteCount($content) -gt 4096) {
    throw 'Dream Skin start result exceeded its fixed size limit.'
  }
  Write-DreamSkinUtf8FileAtomically -Path $path -Content $content -ExpectedBytes $null
}

function Read-DreamSkinStartResult {
  param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][string]$Token
  )
  $path = Get-DreamSkinStartResultPath -StateRoot $StateRoot -Token $Token
  if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $path
  }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw 'Dream Skin start did not return a structured result.'
  }
  $stream = $null
  try {
    # Hold one non-writable, non-deletable handle from the size check through
    # the read. This prevents a path swap or growth between two file opens.
    $stream = [System.IO.FileStream]::new(
      $path,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read
    )
    if ($stream.Length -le 0 -or $stream.Length -gt 4096) {
      throw 'Dream Skin start returned an invalid structured result size.'
    }
    $bytes = [byte[]]::new([int]$stream.Length)
    $offset = 0
    while ($offset -lt $bytes.Length) {
      $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
      if ($read -le 0) {
        throw 'Dream Skin start returned a truncated structured result.'
      }
      $offset += $read
    }
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
  $json = ConvertFrom-DreamSkinUtf8Bytes -Bytes $bytes -Path $path
  try { $result = $json | ConvertFrom-Json -ErrorAction Stop } catch {
    throw 'Dream Skin start returned invalid structured result JSON.'
  }
  if ($null -eq $result -or $result -is [string] -or $result -is [array]) {
    throw 'Dream Skin start returned an invalid structured result object.'
  }
  $allowed = @('schemaVersion', 'token', 'outcome', 'category', 'appearanceRecovery')
  $properties = @($result.PSObject.Properties)
  if ($properties.Count -ne $allowed.Count) {
    throw 'Dream Skin start returned an unexpected structured result shape.'
  }
  foreach ($property in $properties) {
    if ($allowed -cnotcontains $property.Name) {
      throw 'Dream Skin start returned an unexpected structured result field.'
    }
  }
  if (($result.schemaVersion -isnot [int] -and $result.schemaVersion -isnot [long]) -or
    [int64]$result.schemaVersion -ne 1 -or
    $result.token -isnot [string] -or "$($result.token)" -cne $Token -or
    $result.outcome -isnot [string] -or
    @('success', 'failure') -cnotcontains "$($result.outcome)" -or
    $result.category -isnot [string] -or
    $script:DreamSkinStartResultCategories -cnotcontains "$($result.category)" -or
    $result.appearanceRecovery -isnot [string] -or
    $script:DreamSkinStartAppearanceRecoveryStates -cnotcontains "$($result.appearanceRecovery)" -or
    ("$($result.outcome)" -ceq 'success' -and "$($result.category)" -cne 'none') -or
    ("$($result.outcome)" -ceq 'failure' -and "$($result.category)" -ceq 'none')) {
    throw 'Dream Skin start returned invalid structured result values.'
  }
  return $result
}

function Enter-DreamSkinOperationLock {
  param(
    [ValidateRange(0, 300000)]
    [int]$TimeoutMilliseconds = 0
  )
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex = [System.Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.Operation")
  $acquired = $false
  try {
    $acquired = $mutex.WaitOne($TimeoutMilliseconds)
  } catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
  }
  if (-not $acquired) {
    $mutex.Dispose()
    if ($TimeoutMilliseconds -eq 0) {
      throw 'Another Codex Dream Skin install, start, restore, or verify operation is already running.'
    }
    throw "Another Codex Dream Skin operation did not finish within $TimeoutMilliseconds ms."
  }
  return $mutex
}

function Exit-DreamSkinOperationLock {
  param([Parameter(Mandatory = $true)][System.Threading.Mutex]$Mutex)
  try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Assert-DreamSkinPort {
  param([Parameter(Mandatory = $true)][int]$Port)
  if ($Port -lt 1024 -or $Port -gt 65535) { throw "Port must be between 1024 and 65535: $Port" }
}

function Test-DreamSkinPathEqual {
  param([string]$Left, [string]$Right)
  if (-not $Left -or -not $Right) { return $false }
  try {
    return ([System.IO.Path]::GetFullPath($Left).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($Right).TrimEnd('\'))
  } catch {
    return $false
  }
}

function Test-DreamSkinPathWithin {
  param([string]$Path, [string]$Root)
  if (-not $Path -or -not $Root) { return $false }
  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Get-DreamSkinRuntimeEnginePaths {
  param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'))
  $root = Join-Path ([System.IO.Path]::GetFullPath($StateRoot)) 'engine'
  $scripts = Join-Path $root 'scripts'
  return [pscustomobject]@{
    Root = $root
    Scripts = $scripts
    Runtime = Join-Path $root 'runtime'
    Version = Join-Path $root 'VERSION'
    CommunityApply = Join-Path $scripts 'apply-community-theme.ps1'
    Start = Join-Path $scripts 'start-dream-skin.ps1'
    Restore = Join-Path $scripts 'restore-dream-skin.ps1'
    Tray = Join-Path $scripts 'tray-dream-skin.ps1'
    CheckUpdate = Join-Path $scripts 'check-update.ps1'
  }
}

function Test-DreamSkinTrayActive {
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex = [System.Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.Tray")
  $acquired = $false
  try {
    try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] {
      $acquired = $true
    }
    if ($acquired) {
      $mutex.ReleaseMutex()
      $acquired = $false
      return $false
    }
    return $true
  } finally {
    if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
  }
}

function Stop-DreamSkinTrayProcess {
  param(
    [string[]]$ScriptPaths = @(),
    [switch]$RequireStopped
  )
  if ($ScriptPaths.Count -eq 0) {
    $ScriptPaths = @((Get-DreamSkinRuntimeEnginePaths).Tray)
  }
  $normalized = @($ScriptPaths | ForEach-Object {
    try { [System.IO.Path]::GetFullPath($_) } catch { $null }
  } | Where-Object { $_ })
  $failures = @()
  try {
    $processes = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" `
      -ErrorAction Stop
    foreach ($process in $processes) {
      if ($process.ProcessId -eq $PID -or -not $process.CommandLine) { continue }
      $matchesTray = $false
      foreach ($scriptPath in $normalized) {
        if ($process.CommandLine.IndexOf($scriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
          $matchesTray = $true
          break
        }
      }
      if (-not $matchesTray) { continue }
      try {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        Wait-Process -Id $process.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
      } catch {
        $failures += "PID $($process.ProcessId): $($_.Exception.Message)"
      }
    }
  } catch {
    $failures += $_.Exception.Message
  }
  if ($failures.Count -gt 0) {
    $message = 'Could not close the Dream Skin tray automatically: ' + ($failures -join '; ')
    if ($RequireStopped) { throw $message }
    Write-Warning $message
  }
  if ($RequireStopped -and (Test-DreamSkinTrayActive)) {
    throw 'The Dream Skin tray is still active. Exit it and retry the operation.'
  }
}

function Assert-DreamSkinRuntimeTree {
  param([Parameter(Mandatory = $true)][string]$Path)
  $root = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Dream Skin runtime directory does not exist: $root"
  }
  if (-not (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue)) {
    throw 'Dream Skin managed-path validation is unavailable.'
  }
  Assert-DreamSkinNoReparseComponents -Path $root
  foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop) {
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Dream Skin runtime contains a junction or symbolic link: $($item.FullName)"
    }
  }
}

function Remove-DreamSkinRuntimeTree {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$StateRoot
  )
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $fullStateRoot = [System.IO.Path]::GetFullPath($StateRoot)
  if (-not (Test-DreamSkinPathWithin -Path $fullPath -Root $fullStateRoot)) {
    throw "Refusing to remove a runtime path outside the Dream Skin state root: $fullPath"
  }
  if (-not (Test-Path -LiteralPath $fullPath)) { return }
  Assert-DreamSkinRuntimeTree -Path $fullPath
  Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
}

function Install-DreamSkinRuntimeEngine {
  param(
    [Parameter(Mandatory = $true)][string]$SkillRoot,
    [Parameter(Mandatory = $true)][string]$StateRoot
  )
  if (-not (Get-Command Ensure-DreamSkinManagedDirectory -ErrorAction SilentlyContinue)) {
    throw 'Dream Skin managed-directory validation is unavailable.'
  }

  $sourceRoot = [System.IO.Path]::GetFullPath($SkillRoot)
  $fullStateRoot = [System.IO.Path]::GetFullPath($StateRoot)
  $engine = Get-DreamSkinRuntimeEnginePaths -StateRoot $fullStateRoot
  $required = @(
    'VERSION',
    'assets\dream-reference.jpg',
    'assets\dream-skin.css',
    'assets\renderer-inject.js',
    'assets\safe-css-policy.json',
    'assets\safe-css-validator.mjs',
    'assets\selectors.json',
    'assets\theme-package-validator.mjs',
    'assets\theme.json',
    'presets\preset-gothic-void-crusade\background.jpg',
    'presets\preset-gothic-void-crusade\theme.json',
    'scripts\apply-community-theme.ps1',
    'scripts\common-windows.ps1',
    'scripts\check-update.ps1',
    'scripts\config-utf8.ps1',
    'scripts\image-metadata.mjs',
    'scripts\video-decode-probe.mjs',
    'scripts\validate-video-file.mjs',
    'scripts\injector.mjs',
    'scripts\install-dream-skin.ps1',
    'scripts\localization-windows.ps1',
    'scripts\restore-dream-skin.ps1',
    'scripts\start-dream-skin.ps1',
    'scripts\theme-windows.ps1',
    'scripts\tray-dream-skin.ps1',
    'scripts\validate-safe-css-file.mjs',
    'scripts\verify-dream-skin.ps1'
  )
  $sourceHasBundledRuntime = Test-Path -LiteralPath (Join-Path $sourceRoot 'runtime') `
    -PathType Container
  if ($sourceHasBundledRuntime) {
    $required += @('runtime\node\node.exe', 'runtime\node\LICENSE')
  }
  foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $relative) -PathType Leaf)) {
      throw "Dream Skin runtime source is incomplete: $relative"
    }
  }
  $sourceDirectories = @('assets', 'scripts', 'presets')
  if ($sourceHasBundledRuntime) {
    $sourceDirectories += 'runtime'
  }
  foreach ($directoryName in $sourceDirectories) {
    $sourceDirectory = Join-Path $sourceRoot $directoryName
    if ((Test-DreamSkinPathEqual -Left $fullStateRoot -Right $sourceDirectory) -or
      (Test-DreamSkinPathWithin -Path $fullStateRoot -Root $sourceDirectory)) {
      throw "Dream Skin state root cannot be created inside its runtime source: $fullStateRoot"
    }
    Assert-DreamSkinRuntimeTree -Path $sourceDirectory
  }

  Ensure-DreamSkinManagedDirectory -Path $fullStateRoot -Root $fullStateRoot
  $token = [guid]::NewGuid().ToString('N')
  $stagingRoot = Join-Path $fullStateRoot ".engine-staging-$token"
  $backupRoot = Join-Path $fullStateRoot ".engine-backup-$token"
  Ensure-DreamSkinManagedDirectory -Path $stagingRoot -Root $fullStateRoot

  try {
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'VERSION') -Destination $stagingRoot `
      -Force -ErrorAction Stop
    foreach ($directoryName in $sourceDirectories) {
      Copy-Item -LiteralPath (Join-Path $sourceRoot $directoryName) -Destination $stagingRoot `
        -Recurse -Force -ErrorAction Stop
    }
    Assert-DreamSkinRuntimeTree -Path $stagingRoot
    foreach ($relative in $required) {
      if (-not (Test-Path -LiteralPath (Join-Path $stagingRoot $relative) -PathType Leaf)) {
        throw "Staged Dream Skin runtime is incomplete: $relative"
      }
    }

    $sourcePrefix = $sourceRoot.TrimEnd('\') + '\'
    $sourceFileRoots = @($sourceDirectories | ForEach-Object { Join-Path $sourceRoot $_ })
    $stagedFileRoots = @($sourceDirectories | ForEach-Object { Join-Path $stagingRoot $_ })
    $sourceFiles = @((Get-Item -LiteralPath (Join-Path $sourceRoot 'VERSION'))) + @(
      Get-ChildItem -LiteralPath $sourceFileRoots -Recurse -File -Force -ErrorAction Stop
    )
    $stagedFiles = @((Get-Item -LiteralPath (Join-Path $stagingRoot 'VERSION'))) + @(
      Get-ChildItem -LiteralPath $stagedFileRoots -Recurse -File -Force -ErrorAction Stop
    )
    if ($sourceFiles.Count -ne $stagedFiles.Count) {
      throw 'Staged Dream Skin runtime file count does not match its source.'
    }
    foreach ($sourceFile in $sourceFiles) {
      $relative = $sourceFile.FullName.Substring($sourcePrefix.Length)
      $stagedFile = Join-Path $stagingRoot $relative
      if (-not (Test-Path -LiteralPath $stagedFile -PathType Leaf) -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceFile.FullName).Hash -cne
        (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedFile).Hash) {
        throw "Staged Dream Skin runtime failed hash verification: $relative"
      }
    }

    # Unblock only verified managed copies so shortcuts can honor RemoteSigned instead of bypassing policy.
    foreach ($runtimeScript in Get-ChildItem -LiteralPath (Join-Path $stagingRoot 'scripts') `
      -Filter '*.ps1' -Recurse -File -Force -ErrorAction Stop) {
      Unblock-File -LiteralPath $runtimeScript.FullName -ErrorAction Stop
    }
    if (Test-Path -LiteralPath (Join-Path $stagingRoot 'runtime') -PathType Container) {
      foreach ($runtimeFile in Get-ChildItem -LiteralPath (Join-Path $stagingRoot 'runtime') `
        -Recurse -File -Force -ErrorAction Stop) {
        Unblock-File -LiteralPath $runtimeFile.FullName -ErrorAction Stop
      }
    }

    $hasBackup = $false
    if (Test-Path -LiteralPath $engine.Root) {
      Assert-DreamSkinRuntimeTree -Path $engine.Root
      Move-Item -LiteralPath $engine.Root -Destination $backupRoot -ErrorAction Stop
      $hasBackup = $true
    }
    try {
      Move-Item -LiteralPath $stagingRoot -Destination $engine.Root -ErrorAction Stop
    } catch {
      $installError = $_.Exception.Message
      if ($hasBackup -and -not (Test-Path -LiteralPath $engine.Root)) {
        try {
          Move-Item -LiteralPath $backupRoot -Destination $engine.Root -ErrorAction Stop
          $hasBackup = $false
        } catch {
          throw "Dream Skin runtime update failed and its previous engine could not be restored. Backup preserved at ${backupRoot}: $installError"
        }
      }
      throw
    }
    if ($hasBackup) {
      try { Remove-DreamSkinRuntimeTree -Path $backupRoot -StateRoot $fullStateRoot } catch {
        try {
          Write-Warning "Installed the new runtime but could not remove its previous backup: $($_.Exception.Message)"
        } catch {
          # Cleanup must never make a committed runtime update look unsuccessful.
        }
      }
    }
    return Get-DreamSkinRuntimeEnginePaths -StateRoot $fullStateRoot
  } finally {
    if (Test-Path -LiteralPath $stagingRoot) {
      try { Remove-DreamSkinRuntimeTree -Path $stagingRoot -StateRoot $fullStateRoot } catch {
        try {
          Write-Warning "Could not remove the staged Dream Skin runtime: $($_.Exception.Message)"
        } catch {
          # Cleanup must never mask the runtime installation result.
        }
      }
    }
  }
}

function Test-DreamSkinCommandLineToken {
  param([string]$CommandLine, [string]$Token)
  if (-not $CommandLine -or -not $Token) { return $false }
  $pattern = '(?i)(?:^|[\s"])' + [regex]::Escape($Token) + '(?=$|[\s"])'
  return [regex]::IsMatch($CommandLine, $pattern)
}

function Get-DreamSkinCodexDebugArgumentStatus {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes,
    [Parameter(Mandatory = $true)][int]$Port
  )
  Assert-DreamSkinPort -Port $Port
  $flag = "--remote-debugging-port=$Port"
  $encodedFlag = [Uri]::EscapeDataString($flag)
  $sawReadableCommandLine = $false
  $sawProtocolRedirect = $false
  foreach ($process in $Processes) {
    $commandLine = "$($process.CommandLine)"
    if (-not $commandLine) { continue }
    $sawReadableCommandLine = $true
    $protocolPattern = '(?i)(?<!\S)"?(?<url>codex://[^\s"]*)"?'
    $protocolMatches = [regex]::Matches($commandLine, $protocolPattern)
    foreach ($protocolMatch in $protocolMatches) {
      $protocolArgument = $protocolMatch.Groups['url'].Value
      if ($protocolArgument.IndexOf($encodedFlag, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $protocolArgument.IndexOf($flag, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $sawProtocolRedirect = $true
      }
    }
    $rawArguments = [regex]::Replace($commandLine, $protocolPattern, ' ')
    if (Test-DreamSkinCommandLineToken -CommandLine $rawArguments -Token $flag) {
      return 'forwarded'
    }
  }
  if ($sawProtocolRedirect) { return 'protocol-redirected' }
  if ($sawReadableCommandLine) { return 'not-forwarded' }
  return 'uninspectable'
}

function ConvertTo-DreamSkinProcessArgument {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
  if ($Value.Contains('"')) { throw 'Process arguments containing a double quote are not supported.' }
  if ($Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '\s') { return $Value }
  $escaped = [regex]::Replace($Value, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}

function ConvertTo-DreamSkinArgumentLine {
  param([AllowEmptyCollection()][string[]]$Arguments = @())
  return (($Arguments | ForEach-Object { ConvertTo-DreamSkinProcessArgument -Value $_ }) -join ' ')
}

function Get-DreamSkinProcessExecutablePath {
  param([Parameter(Mandatory = $true)][object]$ProcessInfo)
  if ($ProcessInfo.ExecutablePath) { return "$($ProcessInfo.ExecutablePath)" }
  try {
    $process = Get-Process -Id ([int]$ProcessInfo.ProcessId) -ErrorAction Stop
    if ($process.Path) { return "$($process.Path)" }
    return "$($process.MainModule.FileName)"
  } catch {
    return $null
  }
}

# Windows PowerShell 5.1 promotes redirected native-command stderr lines to
# ErrorRecords; while $ErrorActionPreference is 'Stop' the first stderr line
# becomes a terminating NativeCommandError before the exit code can be read.
# Run the command with the preference relaxed and report output + exit code.
function Invoke-DreamSkinNative {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$ArgumentList = @(),
    [switch]$DiscardStderr
  )
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($DiscardStderr) {
      $nativeOutput = @(& $FilePath @ArgumentList 2>$null)
    } else {
      $nativeOutput = @(& $FilePath @ArgumentList 2>&1)
    }
    $exitCode = $LASTEXITCODE
    $output = @($nativeOutput | ForEach-Object { "$_" })
    return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
  } finally {
    $ErrorActionPreference = $previousPreference
  }
}

function ConvertFrom-DreamSkinUtf8Base64 {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
  )
  try {
    $bytes = [Convert]::FromBase64String($Value.Trim())
    return ([System.Text.UTF8Encoding]::new($false, $true)).GetString($bytes)
  } catch {
    throw 'The native UTF-8 probe returned invalid data.'
  }
}

function Import-DreamSkinPowerShellSecurityModule {
  $command = Get-Command Get-AuthenticodeSignature -CommandType Cmdlet -ErrorAction SilentlyContinue
  if ($command) { return }
  try {
    Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
  } catch {
    $modulePath = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
      throw "PowerShell security module is unavailable: $($_.Exception.Message)"
    }
    Import-Module $modulePath -ErrorAction Stop
  }
  $command = Get-Command Get-AuthenticodeSignature -CommandType Cmdlet -ErrorAction SilentlyContinue
  if (-not $command) {
    throw 'PowerShell security module loaded, but Get-AuthenticodeSignature is unavailable.'
  }
}

function Assert-DreamSkinTrustedNodeImage {
  param([Parameter(Mandatory = $true)][string]$Path)

  # Runs BEFORE the binary is ever executed. Get-DreamSkinValidatedNodeRuntime
  # learns the version by running `node -p`, so any authenticity check placed
  # after that point would already have executed attacker-controlled code.
  Import-DreamSkinPowerShellSecurityModule
  $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
  if ("$($signature.Status)" -ine 'Valid') {
    throw "The Node.js runtime is not validly signed: $Path ($($signature.Status))."
  }
  $subject = "$($signature.SignerCertificate.Subject)"
  # Publisher names observed on official Node.js builds. The subject is echoed
  # in the failure so an unexpected-but-legitimate publisher can be identified
  # and added deliberately, rather than the check being loosened blindly.
  if ($subject -notmatch '(?i)O=("?)(OpenJS Foundation|Node\.js Foundation|Microsoft Corporation|GitHub, Inc\.)') {
    throw "The Node.js runtime is signed by an unexpected publisher: $subject"
  }
}

function Get-DreamSkinValidatedNodeRuntime {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$MinimumMajor = 22
  )
  $candidate = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "Node.js runtime does not exist: $candidate"
  }
  Assert-DreamSkinTrustedNodeImage -Path $candidate
  $versionProbe = Invoke-DreamSkinNative -FilePath $candidate -ArgumentList @('-p', 'process.versions.node') -DiscardStderr
  $version = ($versionProbe.Output -join '').Trim()
  if ($versionProbe.ExitCode -ne 0 -or -not $version) { throw 'The Node.js runtime could not be validated.' }
  # Windows PowerShell 5.1 decodes redirected native stdout through the active
  # console code page. Node writes UTF-8, so a non-ASCII temporary path can be
  # corrupted before Test-Path sees it. Keep the transport ASCII-only and
  # decode the original UTF-8 bytes explicitly; never fall back to the
  # candidate when the identity probe is invalid.
  $pathProbe = Invoke-DreamSkinNative -FilePath $candidate -ArgumentList @(
    '-e', "process.stdout.write(Buffer.from(process.execPath, 'utf8').toString('base64'))"
  ) -DiscardStderr
  $encodedRuntimePath = ($pathProbe.Output -join '').Trim()
  $runtimePath = ''
  if ($pathProbe.ExitCode -eq 0 -and $encodedRuntimePath) {
    try {
      $runtimePath = ConvertFrom-DreamSkinUtf8Base64 -Value $encodedRuntimePath
    } catch {
      $runtimePath = ''
    }
  }
  $runtimePathExists = $false
  if ($runtimePath) {
    try { $runtimePathExists = Test-Path -LiteralPath $runtimePath -PathType Leaf } catch {}
  }
  if ($pathProbe.ExitCode -ne 0 -or -not $runtimePath -or -not $runtimePathExists) {
    $reason = 'path-not-found'
    if ($pathProbe.ExitCode -ne 0) { $reason = 'probe-exit' }
    elseif (-not $encodedRuntimePath) { $reason = 'empty-output' }
    elseif (-not $runtimePath) { $reason = 'invalid-output' }
    throw "The Node.js executable path could not be validated ($reason)."
  }
  $major = 0
  if (-not [int]::TryParse(($version -split '\.')[0], [ref]$major) -or $major -lt $MinimumMajor) {
    throw "Node.js $MinimumMajor or newer is required; found $version at $runtimePath."
  }
  return [pscustomobject]@{ Path = $runtimePath; Version = $version; Major = $major }
}

$script:DreamSkinNodeRuntimeCache = $null

# Validating the bundled runtime (Authenticode plus two identity probes) costs
# about a second, and every manager action runs in a new PowerShell process.
# A full validation of the bundled node.exe is therefore remembered by the
# SHA-256 of its bytes for a day; a changed file never matches and is validated
# again. The PATH fallback is never remembered: PATH can be redirected without
# touching the engine folder, so it keeps the full validation in every process.
$script:DreamSkinNodeRuntimeRecordPath = Join-Path `
  ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexDreamSkinManager\node-runtime-v1.json'
$script:DreamSkinNodeRuntimeRecordMaxAge = [TimeSpan]::FromHours(24)

function Get-DreamSkinFileSha256 {
  param([Parameter(Mandatory = $true)][string]$Path)
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
      return ([System.BitConverter]::ToString($hasher.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
    } finally {
      $hasher.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Read-DreamSkinNodeRuntimeRecords {
  try {
    $recordPath = $script:DreamSkinNodeRuntimeRecordPath
    if (-not $recordPath -or -not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return @() }
    $parsed = [System.IO.File]::ReadAllText($recordPath) | ConvertFrom-Json -ErrorAction Stop
    if ("$($parsed.version)" -cne '1') { return @() }
    return @($parsed.entries | Where-Object { $_ -and "$($_.path)" -and "$($_.sha256)" -cmatch '^[0-9a-f]{64}$' })
  } catch {
    return @()
  }
}

function Get-DreamSkinRememberedNodeRuntime {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Sha256,
    [int]$MinimumMajor = 22
  )
  foreach ($entry in Read-DreamSkinNodeRuntimeRecords) {
    if (-not (Test-DreamSkinPathEqual -Left "$($entry.path)" -Right $Path) -or "$($entry.sha256)" -cne $Sha256) {
      continue
    }
    # PowerShell 7 turns ISO strings into dates; Windows PowerShell keeps text.
    $validatedAt = [DateTime]::MinValue
    if ($entry.validatedAt -is [DateTime]) {
      $validatedAt = $entry.validatedAt.ToUniversalTime()
    } elseif (-not [DateTime]::TryParse("$($entry.validatedAt)", [System.Globalization.CultureInfo]::InvariantCulture,
      ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal),
      [ref]$validatedAt)) {
      return $null
    }
    $age = [DateTime]::UtcNow - $validatedAt
    if ($age -lt [TimeSpan]::Zero -or $age -gt $script:DreamSkinNodeRuntimeRecordMaxAge) { return $null }
    $major = 0
    if (-not [int]::TryParse("$($entry.major)", [ref]$major) -or $major -lt $MinimumMajor) { return $null }
    if (-not (Test-DreamSkinPathEqual -Left "$($entry.runtimePath)" -Right $Path)) { return $null }
    return [pscustomobject]@{ Path = "$($entry.runtimePath)"; Version = "$($entry.version)"; Major = $major }
  }
  return $null
}

function Save-DreamSkinNodeRuntimeRecord {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Sha256,
    [Parameter(Mandatory = $true)][object]$Runtime
  )
  try {
    # Only a runtime that resolved to the bundled executable itself is remembered.
    if (-not (Test-DreamSkinPathEqual -Left "$($Runtime.Path)" -Right $Path)) { return }
    $others = @(Read-DreamSkinNodeRuntimeRecords |
      Where-Object { -not (Test-DreamSkinPathEqual -Left "$($_.path)" -Right $Path) })
    $entry = [pscustomobject][ordered]@{
      path = $Path
      sha256 = $Sha256
      runtimePath = "$($Runtime.Path)"
      version = "$($Runtime.Version)"
      major = [int]$Runtime.Major
      validatedAt = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $records = [ordered]@{ version = 1; entries = @((@($entry) + $others) | Select-Object -First 8) }
    $directory = Split-Path -Parent $script:DreamSkinNodeRuntimeRecordPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
      New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Write-DreamSkinUtf8FileAtomically -Path $script:DreamSkinNodeRuntimeRecordPath `
      -Content ($records | ConvertTo-Json -Depth 4)
  } catch {
    # A missing record only costs the next process a full validation.
  }
}

function Get-DreamSkinNodeRuntime {
  param([int]$MinimumMajor = 22)

  # One manager action resolves the runtime several times (metadata checks,
  # video probes, live apply). Reuse the validated result within this process
  # while the executable keeps the same path, size and timestamp; any change
  # repeats the full Authenticode and identity validation below.
  $cached = $script:DreamSkinNodeRuntimeCache
  if ($null -ne $cached -and $cached.Runtime.Major -ge $MinimumMajor) {
    try {
      $current = Get-Item -LiteralPath $cached.Runtime.Path -ErrorAction Stop
      if ($current.Length -eq $cached.Length -and $current.LastWriteTimeUtc -eq $cached.LastWriteTimeUtc) {
        return $cached.Runtime
      }
    } catch {}
    $script:DreamSkinNodeRuntimeCache = $null
  }
  $runtime = Resolve-DreamSkinNodeRuntime -MinimumMajor $MinimumMajor
  try {
    $item = Get-Item -LiteralPath $runtime.Path -ErrorAction Stop
    $script:DreamSkinNodeRuntimeCache = [pscustomobject]@{
      Runtime = $runtime
      Length = $item.Length
      LastWriteTimeUtc = $item.LastWriteTimeUtc
    }
  } catch {
    $script:DreamSkinNodeRuntimeCache = $null
  }
  return $runtime
}

function Resolve-DreamSkinNodeRuntime {
  param([int]$MinimumMajor = 22)

  # The runtime that runs Safe CSS validation, theme-package validation, image
  # metadata limits and the injector must not be redirectable: anyone able to
  # write HKCU\Environment (no admin needed) could otherwise point every
  # validator at their own node.exe and bypass all of them at once. So there is
  # no environment-variable override -- macOS pins the same way, see
  # require_signed_node_runtime in macos/scripts/common-macos.sh.
  #
  # An installed engine always ships runtime\node\node.exe and must use it. The
  # repository source tree has no bundled copy (the installer downloads it), so
  # running the suite from source falls back to PATH -- but that candidate goes
  # through the exact same Authenticode gate, so a hostile node.exe on PATH is
  # rejected before it is ever executed.
  $runtimeRoot = Split-Path -Parent $PSScriptRoot
  $bundledNode = Join-Path $runtimeRoot 'runtime\node\node.exe'
  if (Test-Path -LiteralPath $bundledNode -PathType Leaf) {
    $bundledNode = [System.IO.Path]::GetFullPath($bundledNode)
    $digest = $null
    try { $digest = Get-DreamSkinFileSha256 -Path $bundledNode } catch {}
    if ($digest) {
      $remembered = Get-DreamSkinRememberedNodeRuntime -Path $bundledNode -Sha256 $digest -MinimumMajor $MinimumMajor
      if ($null -ne $remembered) { return $remembered }
    }
    $runtime = Get-DreamSkinValidatedNodeRuntime -Path $bundledNode -MinimumMajor $MinimumMajor
    # Remember the validation only if the bytes did not change while it ran.
    $after = $null
    if ($digest) { try { $after = Get-DreamSkinFileSha256 -Path $bundledNode } catch {} }
    if ($digest -and $after -ceq $digest) {
      Save-DreamSkinNodeRuntimeRecord -Path $bundledNode -Sha256 $digest -Runtime $runtime
    }
    return $runtime
  }

  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if (-not $command) { $command = Get-Command node -ErrorAction SilentlyContinue }
  if (-not $command) {
    throw "The bundled Node.js runtime is missing ($bundledNode) and Node.js $MinimumMajor or newer was not found in PATH."
  }
  return Get-DreamSkinValidatedNodeRuntime -Path $command.Source -MinimumMajor $MinimumMajor
}

function ConvertTo-DreamSkinCodexInstall {
  param(
    [Parameter(Mandatory = $true)][object]$Package,
    [AllowNull()][object]$Manifest
  )
  $supportedPackageNames = @(Get-DreamSkinSupportedPackageNames)
  if ("$($Package.Name)" -notin $supportedPackageNames -or -not $Package.InstallLocation -or
    -not $Package.PackageFullName -or -not $Package.PackageFamilyName -or
    "$($Package.SignatureKind)" -ine 'Store' -or [bool]$Package.IsDevelopmentMode) {
    return $null
  }
  $packageRoot = "$($Package.InstallLocation)"
  $executable = Join-Path $packageRoot 'app\ChatGPT.exe'
  if (-not (Test-Path -LiteralPath $executable)) { return $null }
  try {
    if (-not $PSBoundParameters.ContainsKey('Manifest')) {
      $Manifest = Get-AppxPackageManifest -Package $Package -ErrorAction Stop
    }
    $applications = @($Manifest.Package.Applications.Application | Where-Object {
      "$($_.Executable)".Replace('/', '\') -ieq 'app\ChatGPT.exe'
    })
    if ($applications.Count -ne 1) { return $null }
    $applicationId = "$($applications[0].Id)"
  } catch {
    return $null
  }
  $packageFamilyName = "$($Package.PackageFamilyName)"
  if ($packageFamilyName -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or
    $applicationId -cnotmatch '^[A-Za-z0-9._-]{1,64}$') {
    return $null
  }
  return [pscustomobject]@{
    PackageRoot = $packageRoot
    Executable = $executable
    Version = "$($Package.Version)"
    PackageFullName = "$($Package.PackageFullName)"
    PackageFamilyName = $packageFamilyName
    ApplicationId = $applicationId
    AppUserModelId = "$packageFamilyName!$applicationId"
    SignatureKind = "$($Package.SignatureKind)"
  }
}

function Get-DreamSkinSupportedPackageNames {
  # The unified client runs ChatGPT.exe but retains the OpenAI.Codex Store
  # package identity. ChatGPT Classic is a different, unsupported shell.
  return @('OpenAI.Codex')
}

# Opt-in per process (start-dream-skin.ps1 enables it): one startup resolves
# the registered packages three times, each Appx query costing about a second.
# The short lifetime bounds staleness if a long-lived host ever enables it.
$script:DreamSkinRegisteredCodexInstallsCacheEnabled = $false
$script:DreamSkinRegisteredCodexInstallsCache = $null
$script:DreamSkinRegisteredCodexInstallsCachedAt = [DateTime]::MinValue

function Get-DreamSkinRegisteredCodexInstalls {
  if ($script:DreamSkinRegisteredCodexInstallsCacheEnabled -and
    $null -ne $script:DreamSkinRegisteredCodexInstallsCache -and
    ([DateTime]::UtcNow - $script:DreamSkinRegisteredCodexInstallsCachedAt).TotalSeconds -lt 60) {
    return @($script:DreamSkinRegisteredCodexInstallsCache)
  }
  $packages = @()
  foreach ($packageName in @(Get-DreamSkinSupportedPackageNames)) {
    try {
      $packages += @(Get-AppxPackage -Name $packageName -ErrorAction Stop)
    } catch {
      # A missing registered Codex package is reported by the caller.
    }
  }
  # Keep the property list explicit for Windows PowerShell 5.1; placing a
  # second property after a parameter switch is parsed as an argument error.
  $packages = @($packages | Sort-Object -Property @(
    @{ Expression = 'Version'; Descending = $true },
    @{ Expression = 'PackageFullName'; Descending = $false }
  ) -Unique)
  $installs = @()
  foreach ($package in $packages) {
    $install = ConvertTo-DreamSkinCodexInstall -Package $package
    if ($null -ne $install) { $installs += $install }
  }
  if ($script:DreamSkinRegisteredCodexInstallsCacheEnabled) {
    $script:DreamSkinRegisteredCodexInstallsCache = @($installs)
    $script:DreamSkinRegisteredCodexInstallsCachedAt = [DateTime]::UtcNow
  }
  return $installs
}

function Get-DreamSkinCodexInstall {
  $installs = @(Get-DreamSkinRegisteredCodexInstalls)
  if ($installs.Count -eq 0) { throw 'The official OpenAI Codex/ChatGPT Store package is not installed or its identity cannot be validated.' }
  return $installs[0]
}

# The skinned Codex must run on its own profile (CDP ignores the default
# user-data-dir), which gave it a fresh Statsig device id and with it a
# different experiment group than the user's normal Codex: another UI variant
# and language, which the skin and its verification were not written for.
# Before a launch (Codex is closed), adopt the normal profile's device id.
# Only that id is copied; sign-in and conversation data are never touched.
function Sync-DreamSkinProfileStatsigIdentity {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][string]$ProfilePath
  )
  try {
    $family = "$($Codex.PackageFamilyName)"
    if ($family -cnotmatch '^[A-Za-z0-9._-]{1,128}$') { return 'skipped (package family unknown)' }
    $roaming = Join-Path $env:LOCALAPPDATA "Packages\$family\LocalCache\Roaming"
    if (-not (Test-Path -LiteralPath $roaming -PathType Container)) { return 'skipped (no packaged profile root)' }
    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Container)) { return 'skipped (no skin profile directory)' }
    $skinState = Join-Path $ProfilePath 'statsig-state.json'
    # The normal profile is the packaged one most recently used by Codex.
    $source = @(Get-ChildItem -LiteralPath $roaming -Recurse -Depth 4 -Filter 'statsig-state.json' -File -ErrorAction SilentlyContinue |
      Where-Object {
        -not (Test-DreamSkinPathEqual -Left $_.FullName -Right $skinState) -and
        (Test-Path -LiteralPath (Join-Path $_.DirectoryName 'Local State') -PathType Leaf)
      } |
      Sort-Object -Property @{ Expression = { (Get-Item -LiteralPath (Join-Path $_.DirectoryName 'Local State')).LastWriteTimeUtc } } -Descending |
      Select-Object -First 1)
    if ($source.Count -eq 0) { return 'skipped (normal profile not found)' }
    $stableId = "$((Get-Content -LiteralPath $source[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json).'statsig-stable-id')"
    if ($stableId -cnotmatch '^[A-Za-z0-9-]{8,64}$') { return 'skipped (normal profile has no device id)' }
    if (Test-Path -LiteralPath $skinState -PathType Leaf) {
      $current = "$((Get-Content -LiteralPath $skinState -Raw -Encoding UTF8 | ConvertFrom-Json).'statsig-stable-id')"
      if ($current -ceq $stableId) { return 'already shared' }
    }
    $json = '{"statsig-stable-id":"' + $stableId + '"}'
    $encoding = New-Object System.Text.UTF8Encoding($false)
    # Keep the profile's original id once, so the change can be reverted.
    $original = $skinState + '.before-dreamskin-sync'
    if ((Test-Path -LiteralPath $skinState -PathType Leaf) -and -not (Test-Path -LiteralPath $original)) {
      Copy-Item -LiteralPath $skinState -Destination $original
    }
    foreach ($target in @($skinState, ($skinState + '.bak'))) {
      Assert-DreamSkinNoReparseComponents -Path $target
      [System.IO.File]::WriteAllText($target, $json, $encoding)
    }
    return 'adopted from the normal profile'
  } catch {
    return "skipped ($($_.Exception.Message))"
  }
}

function Initialize-DreamSkinPackageLauncher {
  if ('CodexDreamSkin.PackageLauncher' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexDreamSkin {
  [Flags]
  internal enum ActivateOptions : uint {
    None = 0
  }

  [ComImport]
  [Guid("2e941141-7f97-4756-ba1d-9decde894a3d")]
  [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  internal interface IApplicationActivationManager {
    [PreserveSig]
    int ActivateApplication(
      [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
      [MarshalAs(UnmanagedType.LPWStr)] string arguments,
      ActivateOptions options,
      out uint processId);
  }

  [ComImport]
  [Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
  internal class ApplicationActivationManager {}

  public static class PackageLauncher {
    public static uint Launch(string appUserModelId, string arguments) {
      var manager = (IApplicationActivationManager)new ApplicationActivationManager();
      try {
        uint processId;
        int result = manager.ActivateApplication(
          appUserModelId,
          arguments ?? string.Empty,
          ActivateOptions.None,
          out processId);
        Marshal.ThrowExceptionForHR(result);
        return processId;
      } finally {
        if (Marshal.IsComObject(manager)) Marshal.FinalReleaseComObject(manager);
      }
    }
  }
}
'@
}

function Start-DreamSkinCodex {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][string[]]$Arguments = @()
  )
  $appUserModelId = "$($Codex.AppUserModelId)"
  if ($appUserModelId -cnotmatch '^[A-Za-z0-9._-]{1,128}![A-Za-z0-9._-]{1,64}$') {
    throw 'The registered Codex AppUserModelId is unavailable or invalid.'
  }
  Initialize-DreamSkinPackageLauncher
  $argumentLine = ConvertTo-DreamSkinArgumentLine -Arguments $Arguments
  $processId = [CodexDreamSkin.PackageLauncher]::Launch($appUserModelId, $argumentLine)
  if ($processId -le 0) { throw 'Windows did not return a Codex process ID after package activation.' }
  return $processId
}

function Assert-DreamSkinCodexDirectLaunchTarget {
  param([Parameter(Mandatory = $true)][object]$Codex)
  $expectedExecutable = if ($Codex.PackageRoot) {
    Join-Path "$($Codex.PackageRoot)" 'app\ChatGPT.exe'
  } else {
    $null
  }
  $expectedAppUserModelId = if ($Codex.PackageFamilyName -and $Codex.ApplicationId) {
    "$($Codex.PackageFamilyName)!$($Codex.ApplicationId)"
  } else {
    $null
  }
  if ("$($Codex.SignatureKind)" -ine 'Store' -or -not $Codex.PackageFullName -or
    -not $expectedExecutable -or -not $expectedAppUserModelId -or
    "$($Codex.AppUserModelId)" -cne $expectedAppUserModelId -or
    -not (Test-DreamSkinPathEqual -Left "$($Codex.Executable)" -Right $expectedExecutable) -or
    -not (Test-Path -LiteralPath $expectedExecutable -PathType Leaf)) {
    throw 'Direct launch requires the exact executable from the validated OpenAI Codex/ChatGPT Store package.'
  }
}

function Start-DreamSkinCodexDirect {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments
  )
  Assert-DreamSkinCodexDirectLaunchTarget -Codex $Codex
  $argumentLine = ConvertTo-DreamSkinArgumentLine -Arguments $Arguments
  $process = Start-Process -FilePath "$($Codex.Executable)" -ArgumentList $argumentLine `
    -PassThru -ErrorAction Stop
  try {
    if ($process.Id -le 0) { throw 'Windows did not return a Codex process ID after direct launch.' }
    return $process.Id
  } finally {
    $process.Dispose()
  }
}

function Get-DreamSkinDirectLaunchFailureKind {
  param([Parameter(Mandatory = $true)][System.Exception]$Exception)
  $current = $Exception
  while ($null -ne $current) {
    if ($current -is [System.UnauthorizedAccessException] -or
      ($current -is [System.ComponentModel.Win32Exception] -and $current.NativeErrorCode -eq 5) -or
      $current.HResult -eq -2147024891) {
      return 'access-denied'
    }
    $current = $current.InnerException
  }
  return 'start-failed'
}

function Wait-DreamSkinCodexDebugArgumentStatus {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][int]$Port,
    [int]$TimeoutSeconds = 5
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $lastStatus = 'uninspectable'
  do {
    $processes = @(Get-DreamSkinCodexProcesses -Codex $Codex)
    $lastStatus = Get-DreamSkinCodexDebugArgumentStatus -Processes $processes -Port $Port
    if ($lastStatus -in @('forwarded', 'protocol-redirected')) { return $lastStatus }
    if ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
  } while ((Get-Date) -lt $deadline)
  return $lastStatus
}

function Start-DreamSkinCodexForDebugging {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
    [Parameter(Mandatory = $true)][int]$Port,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds
  )
  $preservedProcessIds = if ($PSBoundParameters.ContainsKey('PreserveProcessIds')) {
    @($PreserveProcessIds)
  } else {
    @(Get-DreamSkinCodexProcesses -Codex $Codex | ForEach-Object { [int]$_.ProcessId })
  }
  $packageProcessId = Start-DreamSkinCodex -Codex $Codex -Arguments $Arguments
  $packageStatus = Wait-DreamSkinCodexDebugArgumentStatus -Codex $Codex -Port $Port
  if ($packageStatus -ne 'protocol-redirected') {
    return [pscustomobject]@{
      ProcessId = $packageProcessId
      Strategy = 'package-activation'
      ArgumentStatus = $packageStatus
      PackageArgumentStatus = $packageStatus
    }
  }

  try {
    Stop-DreamSkinCodex -Codex $Codex -PreserveProcessIds $preservedProcessIds -AllowForce
  } catch {
    throw (New-DreamSkinStartException -Category 'cdp-launch-failed' `
      -Message 'Codex package activation did not retain the CDP arguments, and its process could not be closed safely.' `
      -InnerException $_.Exception)
  }

  try {
    $directProcessId = Start-DreamSkinCodexDirect -Codex $Codex -Arguments $Arguments
  } catch {
    $failureKind = Get-DreamSkinDirectLaunchFailureKind -Exception $_.Exception
    $category = if ($failureKind -ceq 'access-denied') {
      'cdp-direct-access-denied'
    } else {
      'cdp-launch-failed'
    }
    throw (New-DreamSkinStartException -Category $category `
      -Message "Codex $($Codex.Version) converted the CDP argument into a codex:// navigation path. Direct launch of the validated Store executable failed ($failureKind), so this Codex/Windows combination cannot expose the Dream Skin debugging endpoint without modifying the protected app package." `
      -InnerException $_.Exception)
  }

  $directStatus = Wait-DreamSkinCodexDebugArgumentStatus -Codex $Codex -Port $Port
  if ($directStatus -in @('protocol-redirected', 'not-forwarded')) {
    try {
      Stop-DreamSkinCodex -Codex $Codex -PreserveProcessIds $preservedProcessIds -AllowForce
    } catch {
      throw (New-DreamSkinStartException -Category 'cdp-endpoint-unavailable' `
        -Message 'Direct Codex launch did not retain the CDP arguments and could not be closed safely.' `
        -InnerException $_.Exception)
    }
    throw (New-DreamSkinStartException -Category 'cdp-endpoint-unavailable' `
      -Message "Codex $($Codex.Version) did not retain the CDP argument during package activation or validated direct launch. Dream Skin cannot run without modifying the protected app package." `
      -InnerException $null)
  }

  return [pscustomobject]@{
    ProcessId = $directProcessId
    Strategy = 'direct-store-executable'
    ArgumentStatus = $directStatus
    PackageArgumentStatus = $packageStatus
  }
}

function Get-DreamSkinCodexStatePathCandidate {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or -not $State.codexExe -or -not $State.codexPackageRoot) { return $null }
  $executable = "$($State.codexExe)"
  $packageRoot = "$($State.codexPackageRoot)"
  $expectedExecutable = Join-Path $packageRoot 'app\ChatGPT.exe'
  if (-not (Test-DreamSkinPathEqual -Left $executable -Right $expectedExecutable)) { return $null }
  return [pscustomobject]@{
    PackageRoot = $packageRoot
    Executable = $executable
    Version = "$($State.codexVersion)"
    FromState = $true
    RegisteredPackageVerified = $false
  }
}

function Resolve-DreamSkinCodexInstallFromState {
  param(
    [AllowNull()][object]$State,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$RegisteredInstalls
  )
  $candidate = Get-DreamSkinCodexStatePathCandidate -State $State
  if ($null -eq $candidate) { return $null }

  $hasFullName = [bool]$State.codexPackageFullName
  $hasFamilyName = [bool]$State.codexPackageFamilyName
  if ($hasFullName -xor $hasFamilyName) { return $null }
  foreach ($install in $RegisteredInstalls) {
    $pathMatches = (Test-DreamSkinPathEqual -Left $candidate.PackageRoot -Right $install.PackageRoot) -and
      (Test-DreamSkinPathEqual -Left $candidate.Executable -Right $install.Executable)
    if (-not $pathMatches) { continue }
    if ($hasFullName -and ("$($State.codexPackageFullName)" -ine $install.PackageFullName -or
      "$($State.codexPackageFamilyName)" -ine $install.PackageFamilyName)) {
      continue
    }
    return [pscustomobject]@{
      PackageRoot = $install.PackageRoot
      Executable = $install.Executable
      Version = $install.Version
      PackageFullName = $install.PackageFullName
      PackageFamilyName = $install.PackageFamilyName
      ApplicationId = $install.ApplicationId
      AppUserModelId = $install.AppUserModelId
      SignatureKind = $install.SignatureKind
      FromState = $true
      RegisteredPackageVerified = $true
    }
  }
  return $null
}

function Get-DreamSkinCodexInstallFromState {
  param([AllowNull()][object]$State)
  try { $installs = @(Get-DreamSkinRegisteredCodexInstalls) } catch { return $null }
  return Resolve-DreamSkinCodexInstallFromState -State $State -RegisteredInstalls $installs
}

function Test-DreamSkinWebSocketUrl {
  param([string]$Value, [int]$Port)
  try {
    $uri = [Uri]$Value
    $hostName = $uri.Host.ToLowerInvariant()
    return ($uri.IsAbsoluteUri -and $uri.Scheme -eq 'ws' -and $uri.Port -eq $Port -and
      $hostName -in @('127.0.0.1', 'localhost', '::1', '[::1]') -and -not $uri.UserInfo -and
      -not $uri.Query -and -not $uri.Fragment -and
      $uri.AbsolutePath -cmatch '^/devtools/(?:page|browser)/[A-Za-z0-9._-]{1,200}$')
  } catch {
    return $false
  }
}

function Test-DreamSkinCdpPageTarget {
  param([AllowNull()][object]$Target, [int]$Port)
  if ($null -eq $Target -or "$($Target.type)" -cne 'page' -or
    "$($Target.url)" -notlike 'app://*') {
    return $false
  }
  if ($Target.id -isnot [string]) { return $false }
  $targetId = "$($Target.id)"
  $webSocketUrl = "$($Target.webSocketDebuggerUrl)"
  if (-not (Test-DreamSkinBrowserId -Value $targetId) -or
    -not (Test-DreamSkinWebSocketUrl -Value $webSocketUrl -Port $Port)) {
    return $false
  }
  try {
    return ([Uri]$webSocketUrl).AbsolutePath -ceq "/devtools/page/$targetId"
  } catch {
    return $false
  }
}

function Get-DreamSkinCdpTargets {
  param([int]$Port)
  try {
    $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2 `
      -MaximumRedirection 0 -ErrorAction Stop
    return @($targets | Where-Object { Test-DreamSkinCdpPageTarget -Target $_ -Port $Port })
  } catch {
    return @()
  }
}

function Test-DreamSkinBrowserId {
  param([string]$Value)
  return [bool]($Value -and $Value.Length -le 200 -and $Value -cmatch '^[A-Za-z0-9._-]+$')
}

function Get-DreamSkinCdpBrowserIdentity {
  param([int]$Port)
  try {
    $version = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 `
      -MaximumRedirection 0 -ErrorAction Stop
    $webSocketUrl = "$($version.webSocketDebuggerUrl)"
    if (-not (Test-DreamSkinWebSocketUrl -Value $webSocketUrl -Port $Port)) { return $null }
    $uri = [Uri]$webSocketUrl
    $match = [regex]::Match($uri.AbsolutePath, '^/devtools/browser/(?<id>[A-Za-z0-9._-]{1,200})$')
    if (-not $match.Success -or $uri.Query -or $uri.Fragment) { return $null }
    $browserId = $match.Groups['id'].Value
    if (-not (Test-DreamSkinBrowserId -Value $browserId)) { return $null }
    return [pscustomobject]@{
      BrowserId = $browserId
      WebSocketDebuggerUrl = $webSocketUrl
      Browser = "$($version.Browser)"
    }
  } catch {
    return $null
  }
}

$script:DreamSkinListenerLookupUnavailable = $false

# Get-NetTCPConnection and Win32_Process walk every connection or process
# through CIM: with about a thousand TCP connections one listener query takes
# ~3 seconds and one process query ~1 second, and every endpoint identity check
# needs two of each. The owner-PID listener tables and a limited process query
# answer in milliseconds; the CIM queries remain the fallback and the final word
# whenever the fast answer is not a positive match.
function Initialize-DreamSkinListenerLookup {
  if ($script:DreamSkinListenerLookupUnavailable) { return $false }
  if ('CodexDreamSkin.LoopbackListenerTable' -as [type]) { return $true }
  try {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexDreamSkin {
  public sealed class TcpListenerEntry {
    public string LocalAddress { get; private set; }
    public int LocalPort { get; private set; }
    public int OwningProcess { get; private set; }

    internal TcpListenerEntry(string localAddress, int localPort, int owningProcess) {
      LocalAddress = localAddress;
      LocalPort = localPort;
      OwningProcess = owningProcess;
    }
  }

  public static class LoopbackListenerTable {
    private const int AfInet = 2;
    private const int AfInet6 = 23;
    private const int TcpTableOwnerPidListener = 3;
    private const uint ErrorNotSupported = 50;
    private const uint ErrorInsufficientBuffer = 122;
    private const int ProcessQueryLimitedInformation = 0x1000;
    private const uint StillActive = 259;

    [DllImport("iphlpapi.dll")]
    private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order,
      int family, int tableClass, uint reserved);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(int access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(IntPtr process, int flags,
      StringBuilder name, ref int size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    // Every listening row for a port, as Get-NetTCPConnection -State Listen
    // reports them, except that a dual-stack socket also appears in the IPv4
    // table as 0.0.0.0 next to its "::" row. Both rows are rejected as
    // non-loopback, so no availability or ownership decision changes.
    public static TcpListenerEntry[] Find(int port) {
      List<TcpListenerEntry> result = new List<TcpListenerEntry>();
      Collect(AfInet, 24, port, result);
      Collect(AfInet6, 56, port, result);
      return result.ToArray();
    }

    private static void Collect(int family, int rowSize, int port, List<TcpListenerEntry> result) {
      int size = 0;
      IntPtr buffer = IntPtr.Zero;
      try {
        uint status = ErrorInsufficientBuffer;
        // The table can grow between the size query and the read.
        for (int attempt = 0; attempt < 8 && status == ErrorInsufficientBuffer; attempt++) {
          if (buffer != IntPtr.Zero) { Marshal.FreeHGlobal(buffer); buffer = IntPtr.Zero; }
          if (size > 0) buffer = Marshal.AllocHGlobal(size);
          status = GetExtendedTcpTable(buffer, ref size, false, family, TcpTableOwnerPidListener, 0);
        }
        if (status == ErrorNotSupported && family == AfInet6) return;
        if (status != 0) throw new Win32Exception((int)status);
        if (buffer == IntPtr.Zero) return;
        int count = Marshal.ReadInt32(buffer);
        if (count < 0 || 4L + (long)count * rowSize > size) {
          throw new InvalidOperationException("The TCP listener table is malformed.");
        }
        int portOffset = family == AfInet ? 8 : 20;
        int processOffset = family == AfInet ? 20 : 52;
        for (int index = 0; index < count; index++) {
          IntPtr row = IntPtr.Add(buffer, 4 + index * rowSize);
          // The port is stored in network byte order.
          int localPort = (Marshal.ReadByte(row, portOffset) << 8) | Marshal.ReadByte(row, portOffset + 1);
          if (localPort != port) continue;
          string address;
          if (family == AfInet) {
            address = new IPAddress((long)(uint)Marshal.ReadInt32(row, 4)).ToString();
          } else {
            // The scope id is left out: it never makes a loopback row less local.
            byte[] bytes = new byte[16];
            Marshal.Copy(row, bytes, 0, 16);
            address = new IPAddress(bytes).ToString();
          }
          result.Add(new TcpListenerEntry(address, localPort, Marshal.ReadInt32(row, processOffset)));
        }
      } finally {
        if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
      }
    }

    // The final image path (junctions and file system redirection resolved).
    // Null when the process has exited, even if a handle keeps its object
    // alive, or when the limited query right is denied.
    public static string ProcessImagePath(int processId) {
      if (processId <= 0) return null;
      IntPtr handle = OpenProcess(ProcessQueryLimitedInformation, false, processId);
      if (handle == IntPtr.Zero) return null;
      try {
        uint exitCode;
        if (!GetExitCodeProcess(handle, out exitCode) || exitCode != StillActive) return null;
        StringBuilder name = new StringBuilder(32768);
        int size = name.Capacity;
        return QueryFullProcessImageName(handle, 0, name, ref size) ? name.ToString(0, size) : null;
      } finally {
        CloseHandle(handle);
      }
    }
  }
}
'@
    return $true
  } catch {
    # Compilation can be unavailable (for example under a language-mode
    # policy); the CIM queries below stay correct, only slower.
    $script:DreamSkinListenerLookupUnavailable = $true
    return $false
  }
}

function Get-DreamSkinPortListeners {
  param([int]$Port)
  if (Initialize-DreamSkinListenerLookup) {
    try {
      return @([CodexDreamSkin.LoopbackListenerTable]::Find($Port))
    } catch {}
  }
  if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    throw 'Get-NetTCPConnection is required to verify CDP listener ownership.'
  }
  return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Test-DreamSkinListenerProcess {
  param([int]$ProcessId, [string]$Executable)
  if (Initialize-DreamSkinListenerLookup) {
    try {
      $finalPath = [CodexDreamSkin.LoopbackListenerTable]::ProcessImagePath($ProcessId)
      if ($finalPath -and (Test-DreamSkinPathEqual -Left $finalPath -Right $Executable)) { return $true }
    } catch {}
  }
  # Only a match is conclusive above. The final path differs from the launch
  # path when the install sits behind a junction, and WMI can read paths the
  # limited query right cannot, so anything else is decided by Win32_Process
  # exactly as before.
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
  $processPath = if ($process) { Get-DreamSkinProcessExecutablePath -ProcessInfo $process } else { $null }
  return [bool]($processPath -and (Test-DreamSkinPathEqual -Left $processPath -Right $Executable))
}

function Test-DreamSkinPortAvailable {
  param([int]$Port)
  return @(Get-DreamSkinPortListeners -Port $Port).Count -eq 0
}

function Test-DreamSkinCodexPortOwner {
  param([int]$Port, [Parameter(Mandatory = $true)][object]$Codex)
  $listeners = @(Get-DreamSkinPortListeners -Port $Port)
  if ($listeners.Count -eq 0) { return $false }
  foreach ($listener in $listeners) {
    if ($listener.LocalAddress -notin @('127.0.0.1', '::1')) { return $false }
    if (-not (Test-DreamSkinListenerProcess -ProcessId ([int]$listener.OwningProcess) -Executable "$($Codex.Executable)")) {
      return $false
    }
  }
  return $true
}

function Get-DreamSkinVerifiedCdpIdentity {
  param([int]$Port, [Parameter(Mandatory = $true)][object]$Codex)
  if (-not (Test-DreamSkinCodexPortOwner -Port $Port -Codex $Codex)) { return $null }
  $browser = Get-DreamSkinCdpBrowserIdentity -Port $Port
  if ($null -eq $browser) { return $null }
  $targets = Get-DreamSkinCdpTargets -Port $Port
  if ($targets.Count -eq 0) { return $null }
  if (-not (Test-DreamSkinCodexPortOwner -Port $Port -Codex $Codex)) { return $null }
  return [pscustomobject]@{
    BrowserId = $browser.BrowserId
    BrowserWebSocketDebuggerUrl = $browser.WebSocketDebuggerUrl
    Browser = $browser.Browser
    TargetCount = $targets.Count
  }
}

function Test-DreamSkinCodexCdpEndpoint {
  param([int]$Port, [Parameter(Mandatory = $true)][object]$Codex)
  return $null -ne (Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $Codex)
}

function Get-DreamSkinVerifiedCdpIdentityForAnyRegistered {
  # A Store auto-update replaces the "current" package directory while the
  # older version keeps running and owning the verified endpoint.  Accepting
  # any registered OpenAI Codex/ChatGPT install keeps the strict owner validation
  # (every candidate passed the same package identity checks) without
  # restarting a healthy skinned Codex just because the Store updated.
  param([int]$Port)
  foreach ($install in @(Get-DreamSkinRegisteredCodexInstalls)) {
    $identity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $install
    if ($null -ne $identity) {
      return [pscustomobject]@{
        Identity = $identity
        Codex = $install
      }
    }
  }
  return $null
}

function Select-DreamSkinPort {
  param([int]$PreferredPort)
  for ($candidate = $PreferredPort; $candidate -le [Math]::Min(65535, $PreferredPort + 100); $candidate++) {
    if (Test-DreamSkinPortAvailable -Port $candidate) { return $candidate }
  }
  throw "No free loopback port was found between $PreferredPort and $([Math]::Min(65535, $PreferredPort + 100))."
}

function Wait-DreamSkinPortAvailable {
  param([int]$Port, [int]$TimeoutSeconds = 5)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    if (Test-DreamSkinPortAvailable -Port $Port) { return $true }
    Start-Sleep -Milliseconds 200
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Read-DreamSkinState {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $state = (Read-DreamSkinUtf8File -Path $Path) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $state -or $state -is [string] -or $state -is [array]) { throw 'State root must be an object.' }
    $properties = @($state.PSObject.Properties.Name)
    if ($properties -contains 'platform' -and "$($state.platform)" -ine 'windows') {
      throw 'State platform is not Windows.'
    }
    $schemaVersion = 1
    if ($properties -contains 'schemaVersion') {
      $schemaVersion = 0
      if (-not [int]::TryParse("$($state.schemaVersion)", [ref]$schemaVersion) -or
        $schemaVersion -lt 1 -or $schemaVersion -gt 3) {
        throw 'State schema is not supported.'
      }
    }
    if ($schemaVersion -ge 3) {
      $requiredFields = @(
        'platform', 'port',
        'codexExe', 'codexPackageRoot', 'codexPackageFullName', 'codexPackageFamilyName', 'browserId'
      )
      if ($state.connectionOnly -isnot [bool] -or -not $state.connectionOnly) {
        $requiredFields += @('injectorPid', 'injectorStartedAt', 'injectorPath', 'nodePath')
      } elseif ($properties -contains 'injectorPid') {
        throw 'A connection-only state cannot claim an injector process.'
      }
      foreach ($required in $requiredFields) {
        if ($properties -notcontains $required -or -not $state.$required) {
          throw "State schema 3 is missing required field: $required"
        }
      }
    }
    if ($properties -contains 'port') {
      $statePort = 0
      if (-not [int]::TryParse("$($state.port)", [ref]$statePort)) { throw 'State port is invalid.' }
      Assert-DreamSkinPort -Port $statePort
    }
    if ($properties -contains 'injectorPid' -and $null -ne $state.injectorPid) {
      $statePid = 0
      if (-not [int]::TryParse("$($state.injectorPid)", [ref]$statePid) -or $statePid -le 0) {
        throw 'State injector PID is invalid.'
      }
    }
    if ($properties -contains 'browserId' -and $state.browserId -and
      -not (Test-DreamSkinBrowserId -Value "$($state.browserId)")) {
      throw 'State browser ID is invalid.'
    }
    return $state
  } catch {
    throw "Dream Skin state is unreadable; it was preserved for inspection: $Path"
  }
}

function Write-DreamSkinState {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$State)
  $json = $State | ConvertTo-Json -Depth 6
  Write-DreamSkinUtf8FileAtomically -Path $Path -Content ($json + "`r`n")
}

function Archive-DreamSkinStateFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  $directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
  $archivePath = Join-Path $directory "state.stale-$stamp-$([guid]::NewGuid().ToString('N')).json"
  Move-Item -LiteralPath $Path -Destination $archivePath -ErrorAction Stop
  return $archivePath
}

function Get-DreamSkinProcessStartedAt {
  param([int]$ProcessId)
  try {
    return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
  } catch {
    return $null
  }
}

function Test-DreamSkinTimestampEqual {
  param(
    [AllowNull()][object]$Left,
    [AllowNull()][object]$Right
  )

  if ($null -eq $Left -or $null -eq $Right) { return $false }
  try {
    # Windows PowerShell 5.1's ConvertFrom-Json eagerly turns ISO timestamps
    # into DateTime values. Compare UTC instants instead of interpolating one
    # side back to a locale-dependent display string.
    $leftUtc = if ($Left -is [System.DateTimeOffset]) {
      $Left.ToUniversalTime().UtcDateTime
    } elseif ($Left -is [System.DateTime]) {
      $Left.ToUniversalTime()
    } else {
      $parsedLeft = [System.DateTimeOffset]::MinValue
      if (-not [System.DateTimeOffset]::TryParse(
          [string]$Left,
          [System.Globalization.CultureInfo]::InvariantCulture,
          [System.Globalization.DateTimeStyles]::RoundtripKind,
          [ref]$parsedLeft)) { return $false }
      $parsedLeft.UtcDateTime
    }
    $rightUtc = if ($Right -is [System.DateTimeOffset]) {
      $Right.ToUniversalTime().UtcDateTime
    } elseif ($Right -is [System.DateTime]) {
      $Right.ToUniversalTime()
    } else {
      $parsedRight = [System.DateTimeOffset]::MinValue
      if (-not [System.DateTimeOffset]::TryParse(
          [string]$Right,
          [System.Globalization.CultureInfo]::InvariantCulture,
          [System.Globalization.DateTimeStyles]::RoundtripKind,
          [ref]$parsedRight)) { return $false }
      $parsedRight.UtcDateTime
    }
    return $leftUtc.Ticks -eq $rightUtc.Ticks
  } catch {
    return $false
  }
}

function Stop-DreamSkinRecordedInjector {
  param([AllowNull()][object]$State)
  if ($null -eq $State -or -not $State.injectorPid) { return $true }
  $processId = [int]$State.injectorPid
  $processHandle = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if (-not $processHandle) { return $true }
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
  if (-not $process) {
    if ($processHandle.HasExited) { return $true }
    throw "The recorded injector PID $processId is running, but its identity cannot be inspected. State was preserved."
  }

  $expectedInjector = if ($State.injectorPath) {
    "$($State.injectorPath)"
  } elseif ($State.skillRoot) {
    Join-Path "$($State.skillRoot)" 'scripts\injector.mjs'
  } else {
    $null
  }
  $processPath = Get-DreamSkinProcessExecutablePath -ProcessInfo $process
  $commandLine = "$($process.CommandLine)"
  if (-not $processPath -or -not $commandLine) {
    throw "The recorded injector PID $processId is running, but its identity cannot be inspected. State was preserved."
  }
  $isNodeExecutable = [System.IO.Path]::GetFileName("$processPath") -ieq 'node.exe'
  $nodeMatches = -not $State.nodePath -or
    (Test-DreamSkinPathEqual -Left $processPath -Right "$($State.nodePath)")
  $injectorMatches = [bool]($expectedInjector -and
    (Test-DreamSkinCommandLineToken -CommandLine $commandLine -Token $expectedInjector) -and
    (Test-DreamSkinCommandLineToken -CommandLine $commandLine -Token '--watch'))
  if ($State.port) {
    $portPattern = '(?i)(?:^|\s)--port(?:=|\s+)' + [regex]::Escape("$($State.port)") + '(?=$|\s)'
    $injectorMatches = $injectorMatches -and [regex]::IsMatch($commandLine, $portPattern)
  } else {
    $injectorMatches = $false
  }
  if ($State.browserId) {
    $browserPattern = '(?:^|\s)(?i:--browser-id)(?:=|\s+)' + [regex]::Escape("$($State.browserId)") + '(?=$|\s)'
    $injectorMatches = $injectorMatches -and [regex]::IsMatch($commandLine, $browserPattern)
  }
  try {
    $startedAt = $processHandle.StartTime.ToUniversalTime().ToString('o')
  } catch {
    if ($processHandle.HasExited) { return $true }
    throw "The recorded injector PID $processId is running, but its start time cannot be inspected. State was preserved."
  }
  $startMatches = -not $State.injectorStartedAt -or
    (Test-DreamSkinTimestampEqual -Left $startedAt -Right $State.injectorStartedAt)
  $identityMatches = [bool]($isNodeExecutable -and $nodeMatches -and $injectorMatches -and $startMatches)

  if (-not $identityMatches) {
    throw "The recorded injector PID $processId is running, but its visible identity does not match the saved Dream Skin process. State was preserved."
  }

  Stop-Process -InputObject $processHandle -Force -ErrorAction Stop
  [void]$processHandle.WaitForExit(15000)
  if (-not $processHandle.HasExited) {
    throw "The recorded Dream Skin injector did not stop: PID $processId"
  }
  return $true
}

function Get-DreamSkinCodexProcesses {
  param([Parameter(Mandatory = $true)][object]$Codex)
  return @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $processPath = Get-DreamSkinProcessExecutablePath -ProcessInfo $_
      Test-DreamSkinPathEqual -Left $processPath -Right $Codex.Executable
    })
}

function Get-DreamSkinCodexProcessesExcept {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds = @()
  )
  $preserved = @{}
  foreach ($processId in $PreserveProcessIds) {
    if ($processId -gt 0) { $preserved[$processId] = $true }
  }
  return @(
    Get-DreamSkinCodexProcesses -Codex $Codex | Where-Object {
      -not $preserved.ContainsKey([int]$_.ProcessId)
    }
  )
}

function Stop-DreamSkinCodex {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowEmptyCollection()][int[]]$PreserveProcessIds = @(),
    [switch]$AllowForce
  )
  $processes = Get-DreamSkinCodexProcessesExcept -Codex $Codex -PreserveProcessIds $PreserveProcessIds
  if ($processes.Count -eq 0) { return }
  $closeRequested = $false
  foreach ($item in $processes) {
    try {
      if ((Get-Process -Id $item.ProcessId -ErrorAction Stop).CloseMainWindow()) { $closeRequested = $true }
    } catch {}
  }

  # Without force authorization a manual close keeps its full 15 seconds. With
  # restart consent, Codex keeps windowless processes (background instances,
  # helpers) alive after its window closes, which used to cost the whole wait
  # on every restart: give a visible window a short grace and force the rest.
  $graceSeconds = if (-not $AllowForce) { 15 } elseif ($closeRequested) { 3 } else { 0 }
  $deadline = (Get-Date).AddSeconds($graceSeconds)
  while ((Get-DreamSkinCodexProcessesExcept -Codex $Codex `
      -PreserveProcessIds $PreserveProcessIds).Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
  }
  $remaining = Get-DreamSkinCodexProcessesExcept -Codex $Codex -PreserveProcessIds $PreserveProcessIds
  if ($remaining.Count -eq 0) { return }
  if (-not $AllowForce) {
    throw "Codex did not close within $graceSeconds seconds. Close it manually or explicitly authorize a forced restart."
  }
  foreach ($item in $remaining) {
    $current = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$item.ProcessId)" -ErrorAction SilentlyContinue
    $currentPath = if ($current) { Get-DreamSkinProcessExecutablePath -ProcessInfo $current } else { $null }
    if ($currentPath -and (Test-DreamSkinPathEqual -Left $currentPath -Right $Codex.Executable)) {
      Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
  Start-Sleep -Milliseconds 500
  if ((Get-DreamSkinCodexProcessesExcept -Codex $Codex `
      -PreserveProcessIds $PreserveProcessIds).Count -gt 0) {
    throw 'Codex could not be stopped safely.'
  }
}

function Confirm-DreamSkinRestart {
  param([string]$Message)
  $shell = New-Object -ComObject WScript.Shell
  return $shell.Popup($Message, 0, 'Codex Dream Skin', 52) -eq 6
}

function Invoke-DreamSkinCodexWindowActivation {
  param([Parameter(Mandatory = $true)][object]$Codex)
  $processes = @(Get-DreamSkinCodexProcesses -Codex $Codex)
  if ($processes.Count -eq 0) { return $false }
  $shell = New-Object -ComObject WScript.Shell
  foreach ($process in $processes) {
    try {
      if ($shell.AppActivate([int]$process.ProcessId)) { return $true }
    } catch {}
  }
  return $false
}
