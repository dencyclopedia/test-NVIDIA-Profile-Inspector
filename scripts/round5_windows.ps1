# Round 5 (Windows runner): where NPI keeps its settings (portable vs %LOCALAPPDATA%, working-directory rule), favourites,
# DisableUpdateCheck.txt and network, what NPI leaves behind, classic NVIDIA Inspector 1.9.8.7 without a driver.
param([string]$Run = 'run-manual', [string]$Machine = 'windows-2025')
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$root = (Get-Location).Path
$out = Join-Path $root "results\$Run\$Machine\round5"
New-Item -ItemType Directory -Force -Path $out | Out-Null
. (Join-Path $PSScriptRoot 'lab_common.ps1')
[W]::SetRes(1920, 1080) | Out-Null
$tmp = Join-Path $env:RUNNER_TEMP 'r5'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$v = 'v3.0.2.1'
$zip = Join-Path $tmp 'npi.zip'
Invoke-WebRequest "https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/$v/nvidiaProfileInspector.zip" -OutFile $zip -UseBasicParsing
$dir = Join-Path $tmp 'npi'; Expand-Archive $zip $dir -Force
$appData = Join-Path $env:LOCALAPPDATA 'nvidiaProfileInspector'
$results = [ordered]@{ version = $v; machine = $Machine; date = (Get-Date).ToString('o') }

function Tree($p) { if (Test-Path $p) { @(Get-ChildItem $p -Recurse -Force | ForEach-Object { "$($_.FullName.Substring($p.Length)) $($_.Length)" }) } else { @() } }
function Main-Window($p) {
  for ($i = 0; $i -lt 80; $i++) {
    Start-Sleep -Milliseconds 250
    $ws = [W]::ForPid([uint32]$p.Id) | Where-Object { [W]::Title($_) -like '*PROFILE INSPECTOR*' }
    $big = $ws | Where-Object { $r = New-Object W+RECT; [W]::GetWindowRect($_, [ref]$r) | Out-Null; ($r.R - $r.L) -gt 600 } | Select-Object -First 1
    if ($big) { return $big }
  }
  return $null
}
function Rect($h) { $r = New-Object W+RECT; [W]::GetWindowRect($h, [ref]$r) | Out-Null; [ordered]@{ left = $r.L; top = $r.T; width = $r.R - $r.L; height = $r.B - $r.T } }
function Start-Npi($exeDir, $workDir, $argList) {
  Start-Process -FilePath (Join-Path $exeDir 'nvidiaProfileInspector.exe') -ArgumentList $argList -WorkingDirectory $workDir -PassThru
}
function Close-Npi($p) {
  # graceful close so NPI can save its settings, then make sure it is gone
  try { $p.CloseMainWindow() | Out-Null } catch {}
  for ($i = 0; $i -lt 40 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 250 }
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; return 'killed' }
  return 'closed'
}
$geo = @{ WindowLeft = 111; WindowTop = 77; WindowWidth = 1111; WindowHeight = 777 }

# --- A. settings location (T-INST-07) ---
Remove-Item -Recurse -Force $appData -ErrorAction SilentlyContinue
$a = [ordered]@{}
# A1: no settings anywhere, start from the exe folder; close normally; where does settings.xml appear?
$d1 = Join-Path $tmp 'a1'; Copy-Item -Recurse $dir $d1
$p = Start-Npi $d1 $d1 @('-mock'); $h = Main-Window $p
$a.a1_mainWindow = [bool]$h; if ($h) { $a.a1_rect = Rect $h; Shot (Join-Path $out 'a1-default.png') $h | Out-Null }
$a.a1_close = Close-Npi $p; Start-Sleep 1
$a.a1_appDataTree = Tree $appData
$a.a1_exeDirNewFiles = @(Get-ChildItem $d1 | Where-Object { -not (Test-Path (Join-Path $dir $_.Name)) } | ForEach-Object Name)
# A2: portable settings.xml next to the exe, started with the exe folder as working directory
$d2 = Join-Path $tmp 'a2'; Copy-Item -Recurse $dir $d2; Write-Settings $d2 $geo
$p = Start-Npi $d2 $d2 @('-mock'); $h = Main-Window $p
if ($h) { $a.a2_rect = Rect $h; Shot (Join-Path $out 'a2-portable-same-folder.png') $h | Out-Null }
$a.a2_close = Close-Npi $p
# A3: same portable settings.xml next to the exe, but started from another working directory (like a shortcut "Start in")
$other = Join-Path $tmp 'elsewhere'; New-Item -ItemType Directory -Force -Path $other | Out-Null
$p = Start-Npi $d2 $other @('-mock'); $h = Main-Window $p
if ($h) { $a.a3_rect = Rect $h; Shot (Join-Path $out 'a3-portable-other-workdir.png') $h | Out-Null }
$a.a3_close = Close-Npi $p
$a.a3_otherDirFiles = @(Get-ChildItem $other -Force | ForEach-Object Name)
$a.expectedPortableRect = $geo
$results.settingsLocation = $a

# --- B. favourites (T-UI-08) ---
$b = [ordered]@{}
$d4 = Join-Path $tmp 'b'; Copy-Item -Recurse $dir $d4
# Frame Rate Limiter V3 = 0x10835002 = 277041154
Write-Settings $d4 @{ FavoriteSettingIds = '<unsignedInt>277041154</unsignedInt>' }
$p = Start-Npi $d4 $d4 @('-mock'); $h = Main-Window $p
if ($h) { Start-Sleep 2; $t = Texts $h; $b.favoritesGroupShown = [bool]($t | Where-Object { $_ -like '*Favorites*' }); $b.textsSample = @($t | Select-Object -First 40); Shot (Join-Path $out 'b-favourites.png') $h | Out-Null }
$b.close = Close-Npi $p
$x = Get-Content (Join-Path $d4 'settings.xml') -Raw -Encoding Unicode
$b.idStillSavedAfterClose = $x -match '277041154'
$b.settingsAfterClose = $x
$results.favourites = $b

