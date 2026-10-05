[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Root)

$ErrorActionPreference = 'Stop'

function Assert-Equal {
  param($Expected, $Actual, [string]$Message)
  if ("$Expected" -cne "$Actual") { throw "$Message Expected '$Expected', got '$Actual'." }
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dreamskin-validation-cache-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
  # A package-like layout: the bundled runtime path is derived from the
  # location of common-windows.ps1, so load a copy that sits next to a fake one.
  $engine = Join-Path $temporaryRoot 'engine'
  New-Item -ItemType Directory -Path (Join-Path $engine 'scripts'), (Join-Path $engine 'runtime\node') -Force | Out-Null
  foreach ($name in 'common-windows.ps1', 'config-utf8.ps1') {
    Copy-Item -LiteralPath (Join-Path $Root "scripts\$name") -Destination (Join-Path $engine 'scripts')
  }
  $bundledNode = [System.IO.Path]::GetFullPath((Join-Path $engine 'runtime\node\node.exe'))
  [System.IO.File]::WriteAllText($bundledNode, 'bundled node v1')
  . (Join-Path $engine 'scripts\common-windows.ps1')
  . (Join-Path $Root 'scripts\theme-windows.ps1')
  $script:DreamSkinNodeRuntimeRecordPath = Join-Path $temporaryRoot 'node-runtime-v1.json'

  $script:nodeValidations = 0
  function Get-DreamSkinValidatedNodeRuntime {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$MinimumMajor = 22)
    $script:nodeValidations += 1
    [pscustomobject]@{ Path = [System.IO.Path]::GetFullPath($Path); Version = '22.22.2'; Major = 22 }
  }
  function Resolve-AsNewProcess {
    $script:DreamSkinNodeRuntimeCache = $null
    return Get-DreamSkinNodeRuntime
  }

  $first = Resolve-AsNewProcess
  Assert-Equal $bundledNode $first.Path 'The bundled runtime must be selected.'
  Assert-Equal 1 $script:nodeValidations 'The first process must validate the bundled runtime.'
  if (-not (Test-Path -LiteralPath $script:DreamSkinNodeRuntimeRecordPath -PathType Leaf)) {
    throw 'A full validation of the bundled runtime must be remembered.'
  }
  $remembered = Resolve-AsNewProcess
  Assert-Equal 1 $script:nodeValidations 'A later process must reuse the remembered validation of identical bytes.'
  Assert-Equal $bundledNode $remembered.Path 'A remembered runtime must keep its validated path.'
  Assert-Equal 22 $remembered.Major 'A remembered runtime must keep its validated version.'

  [System.IO.File]::WriteAllText($bundledNode, 'bundled node v2')
  $null = Resolve-AsNewProcess
  Assert-Equal 2 $script:nodeValidations 'Changed runtime bytes must be validated again.'

  $records = Get-Content -LiteralPath $script:DreamSkinNodeRuntimeRecordPath -Raw | ConvertFrom-Json
  $records.entries[0].validatedAt = [DateTime]::UtcNow.AddHours(-25).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
  [System.IO.File]::WriteAllText($script:DreamSkinNodeRuntimeRecordPath, ($records | ConvertTo-Json -Depth 4))
  $null = Resolve-AsNewProcess
  Assert-Equal 3 $script:nodeValidations 'A remembered validation older than a day must be repeated.'

  [System.IO.File]::WriteAllText($script:DreamSkinNodeRuntimeRecordPath, '{ not json')
  $null = Resolve-AsNewProcess
  Assert-Equal 4 $script:nodeValidations 'An unreadable record must fall back to a full validation.'
  $null = Resolve-AsNewProcess
  Assert-Equal 4 $script:nodeValidations 'The record must be rewritten after an unreadable one.'

  # PATH can be redirected without touching the engine folder: never remember it.
  Remove-Item -LiteralPath $bundledNode -Force
  $before = $script:nodeValidations
  $null = Resolve-AsNewProcess
  $null = Resolve-AsNewProcess
  Assert-Equal ($before + 2) $script:nodeValidations 'The PATH runtime must be fully validated in every process.'
  $pathRecords = @((Get-Content -LiteralPath $script:DreamSkinNodeRuntimeRecordPath -Raw | ConvertFrom-Json).entries)
  if (@($pathRecords | Where-Object { -not (Test-DreamSkinPathEqual -Left "$($_.path)" -Right $bundledNode) }).Count) {
    throw 'Only the bundled runtime may be remembered.'
  }
  Write-Host 'PASS: bundled node validation is remembered by content for a day; PATH node is always validated'

  # Validated media: identical bytes skip the repeated node parse.
  $stateRoot = Join-Path $temporaryRoot 'state'
  New-Item -ItemType Directory -Path $stateRoot | Out-Null
  $statePath = Join-Path $stateRoot 'state.json'
  [System.IO.File]::WriteAllText($statePath, '{"port":9335,"browserId":"browser-a"}')
  $script:metadataChecks = 0
  $script:decodeChecks = 0
  $script:failMetadata = $false
  function Get-DreamSkinValidatedImageMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($script:failMetadata) { throw "Image metadata is invalid: $Path" }
    $script:metadataChecks += 1
  }
  function Assert-DreamSkinVideoDecodable {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$StateRoot, [switch]$SkipImageMetadata)
    if ([System.IO.Path]::GetExtension($Path) -ine '.mp4') { return }
    if (-not $SkipImageMetadata) { $script:metadataChecks += 1 }
    $script:decodeChecks += 1
  }
  $image = Join-Path $temporaryRoot 'art.png'
  $video = Join-Path $temporaryRoot 'motion.mp4'
  [System.IO.File]::WriteAllBytes($image, [byte[]](1..64))
  [System.IO.File]::WriteAllBytes($video, [byte[]](65..160))

  $null = Set-DreamSkinActiveTheme -ImagePath $image -StateRoot $stateRoot
  Assert-Equal 1 $script:metadataChecks 'A new image is parsed once; its archive copy is not parsed again.'
  $null = Set-DreamSkinActiveTheme -ImagePath $image -StateRoot $stateRoot
  Assert-Equal 1 $script:metadataChecks 'The same image bytes must not be parsed again.'

  $null = Set-DreamSkinActiveTheme -ImagePath $video -StateRoot $stateRoot
  Assert-Equal 2 $script:metadataChecks 'A new video is parsed once before its decode check.'
  Assert-Equal 1 $script:decodeChecks 'A new video must pass the decode check.'
  $null = Set-DreamSkinActiveTheme -ImagePath $video -StateRoot $stateRoot
  Assert-Equal 2 $script:metadataChecks 'The same video bytes must not be parsed again.'
  Assert-Equal 1 $script:decodeChecks 'The same video in the same Codex browser must not be decoded again.'

  [System.IO.File]::WriteAllText($statePath, '{"port":9335,"browserId":"browser-b"}')
  $null = Set-DreamSkinActiveTheme -ImagePath $video -StateRoot $stateRoot
  Assert-Equal 2 $script:metadataChecks 'A new Codex browser does not change the parsed metadata.'
  Assert-Equal 2 $script:decodeChecks 'A new Codex browser must check decoding again.'

  function Get-DreamSkinMediaValidatorFingerprint { return ('f' * 64) }
  $null = Set-DreamSkinActiveTheme -ImagePath $image -StateRoot $stateRoot
  Assert-Equal 3 $script:metadataChecks 'Updated validators must parse previously validated media again.'

  $rejected = Join-Path $temporaryRoot 'rejected.png'
  [System.IO.File]::WriteAllBytes($rejected, [byte[]](200..255))
  $script:failMetadata = $true
  $failed = $false
  try { $null = Set-DreamSkinActiveTheme -ImagePath $rejected -StateRoot $stateRoot } catch { $failed = $true }
  if (-not $failed) { throw 'Invalid media must still be rejected.' }
  $script:failMetadata = $false
  $null = Set-DreamSkinActiveTheme -ImagePath $rejected -StateRoot $stateRoot
  Assert-Equal 4 $script:metadataChecks 'A rejected file must never be remembered as validated.'
  Write-Host 'PASS: validated media skips repeated metadata and decode checks only for identical bytes and validators'
} finally {
  Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
