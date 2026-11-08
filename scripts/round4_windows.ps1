# Round 4 (Windows runner): Mark-of-the-Web/SmartScreen, built-in updater, Procmon trace, package managers,
# UI export automation, Add Application dialog, encodings/unknown IDs, NVPI Revamped (fork) start without a driver.
param([string]$Run = 'run-manual', [string]$Machine = 'windows-2025')
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$root = (Get-Location).Path
$out = Join-Path $root "results\$Run\$Machine\round4"
New-Item -ItemType Directory -Force -Path $out | Out-Null
. (Join-Path $PSScriptRoot 'lab_common.ps1')
[W]::SetRes(1920, 1080) | Out-Null
$tmp = Join-Path $env:RUNNER_TEMP 'r4'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$v = 'v3.0.2.1'
$zip = Join-Path $tmp 'npi.zip'
Invoke-WebRequest "https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/$v/nvidiaProfileInspector.zip" -OutFile $zip -UseBasicParsing
$dir = Join-Path $tmp 'npi'; Expand-Archive $zip $dir -Force
$all = @()

# --- MOTW / SmartScreen (T-LAB-12) ---
$motw = [ordered]@{}
$mz = Join-Path $tmp 'motw.zip'; Copy-Item $zip $mz
Set-Content -Path $mz -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://github.com/" -Encoding Ascii
$motw.zipStream = (Get-Content $mz -Stream Zone.Identifier -ErrorAction SilentlyContinue) -join ' '
$mx = Join-Path $tmp 'motw-x'; Expand-Archive $mz $mx -Force
$motw.exeStreamAfterExpandArchive = (Get-Content (Join-Path $mx 'nvidiaProfileInspector.exe') -Stream Zone.Identifier -ErrorAction SilentlyContinue) -join ' '
$m7 = Join-Path $tmp 'motw-7z'; & 'C:\Program Files\7-Zip\7z.exe' x -y "-o$m7" $mz | Out-Null
$motw.exeStreamAfter7zip = (Get-Content (Join-Path $m7 'nvidiaProfileInspector.exe') -Stream Zone.Identifier -ErrorAction SilentlyContinue) -join ' '
# Copy-with-stream: simulate Explorer extraction propagating MOTW by writing the stream onto the exe
$me = Join-Path $tmp 'motw-explorer'; Copy-Item -Recurse $dir $me
Set-Content -Path (Join-Path $me 'nvidiaProfileInspector.exe') -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3" -Encoding Ascii
$motw.smartScreenPolicy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -ErrorAction SilentlyContinue | Select-Object EnableSmartScreen, ShellSmartScreenLevel
$motw.explorerSmartScreen = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -ErrorAction SilentlyContinue).SmartScreenEnabled
Save-Json $motw (Join-Path $out 'motw.json')
$all += Run-Case $v $me 'r4-motw-start' @('-mock') @{} 15 $null

# --- Updater (T-LAB-13) ---
$all += Run-Case $v $dir 'r4-updater-checknow' @('-mock') @{ UpdateChannel = 'Release' } 25 {
  param($h, $p)
  $a = Invoke-ByHelp $h 'About'; Start-Sleep 2
  $c = Click-Dialog-Button $p 'Check Now'; Start-Sleep 6
  "$a ; $c"
}
$all += Run-Case $v $dir 'r4-updater-prerelease-channel' @('-mock') @{ UpdateChannel = 'Prerelease' } 30 {
  param($h, $p)
  $a = Invoke-ByHelp $h 'About'; Start-Sleep 2
  $c = Click-Dialog-Button $p 'Check Now'; Start-Sleep 6
  "$a ; $c"
}

