[CmdletBinding()]
param(
  # Snapshot：一次性快照；Processes：监视 ChatGPT.exe 进程启动/退出；
  # Renderer：采样页面内皮肤刷新频率与长任务；Manager：计时管理器的只读操作。
  [ValidateSet('Snapshot', 'Processes', 'Renderer', 'Manager')][string]$Mode = 'Snapshot',
  [ValidateRange(0, 300)][int]$Seconds = 0,
  [ValidateRange(1, 10)][int]$Iterations = 3,
  # 写进报告的备注，例如 idle / streaming。
  [string]$Label = '',
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'),
  [string]$SkillRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'windows'),
  [string]$NodePath = '',
  [string]$OutFile = ''
)

# Codex Dream Skin 取证脚本（只读）。
# 不修改 Codex、主题、state.json 或任何配置；Manager 模式只调用 Status/ListThemes 两个只读动作。
# 详见 docs/optimization-plan.md 第 0 阶段。

$ErrorActionPreference = 'Stop'

$skinProfilePath = [System.IO.Path]::GetFullPath((Join-Path $StateRoot 'cdp-profile'))
$statePath = Join-Path $StateRoot 'state.json'
$rendererScript = Join-Path $PSScriptRoot 'diag-renderer.mjs'
$report = [ordered]@{
  tool = 'diag-runtime'
  mode = $Mode
  label = $Label
  capturedAt = (Get-Date).ToString('o')
  stateRoot = $StateRoot
  skinProfile = $skinProfilePath
}