# --- C. update check vs DisableUpdateCheck.txt (T-INST-07) ---
function Net-Probe($exeDir, $name) {
  $p = Start-Npi $exeDir $exeDir @('-mock')
  $seen = @{}
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 500
    Get-NetTCPConnection -OwningProcess $p.Id -ErrorAction SilentlyContinue | Where-Object { $_.RemotePort -eq 443 } | ForEach-Object { $seen[$_.RemoteAddress] = 1 }
  }
  $h = Main-Window $p; if ($h) { Shot (Join-Path $out "c-$name.png") $h | Out-Null }
  Close-Npi $p | Out-Null
  [ordered]@{ https443RemoteAddresses = @($seen.Keys); count = $seen.Count }
}
$c = [ordered]@{}
$d5 = Join-Path $tmp 'c-on'; Copy-Item -Recurse $dir $d5; Write-Settings $d5 @{ DisableUpdateCheck = 'false'; UpdateChannel = 'Release' }
$c.updateCheckOn = Net-Probe $d5 'update-on'
$d6 = Join-Path $tmp 'c-file'; Copy-Item -Recurse $dir $d6; Write-Settings $d6 @{ DisableUpdateCheck = 'false'; UpdateChannel = 'Release' }
Set-Content -Path (Join-Path $d6 'DisableUpdateCheck.txt') -Value '' -Encoding Ascii
$c.disableUpdateCheckTxt = Net-Probe $d6 'disable-file'
$d7 = Join-Path $tmp 'c-setting'; Copy-Item -Recurse $dir $d7; Write-Settings $d7 @{ DisableUpdateCheck = 'true' }
$c.disableUpdateCheckSetting = Net-Probe $d7 'disable-setting'
$c.githubAddresses = @([System.Net.Dns]::GetHostAddresses('github.com') | ForEach-Object { $_.IPAddressToString })
$c.apiGithubAddresses = @([System.Net.Dns]::GetHostAddresses('api.github.com') | ForEach-Object { $_.IPAddressToString })
$results.updateCheck = $c

# --- D. what NPI leaves behind (T-INST-06) ---
$dd = [ordered]@{}
$dd.appDataTree = Tree $appData
$dd.hkcuNip = (Get-ItemProperty 'HKCU:\Software\Classes\.nip' -ErrorAction SilentlyContinue | Select-Object '(default)')
$dd.hkcuProgId = @(Get-ChildItem 'HKCU:\Software\Classes\nvidiaProfileInspector.nip' -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$dd.hkcuSoftwareKeys = @(Get-ChildItem 'HKCU:\Software' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'nvidia|orbmu2k|ProfileInspector' } | ForEach-Object { $_.Name })
$dd.tempMatches = @(Get-ChildItem $env:TEMP -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'nvidiaProfileInspector|npi' } | ForEach-Object { $_.FullName })
$dd.startMenu = @(Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Profile Inspector' } | ForEach-Object { $_.FullName })
$results.leftovers = $dd

# --- E. classic NVIDIA Inspector 1.9.8.7 (T-INST-09) ---
$e = [ordered]@{ url = 'https://download.orbmu2k.de/files/nvidiaInspector.zip' }
$cz = Join-Path $tmp 'ni.zip'
try { Invoke-WebRequest $e.url -OutFile $cz -UseBasicParsing } catch { $e.downloadError = $_.Exception.Message }
if (Test-Path $cz) {
  $e.zipBytes = (Get-Item $cz).Length; $e.zipSha256 = (Get-FileHash $cz).Hash.ToLower()
  $cd = Join-Path $tmp 'ni'; Expand-Archive $cz $cd -Force
  $ex = Join-Path $cd 'nvidiaInspector.exe'
  $e.exeSha256 = (Get-FileHash $ex).Hash.ToLower(); $e.fileVersion = (Get-Item $ex).VersionInfo.FileVersion
  $s = Get-AuthenticodeSignature $ex; $e.signature = "$($s.Status)"
  $e.defender = (& "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -Scan -ScanType 3 -File $ex -DisableRemediation 2>&1 | Out-String).Trim()
  $p = Start-Process -FilePath $ex -WorkingDirectory $cd -PassThru
  Start-Sleep 12
  $e.exited = $p.HasExited; if ($p.HasExited) { $e.exitCode = $p.ExitCode }
  $wins = @(); $i = 0
  if (-not $p.HasExited) {
    foreach ($h in [W]::ForPid([uint32]$p.Id)) { $wins += [ordered]@{ title = [W]::Title($h); texts = (Texts $h) }; Shot (Join-Path $out "e-classic-$i.png") $h | Out-Null; $i++ }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
  # .NET error dialogs belong to other processes (WerFault); capture any top-level window mentioning the inspector
  $e.windows = $wins
  $e.otherWindows = @(Get-Process | Where-Object { $_.MainWindowTitle -match 'Inspector|nvidia' } | ForEach-Object { "$($_.ProcessName): $($_.MainWindowTitle)" })
}
$results.classicInspector = $e
Save-Json $results (Join-Path $out 'round5.json')
$results | ConvertTo-Json -Depth 6