# --- Procmon trace (T-LAB-11) ---
$pm = Join-Path $tmp 'Procmon64.exe'
try { Invoke-WebRequest 'https://live.sysinternals.com/Procmon64.exe' -OutFile $pm -UseBasicParsing } catch {}
if (Test-Path $pm) {
  $pml = Join-Path $tmp 'trace.pml'
  Start-Process $pm -ArgumentList '/AcceptEula', '/Quiet', '/Minimized', '/BackingFile', $pml
  Start-Sleep 8
  $all += Run-Case $v $dir 'r4-procmon-session' @('-mock') @{ DisableUpdateCheck = 'false' } 20 { param($h, $p) $f = Forward $p @('game-fortnite.nip') @('-silentImport'); "$f" }
  & $pm /Terminate; Start-Sleep 8
  $csv = Join-Path $tmp 'trace.csv'
  Start-Process $pm -ArgumentList '/AcceptEula', '/OpenLog', $pml, '/SaveAs', $csv -Wait
  if (Test-Path $csv) {
    $rows = Import-Csv $csv | Where-Object { $_.'Process Name' -eq 'nvidiaProfileInspector.exe' }
    $rows | Group-Object Operation | Sort-Object Count -Descending | Select-Object Name, Count | Export-Csv (Join-Path $out 'procmon-operations.csv') -NoTypeInformation
    $rows | Where-Object { $_.Operation -match 'WriteFile|CreateFile|RegSetValue|RegCreateKey|TCP|UDP' -and $_.Result -eq 'SUCCESS' } |
      Select-Object Operation, Path | Sort-Object Operation, Path -Unique | Export-Csv (Join-Path $out 'procmon-writes-and-network.csv') -NoTypeInformation
  }
}

# --- Package managers (T-LAB-14) ---
$pk = [ordered]@{}
$pk.chocoInfo = (& choco info nvidia-profile-inspector 2>&1 | Out-String).Trim()
$pk.chocoInfoOld = (& choco info nvidia-inspector 2>&1 | Out-String).Trim()
& choco install nvidia-profile-inspector -y --no-progress 2>&1 | Out-Null
$ci = Get-ChildItem 'C:\ProgramData\chocolatey\lib\nvidia-profile-inspector' -Recurse -File -ErrorAction SilentlyContinue
$pk.chocoFiles = @($ci | ForEach-Object { [ordered]@{ path = $_.FullName; bytes = $_.Length; sha256 = (Get-FileHash $_.FullName).Hash.ToLower(); version = $_.VersionInfo.FileVersion } })
if (Get-Command winget -ErrorAction SilentlyContinue) {
  $pk.wingetShow = (& winget show --id Orbmu2k.NvidiaProfileInspector --accept-source-agreements 2>&1 | Out-String).Trim()
  $wd = Join-Path $tmp 'winget'; & winget download --id Orbmu2k.NvidiaProfileInspector -d $wd --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
  $pk.wingetFiles = @(Get-ChildItem $wd -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; bytes = $_.Length; sha256 = (Get-FileHash $_.FullName).Hash.ToLower() } })
} else { $pk.winget = 'not available on this runner image' }
Save-Json $pk (Join-Path $out 'package-managers.json')