function Write-DiagSection {
  param([Parameter(Mandatory = $true)][string]$Title)
  Write-Host ''
  Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Test-DiagPathEqual {
  param([string]$Left, [string]$Right)
  if (-not $Left -or -not $Right) { return $false }
  try {
    $leftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd('\')
    $rightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd('\')
    return [string]::Equals($leftFull, $rightFull, [System.StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Get-DiagSwitchValue {
  param([string]$CommandLine, [Parameter(Mandatory = $true)][string]$Name)
  if (-not $CommandLine) { return '' }
  $quoted = [regex]::Match($CommandLine, '"--' + [regex]::Escape($Name) + '=([^"]*)"')
  if ($quoted.Success) { return $quoted.Groups[1].Value }
  $plain = [regex]::Match($CommandLine, '(?:^|\s)--' + [regex]::Escape($Name) + '=("[^"]*"|\S+)')
  if ($plain.Success) { return $plain.Groups[1].Value.Trim('"') }
  return ''
}

function Get-DiagProcessName {
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return '' }
  try {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
    if ($null -ne $process) { return "$($process.Name)" }
  } catch {}
  return ''
}

function ConvertTo-DiagProcessRecord {
  param([Parameter(Mandatory = $true)][object]$Process)
  $commandLine = "$($Process.CommandLine)"
  $type = Get-DiagSwitchValue -CommandLine $commandLine -Name 'type'
  $userDataDir = Get-DiagSwitchValue -CommandLine $commandLine -Name 'user-data-dir'
  $debugPort = Get-DiagSwitchValue -CommandLine $commandLine -Name 'remote-debugging-port'
  $profileKind = if (-not $commandLine) {
    'uninspectable'
  } elseif (-not $userDataDir) {
    'default'
  } elseif (Test-DiagPathEqual -Left $userDataDir -Right $skinProfilePath) {
    'dream-skin'
  } else {
    'other'
  }
  $record = [ordered]@{
    pid = [int]$Process.ProcessId
    parentPid = [int]$Process.ParentProcessId
    parentName = ''
    created = if ($Process.CreationDate) { ([datetime]$Process.CreationDate).ToString('o') } else { '' }
    role = if ($type) { $type } else { 'browser' }
    profile = $profileKind
    userDataDir = $userDataDir
    debugPort = $debugPort
    executable = "$($Process.ExecutablePath)"
    commandLine = $commandLine
  }
  # 只有主进程（browser）需要追查是谁拉起的：通知激活、资源管理器、包激活服务等。
  if ($record.role -eq 'browser') { $record.parentName = Get-DiagProcessName -ProcessId $record.parentPid }
  return $record
}

function Get-DiagCodexProcesses {
  return @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction SilentlyContinue)
}

function Get-DiagCodexProcessRecords {
  return @(Get-DiagCodexProcesses | ForEach-Object { ConvertTo-DiagProcessRecord -Process $_ })
}

function Write-DiagBrowserProcess {
  param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Record, [string]$Prefix = '')
  $color = if ($Record.profile -eq 'dream-skin') { 'Green' } else { 'Yellow' }
  Write-Host ("{0}PID {1}  profile={2}  debugPort={3}  parent={4}({5})  created={6}" -f $Prefix,
    $Record.pid, $Record.profile, $(if ($Record.debugPort) { $Record.debugPort } else { '-' }),
    $Record.parentName, $Record.parentPid, $Record.created) -ForegroundColor $color
  Write-Host ("{0}  cmd: {1}" -f $Prefix, $Record.commandLine)
}

function Read-DiagState {
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    Write-Warning "state.json 无法解析：$($_.Exception.Message)"
    return $null
  }
}

function Get-DiagStateProperty {
  param([AllowNull()][object]$State, [Parameter(Mandatory = $true)][string]$Name)
  if ($null -eq $State) { return $null }
  if (@($State.PSObject.Properties.Name) -notcontains $Name) { return $null }
  return $State.$Name
}

function Get-DiagStateSummary {
  param([AllowNull()][object]$State)
  if ($null -eq $State) { return [ordered]@{ present = $false } }
  $injectorPid = 0
  [void][int]::TryParse("$(Get-DiagStateProperty -State $State -Name 'injectorPid')", [ref]$injectorPid)
  $injectorAlive = $false
  $injectorStartedAt = ''
  if ($injectorPid -gt 0) {
    $injector = Get-Process -Id $injectorPid -ErrorAction SilentlyContinue
    if ($null -ne $injector) {
      $injectorAlive = $true
      try { $injectorStartedAt = $injector.StartTime.ToUniversalTime().ToString('o') } catch {}
    }
  }
  $codexExe = "$(Get-DiagStateProperty -State $State -Name 'codexExe')"
  $codexVersion = ''
  if ($codexExe -and (Test-Path -LiteralPath $codexExe -PathType Leaf)) {
    try { $codexVersion = (Get-Item -LiteralPath $codexExe).VersionInfo.ProductVersion } catch {}
  }
  return [ordered]@{
    present = $true
    schemaVersion = Get-DiagStateProperty -State $State -Name 'schemaVersion'
    port = Get-DiagStateProperty -State $State -Name 'port'
    browserId = Get-DiagStateProperty -State $State -Name 'browserId'
    connectionOnly = Get-DiagStateProperty -State $State -Name 'connectionOnly'
    injectorPid = $injectorPid
    injectorAlive = $injectorAlive
    injectorRecordedStartedAt = Get-DiagStateProperty -State $State -Name 'injectorStartedAt'
    injectorActualStartedAt = $injectorStartedAt
    codexVersion = $codexVersion
    nodePath = Get-DiagStateProperty -State $State -Name 'nodePath'
  }
}

function Resolve-DiagNode {
  param([AllowNull()][object]$State)
  $candidates = @()
  if ($NodePath) { $candidates += $NodePath }
  $stateNode = "$(Get-DiagStateProperty -State $State -Name 'nodePath')"
  if ($stateNode) { $candidates += $stateNode }
  $candidates += (Join-Path $SkillRoot 'runtime\node\node.exe')
  $command = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($null -ne $command) { $candidates += $command.Source }
  foreach ($candidate in $candidates) {
    if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    try {
      $version = "$(& $candidate -p 'process.versions.node')".Trim()
      $major = 0
      if ($LASTEXITCODE -eq 0 -and [int]::TryParse($version.Split('.')[0], [ref]$major) -and $major -ge 22) {
        return $candidate
      }
    } catch {}
  }
  return $null
}

function Invoke-DiagRenderer {
  param(
    [AllowNull()][object]$State,
    [int]$SampleSeconds = 0,
    [int]$MeasurePasses = 5
  )
  $port = "$(Get-DiagStateProperty -State $State -Name 'port')"
  $browserId = "$(Get-DiagStateProperty -State $State -Name 'browserId')"
  if (-not $port -or -not $browserId) {
    return [ordered]@{ skipped = 'state.json 中没有记录 port/browserId，皮肤会话不存在。' }
  }
  $node = Resolve-DiagNode -State $State
  if (-not $node) {
    return [ordered]@{ skipped = '找不到 Node.js 22+；可用 -NodePath 指定。' }
  }
  $arguments = @($rendererScript, '--port', $port, '--browser-id', $browserId,
    '--sample', "$SampleSeconds", '--measure-passes', "$MeasurePasses")
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $raw = @(& $node @arguments 2>$null)
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  $json = ($raw | Where-Object { "$_".TrimStart().StartsWith('{') } | Select-Object -Last 1)
  if (-not $json) { return [ordered]@{ error = 'diag-renderer.mjs 没有输出结果。'; raw = ($raw -join "`n") } }
  try {
    return ($json | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    return [ordered]@{ error = 'diag-renderer.mjs 输出无法解析。'; raw = "$json" }
  }
}

function Write-DiagRendererSnapshot {
  param([AllowNull()][object]$Result)
  if ($null -eq $Result) { return }
  if ($Result -is [System.Collections.IDictionary]) {
    foreach ($key in $Result.Keys) { Write-Host "  ${key}: $($Result[$key])" -ForegroundColor Yellow }
    return
  }
  if ($Result.fatal) {
    Write-Host "  diag-renderer.mjs 失败：$($Result.fatal)" -ForegroundColor Yellow
    return
  }
  Write-Host "  CDP 身份：$($Result.identity)（期望 $($Result.expectedBrowserId)，实际 $($Result.actualBrowserId)）"
  if ($Result.identity -eq 'unreachable') {
    Write-Host "  记录的调试端口连不上：$($Result.error)。皮肤版 Codex 可能已关闭。" -ForegroundColor Yellow
  } elseif ($Result.identity -eq 'mismatch') {
    Write-Host '  端口上已是另一个浏览器实例（Codex 重启过），注入器不会再连接它。' -ForegroundColor Yellow
  }
  foreach ($target in @($Result.targets)) {
    if ($null -eq $target) { continue }
    Write-Host "  页面 $($target.id)  $($target.page)"
    if (@($target.PSObject.Properties.Name) -contains 'error') {
      Write-Host "    错误：$($target.error)" -ForegroundColor Yellow
      continue
    }
    $value = $target.result
    if ($null -eq $value) { continue }
    $names = @($value.PSObject.Properties.Name)
    if ($names -contains 'perSecond') {
      Write-Host ("    采样 {0}s  DOM {1} -> {2}  页面可见性 {3}/{4}" -f $value.seconds, $value.domBefore,
        $value.domAfter, $value.visibilityBefore, $value.visibilityAfter)
      Write-Host ("    每秒：partPasses={0}  ensureCalls={1}  rootPasses={2}  styleRepairs={3}" -f
        $value.perSecond.partPasses, $value.perSecond.ensureCalls, $value.perSecond.rootPasses,
        $value.perSecond.styleRepairs)
      Write-Host ("    长任务：{0} 次，共 {1}ms，最长 {2}ms" -f $value.longTasks.count, $value.longTasks.totalMs,
        $value.longTasks.maxMs)
      if ($value.replaced) { Write-Host '    采样期间皮肤被重新安装或卸下。' -ForegroundColor Yellow }
      continue
    }
    $installedColor = if ($value.installed -and $value.rootActive) { 'Green' } else { 'Yellow' }
    Write-Host ("    已安装={0}  根节点生效={1}  已禁用={2}  DOM 节点={3}" -f $value.installed, $value.rootActive,
      $value.disabled, $value.domNodes) -ForegroundColor $installedColor
    if (-not $value.installed) { continue }
    Write-Host ("    主题={0}  revision={1}  样式={2}/挂载={3}  媒体={4}  图片就绪={5}  视频就绪={6}" -f
      $value.themeId, $value.revision, $value.styleMode, $value.sheetAttached, $value.mediaType,
      $value.imageReady, $value.videoReady)
    if ($value.imageError -or $value.videoError) {
      Write-Host "    媒体错误：$($value.imageError) $($value.videoError)" -ForegroundColor Yellow
    }
    if ($null -ne $value.scope) {
      Write-Host ("    页面范围={0}  级别={1}  缺失={2}" -f $value.scope.state, $value.scope.level,
        (@($value.scope.missingL1) -join ','))
    }
    Write-Host ("    部件节点={0}  面板节点={1}" -f $value.partNodes, $value.surfaceNodes)
    $metrics = $value.metrics
    Write-Host ("    累计：partPasses={0}  ensureCalls={1}  styleRepairs={2}  safetyPasses={3}  firstEnsureMs={4}" -f
      $metrics.partPasses, $metrics.ensureCalls, $metrics.styleRepairs, $metrics.safetyPasses, $metrics.firstEnsureMs)
    if ($names -contains 'partPassMs') {
      Write-Host ("    单次部件刷新：平均 {0}ms，最长 {1}ms（{2} 次）" -f $value.partPassMs.avg,
        $value.partPassMs.max, $value.partPassMs.runs)
    }
  }
}

function Get-DiagLogSummary {
  $patterns = [ordered]@{
    injected = 'injected target'
    injectFailed = 'inject failed for'
    reinjectFailed = 'reinject failed for'
    liveUpdateFailed = 'live theme update failed'
    earlyUnavailable = 'early (injection|theme refresh) unavailable'
    identityChanged = 'identity changed'
    identityWaiting = 'waiting for the verified CDP identity'
    identityReconnected = 'CDP browser identity reconnected'
    themeRejected = 'theme update rejected'
  }
  $summary = [ordered]@{}
  foreach ($name in @('injector.log', 'injector-error.log')) {
    $path = Join-Path $StateRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      $summary[$name] = [ordered]@{ present = $false }
      continue
    }
    $item = Get-Item -LiteralPath $path
    $lines = @(Get-Content -LiteralPath $path -Tail 5000 -Encoding UTF8 -ErrorAction SilentlyContinue)
    $counts = [ordered]@{}
    foreach ($key in $patterns.Keys) {
      $counts[$key] = @($lines | Where-Object { $_ -match $patterns[$key] }).Count
    }
    $summary[$name] = [ordered]@{
      present = $true
      bytes = $item.Length
      lastWrite = $item.LastWriteTime.ToString('o')
      linesScanned = $lines.Count
      counts = $counts
      tail = @($lines | Select-Object -Last 20)
    }
  }
  return $summary
}

function Write-DiagLogSummary {
  param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Summary)
  foreach ($name in $Summary.Keys) {
    $entry = $Summary[$name]
    if (-not $entry.present) {
      Write-Host "  ${name}：不存在"
      continue
    }
    $nonZero = @($entry.counts.Keys | Where-Object { $entry.counts[$_] -gt 0 } |
      ForEach-Object { "$_=$($entry.counts[$_])" })
    Write-Host ("  {0}：{1} 字节，最后写入 {2}，扫描最近 {3} 行" -f $name, $entry.bytes, $entry.lastWrite, $entry.linesScanned)
    Write-Host ("    关键事件：{0}" -f $(if ($nonZero.Count) { $nonZero -join '  ' } else { '无' }))
    if ($name -eq 'injector-error.log' -and @($entry.tail).Count) {
      Write-Host '    最近错误：'
      foreach ($line in @($entry.tail | Select-Object -Last 10)) { Write-Host "      $line" }
    }
  }
}

function Measure-DiagPowerShell {
  param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Arguments)
  $samples = @()
  for ($index = 0; $index -lt $Iterations; $index++) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = 'powershell.exe'
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = [System.Diagnostics.Process]::Start($info)
    try {
      $outputTask = $process.StandardOutput.ReadToEndAsync()
      $errorTask = $process.StandardError.ReadToEndAsync()
      $finished = $process.WaitForExit(60000)
      if (-not $finished) { try { $process.Kill() } catch {} }
      $stopwatch.Stop()
      $output = if ($finished) { $outputTask.Result } else { '' }
      $statusKind = ''
      try {
        $parsed = $output | ConvertFrom-Json -ErrorAction Stop
        if (@($parsed.PSObject.Properties.Name) -contains 'statusKind') { $statusKind = "$($parsed.statusKind)" }
      } catch {}
      $samples += [ordered]@{
        ms = $stopwatch.ElapsedMilliseconds
        exitCode = if ($finished) { $process.ExitCode } else { 'timeout' }
        outputBytes = $output.Length
        statusKind = $statusKind
        error = if ($finished -and $process.ExitCode -ne 0) { "$($errorTask.Result)".Trim() } else { '' }
      }
    } finally {
      $process.Dispose()
    }
  }
  $values = @($samples | ForEach-Object { [double]$_.ms })
  $sorted = @($values | Sort-Object)
  return [ordered]@{
    name = $Name
    iterations = $Iterations
    minMs = $sorted[0]
    medianMs = $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
    maxMs = $sorted[$sorted.Count - 1]
    samples = $samples
  }
}