# --- Export automation, Add Application, encodings (T-LAB-09) ---
function Save-Through-Dialog($p, $card, $path) {
  $r = Click-Dialog-Button $p $card; Start-Sleep 3
  foreach ($h in [W]::ForPid([uint32]$p.Id)) {
    try {
      $el = [System.Windows.Automation.AutomationElement]::FromHandle($h)
      $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, '1001')
      $edit = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
      if ($edit) {
        $vp = $null; if ($edit.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { $vp.SetValue($path) }
        $edit.SetFocus(); [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); Start-Sleep 3
        return "$r ; saved=$(Test-Path $path)"
      }
    } catch {}
  }
  return "$r ; no-save-dialog"
}
$games = @('game-cyberpunk-2077.nip', 'game-fortnite.nip', 'game-skyrim-se.nip', 'game-rdr2.nip')
foreach ($card in @('Export current profile only', 'Export current profile including predefined', 'Export all customized profiles', 'Export all profiles (NVIDIA Text Format)')) {
  $slug = ($card -replace '[^A-Za-z]+', '-').ToLower().Trim('-')
  $target = Join-Path $out "export-$slug.$(if ($card -match 'Text') {'txt'} else {'nip'})"
  $all += Run-Case $v $dir "r4-export-$slug" @('-mock') @{ WindowLeft = 120 } 35 ([scriptblock]::Create(@"
param(`$h, `$p)
`$f = Forward `$p @('game-cyberpunk-2077.nip','game-fortnite.nip','game-skyrim-se.nip','game-rdr2.nip') @('-silentImport')
`$s = Select-Profile `$h 'Fortnite'
`$e = Invoke-ByHelp `$h 'Export profiles to file'; Start-Sleep 2
`$d = Save-Through-Dialog `$p '$card' '$target'
"`$f ; `$s ; `$e ; `$d"
"@))
}
$all += Run-Case $v $dir 'r4-add-application' @('-mock') @{ WindowLeft = 120 } 30 { param($h, $p) $f = Forward $p @('game-fortnite.nip') @('-silentImport'); $s = Select-Profile $h 'Fortnite'; $a = Invoke-ByHelp $h 'Add Application'; "$f ; $s ; $a" }
$all += Run-Case $v $dir 'r4-row-reset' @('-mock') @{ WindowLeft = 120 } 30 { param($h, $p) $f = Forward $p @('game-fortnite.nip') @('-silentImport'); $s = Select-Profile $h 'Fortnite'; Set-Search $h 'Frame Rate Limiter V3' | Out-Null; $r = Select-Row $h 'Frame Rate Limiter V3'; $x = Invoke-ByHelp $h 'Reset setting to default value'; "$f ; $s ; $r ; $x" }
$all += Run-Case $v $dir 'r4-delete-profile' @('-mock') @{ WindowLeft = 120 } 30 { param($h, $p) $f = Forward $p @('replace-a.nip') @('-silentImport'); $s = Select-Profile $h 'NPI Lab Replace Test'; $d = Invoke-ByHelp $h 'Delete the current profile'; Start-Sleep 2; $y = Click-Dialog-Button $p 'Yes'; "$f ; $s ; $d ; $y" }
# encodings and unknown IDs: build variants of the lab sample
$src = [IO.File]::ReadAllText((Join-Path $root 'samples\npilab-sample.nip'), [Text.Encoding]::Unicode)
[IO.File]::WriteAllText((Join-Path $dir 'enc-utf8bom.nip'), $src, (New-Object Text.UTF8Encoding $true))
[IO.File]::WriteAllText((Join-Path $dir 'enc-utf8nobom.nip'), $src, (New-Object Text.UTF8Encoding $false))
$unknown = $src.Replace('<SettingID>274197361</SettingID>', '<SettingID>305419896</SettingID>').Replace('NPI Lab Sample', 'NPI Lab Unknown ID')
[IO.File]::WriteAllText((Join-Path $dir 'unknown-id.nip'), $unknown, [Text.Encoding]::Unicode)
$legacy = $src.Replace('NPI Lab Sample', 'NPI Lab Legacy 2.4 style')
[IO.File]::WriteAllText((Join-Path $dir 'legacy-24.nip'), $legacy, [Text.Encoding]::Unicode)
foreach ($n in @('enc-utf8bom', 'enc-utf8nobom', 'unknown-id', 'legacy-24')) {
  $all += Run-Case $v $dir "r4-import-$n" @('-mock', "$n.nip") @{} 15 $null
}

# --- NVPI Revamped (fork) without a driver ---
try {
  $rel = Invoke-RestMethod 'https://api.github.com/repos/xHybred/NvidiaProfileInspectorRevamped/releases/latest' -Headers @{ 'User-Agent' = 'npi-lab' }
  $asset = $rel.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1
  $fz = Join-Path $tmp 'revamped.zip'; Invoke-WebRequest $asset.browser_download_url -OutFile $fz -UseBasicParsing
  $fx = Join-Path $tmp 'revamped'; Expand-Archive $fz $fx -Force
  $fork = [ordered]@{ tag = $rel.tag_name; published = $rel.published_at; asset = $asset.name; bytes = (Get-Item $fz).Length; sha256 = (Get-FileHash $fz).Hash.ToLower();
    files = @(Get-ChildItem $fx -Recurse -File | ForEach-Object { [ordered]@{ path = $_.FullName.Substring($fx.Length + 1); bytes = $_.Length; version = $_.VersionInfo.FileVersion } }) }
  Save-Json $fork (Join-Path $out 'revamped.json')
  $fexe = Get-ChildItem $fx -Recurse -Filter '*.exe' | Select-Object -First 1
  if ($fexe) {
    $p = Start-Process $fexe.FullName -WorkingDirectory $fexe.DirectoryName -PassThru; Start-Sleep 12
    $ws = [W]::ForPid([uint32]$p.Id); $i = 0
    $info = @(); foreach ($h in $ws) { $info += [ordered]@{ title = [W]::Title($h); texts = (Texts $h); shot = (Shot (Join-Path $out "revamped-window-$i.png") $h) }; $i++ }
    Save-Json $info (Join-Path $out 'revamped-start.json'); Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
} catch { "revamped: $($_.Exception.Message)" | Set-Content (Join-Path $out 'revamped-error.txt') }

Save-Json $all (Join-Path $out 'cases.json')
Write-Host "round 4 done: $($all.Count) cases"