function Save-DiagReport {
  $target = $OutFile
  if (-not $target) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $target = Join-Path $env:TEMP "codex-dream-skin-diag-$($Mode.ToLowerInvariant())-$stamp.json"
  }
  $json = $report | ConvertTo-Json -Depth 10
  [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($target), $json + "`r`n",
    (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ''
  Write-Host "报告已保存：$target" -ForegroundColor Cyan
}

$state = Read-DiagState

try {
  switch ($Mode) {
    'Snapshot' {
      Write-DiagSection 'Codex 进程'
      $processes = @(Get-DiagCodexProcessRecords)
      $report.processes = $processes
      $browsers = @($processes | Where-Object { $_.role -eq 'browser' })
      if ($processes.Count -eq 0) { Write-Host '  没有运行中的 ChatGPT.exe。' }
      foreach ($browser in $browsers) { Write-DiagBrowserProcess -Record $browser -Prefix '  ' }
      $childRoles = @($processes | Where-Object { $_.role -ne 'browser' } | Group-Object -Property { $_.role } |
        ForEach-Object { "$($_.Name)x$($_.Count)" })
      if ($childRoles.Count) { Write-Host "  子进程：$($childRoles -join '  ')" }
      if (@($browsers | Where-Object { $_.profile -ne 'dream-skin' }).Count) {
        Write-Host '  发现不是皮肤 profile 的 Codex 主进程，这类窗口不会有皮肤。' -ForegroundColor Yellow
      }

      Write-DiagSection '皮肤会话（state.json）'
      $report.state = Get-DiagStateSummary -State $state
      foreach ($key in $report.state.Keys) { Write-Host "  ${key}: $($report.state[$key])" }

      Write-DiagSection '页面内皮肤状态'
      $report.renderer = Invoke-DiagRenderer -State $state -SampleSeconds 0 -MeasurePasses 5
      Write-DiagRendererSnapshot -Result $report.renderer

      Write-DiagSection '注入器日志'
      $report.logs = Get-DiagLogSummary
      Write-DiagLogSummary -Summary $report.logs
    }

    'Processes' {
      $duration = if ($Seconds -gt 0) { $Seconds } else { 60 }
      Write-DiagSection "监视 ChatGPT.exe 进程 $duration 秒"
      Write-Host '  现在去点击右下角的 Codex 通知；脚本会打印新启动进程的完整命令行。按 Ctrl+C 可提前结束。'
      $known = @{}
      $baseline = @(Get-DiagCodexProcessRecords)
      foreach ($record in $baseline) { $known[$record.pid] = $record }
      $report.baseline = $baseline
      foreach ($browser in @($baseline | Where-Object { $_.role -eq 'browser' })) {
        Write-DiagBrowserProcess -Record $browser -Prefix '  [已有] '
      }
      $events = New-Object System.Collections.ArrayList
      $report.events = $events
      $deadline = (Get-Date).AddSeconds($duration)
      while ((Get-Date) -lt $deadline) {
        $seen = @{}
        # 只为新出现的 PID 做完整解析，保持每轮轮询足够快。
        foreach ($process in @(Get-DiagCodexProcesses)) {
          $processId = [int]$process.ProcessId
          $seen[$processId] = $true
          if ($known.ContainsKey($processId)) { continue }
          $record = ConvertTo-DiagProcessRecord -Process $process
          $known[$processId] = $record
          [void]$events.Add([ordered]@{ at = (Get-Date).ToString('o'); kind = 'started'; process = $record })
          if ($record.role -eq 'browser') {
            Write-DiagBrowserProcess -Record $record -Prefix ("  [{0}] 新主进程 " -f (Get-Date).ToString('HH:mm:ss.fff'))
          } else {
            Write-Host ("  [{0}] 新子进程 PID {1}  role={2}  profile={3}" -f (Get-Date).ToString('HH:mm:ss.fff'),
              $record.pid, $record.role, $record.profile)
          }
        }
        foreach ($processId in @($known.Keys)) {
          if ($seen.ContainsKey($processId)) { continue }
          $gone = $known[$processId]
          $known.Remove($processId)
          [void]$events.Add([ordered]@{ at = (Get-Date).ToString('o'); kind = 'exited'; pid = $processId; role = $gone.role })
          if ($gone.role -eq 'browser') {
            Write-Host ("  [{0}] 主进程退出 PID {1}  profile={2}" -f (Get-Date).ToString('HH:mm:ss.fff'),
              $processId, $gone.profile)
          }
        }
        Start-Sleep -Milliseconds 300
      }
    }

    'Renderer' {
      $duration = if ($Seconds -gt 0) { $Seconds } else { 20 }
      Write-DiagSection "采样页面内皮肤 $duration 秒"
      Write-Host '  保持 Codex 窗口可见（最小化会让页面计时器降频）。'
      Write-Host '  对比方法：先空闲时跑一次（-Label idle），再在 Codex 生成长回答时跑一次（-Label streaming）。'
      $report.renderer = Invoke-DiagRenderer -State $state -SampleSeconds $duration -MeasurePasses 0
      Write-DiagRendererSnapshot -Result $report.renderer
    }

    'Manager' {
      $managerScript = Join-Path $SkillRoot 'scripts\manager-actions.ps1'
      if (-not (Test-Path -LiteralPath $managerScript -PathType Leaf)) {
        throw "找不到 manager-actions.ps1：$managerScript（可用 -SkillRoot 指向管理器安装目录下的 windows 文件夹）"
      }
      $scriptsRoot = Join-Path $SkillRoot 'scripts'
      Write-DiagSection "管理器只读操作计时（每项 $Iterations 次）"
      $common = '-NoProfile -ExecutionPolicy Bypass'
      $pathArguments = "-SkillRoot `"$SkillRoot`" -StateRoot `"$StateRoot`""
      $loadOnly = ". '{0}'; . '{1}'" -f (Join-Path $scriptsRoot 'common-windows.ps1').Replace("'", "''"),
        (Join-Path $scriptsRoot 'theme-windows.ps1').Replace("'", "''")
      $measurements = @(
        (Measure-DiagPowerShell -Name 'PowerShell 空启动' -Arguments "$common -Command exit"),
        (Measure-DiagPowerShell -Name '仅加载公共脚本' -Arguments "$common -Command `"$loadOnly`""),
        (Measure-DiagPowerShell -Name 'Status -Quick -SkipThemes（打开管理器时）' `
          -Arguments "$common -File `"$managerScript`" -Action Status -Quick -SkipThemes $pathArguments"),
        (Measure-DiagPowerShell -Name 'ListThemes（主题列表）' `
          -Arguments "$common -File `"$managerScript`" -Action ListThemes $pathArguments")
      )
      $report.manager = $measurements
      foreach ($measurement in $measurements) {
        Write-Host ("  {0}：中位 {1}ms（最快 {2}ms，最慢 {3}ms）" -f $measurement.name, $measurement.medianMs,
          $measurement.minMs, $measurement.maxMs)
        foreach ($sample in @($measurement.samples | Where-Object { $_.error })) {
          Write-Host "    退出码 $($sample.exitCode)：$($sample.error)" -ForegroundColor Yellow
        }
      }
    }
  }
} finally {
  Save-DiagReport
}
