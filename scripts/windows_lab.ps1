# nvprofileinspector.com test lab: Windows matrix for NVIDIA Profile Inspector (NPI).
# Runs on GitHub-hosted Windows runners (no NVIDIA GPU, no NVIDIA driver).
# What it can prove: release files, hashes, signatures, manifest, Defender verdict, behaviour
# without an NVIDIA driver, the built-in -mock mode UI (themes, views, dialogs), CLI switches,
# .nip import/export in mock mode. What it cannot prove: anything that needs a real driver.
param([string]$Run = 'run-manual', [string]$Machine = 'windows')
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$root = (Get-Location).Path
$out = Join-Path $root "results\$Run\$Machine"
$dl = Join-Path $root 'dl'
New-Item -ItemType Directory -Force -Path $out, $dl | Out-Null
. (Join-Path $PSScriptRoot 'lab_common.ps1')

# ---------- machine facts ----------
$mf = [ordered]@{ machine = $Machine; run = $Run; date = (Get-Date).ToString('o') }
$os = Get-CimInstance Win32_OperatingSystem
$mf.os = "$($os.Caption) $($os.Version) build $($os.BuildNumber)"
$mf.cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$mf.ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$mf.gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name) | driver $($_.DriverVersion)" })
$mf.netFxRelease = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
$mf.netFxVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Version
$mf.nvapi64 = Test-Path "$env:WINDIR\System32\nvapi64.dll"
$mf.nvapi32 = Test-Path "$env:WINDIR\SysWOW64\nvapi.dll"
$mf.drsFolder = Test-Path "$env:ProgramData\NVIDIA Corporation\Drs"
$mf.isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$mf.uacEnableLUA = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
$mf.resolutionBefore = "$([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width)x$([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)"
$mf.setResolution = [W]::SetRes(1920, 1080)
Start-Sleep -Seconds 2
$mf.resolutionAfter = "$([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width)x$([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)"
try { $mp = Get-MpComputerStatus; $mf.defender = [ordered]@{ AMServiceEnabled = $mp.AMServiceEnabled; RealTimeProtectionEnabled = $mp.RealTimeProtectionEnabled; AntivirusSignatureVersion = $mp.AntivirusSignatureVersion } } catch { $mf.defender = "unavailable: $($_.Exception.Message)" }
Save-Json $mf (Join-Path $out 'machine.json')
Write-Host ($mf | ConvertTo-Json -Depth 4)

# ---------- downloads ----------
$versions = @('v3.0.2.1', 'v3.0.2.3', '2.4.0.29', 'v2.4.0.35', '2.4.0.4')
$mt = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter mt.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like '*x64*' } | Select-Object -First 1
$sigcheckOk = $false
$downloads = @()
$dirs = @{}
foreach ($v in $versions) {
  $zip = Join-Path $dl "npi-$v.zip"
  $url = "https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/$v/nvidiaProfileInspector.zip"
  $d = [ordered]@{ version = $v; url = $url }
  try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing } catch { $d.error = $_.Exception.Message; $downloads += $d; continue }
  $d.zipBytes = (Get-Item $zip).Length
  $d.zipSha256 = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
  $x = Join-Path $dl "npi-$v"; Expand-Archive -Path $zip -DestinationPath $x -Force
  $exe = Get-ChildItem $x -Recurse -Filter 'nvidiaProfileInspector.exe' | Select-Object -First 1
  if (-not $exe) { $d.error = 'no exe in zip'; $downloads += $d; continue }
  $dirs[$v] = $exe.DirectoryName
  $d.files = @(Get-ChildItem $x -Recurse -File | ForEach-Object { [ordered]@{ path = $_.FullName.Substring($x.Length + 1); bytes = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower() } })
  $vi = $exe.VersionInfo
  $d.exe = [ordered]@{ FileVersion = $vi.FileVersion; ProductVersion = $vi.ProductVersion; ProductName = $vi.ProductName; CompanyName = $vi.CompanyName; FileDescription = $vi.FileDescription; LegalCopyright = $vi.LegalCopyright; OriginalFilename = $vi.OriginalFilename }
  $sig = Get-AuthenticodeSignature $exe.FullName
  $d.authenticode = [ordered]@{ status = "$($sig.Status)"; message = $sig.StatusMessage; signer = "$($sig.SignerCertificate.Subject)" }
  try { $asm = [Reflection.AssemblyName]::GetAssemblyName($exe.FullName); $d.assembly = [ordered]@{ name = $asm.FullName; arch = "$($asm.ProcessorArchitecture)" } } catch { $d.assembly = "not-managed: $($_.Exception.Message)" }
  try {
    $bytes = [IO.File]::ReadAllBytes($exe.FullName); $peOff = [BitConverter]::ToInt32($bytes, 0x3C); $machineType = [BitConverter]::ToUInt16($bytes, $peOff + 4)
    $d.peMachine = '0x{0:X4}' -f $machineType
    $s = [Text.Encoding]::ASCII.GetString($bytes); $m = [regex]::Match($s, 'v4\.0\.30319|\.NETFramework,Version=v[0-9.]+'); $d.targetFramework = [regex]::Matches($s, '\.NETFramework,Version=v[0-9.]+') | ForEach-Object Value | Select-Object -Unique
  } catch {}
  if ($mt) {
    $man = Join-Path $out "manifest-$v.xml"
    & $mt.FullName -nologo "-inputresource:$($exe.FullName);#1" "-out:$man" 2>&1 | Out-Null
    if (Test-Path $man) { $d.manifestLevel = ([regex]::Match((Get-Content $man -Raw), 'level="([^"]+)"')).Groups[1].Value }
  }
  try {
    $mpcmd = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    if (Test-Path $mpcmd) { $scan = & $mpcmd -Scan -ScanType 3 -File $x -DisableRemediation 2>&1; $d.defenderScan = ($scan | Out-String).Trim(); $d.defenderExit = $LASTEXITCODE }
  } catch { $d.defenderScan = "error: $($_.Exception.Message)" }
  $downloads += $d
}
Save-Json $downloads (Join-Path $out 'downloads.json')

# ---------- cases ----------
$all = @()
$focusAction = { param($h, $p) 'none' }
foreach ($v in $dirs.Keys) {
  $dir = $dirs[$v]
  $is3 = $v -like 'v3*'
  $all += Run-Case $v $dir 'nodriver' @() $(if ($is3) { @{} } else { $null }) 15 $null
  $all += Run-Case $v $dir 'cli-createCSN' @('-createCSN') $null 15 $null
  $all += Run-Case $v $dir 'cli-exportCustomized-nodriver' @('-exportCustomized') $null 15 $null
  if (-not $is3) { continue }
  $all += Run-Case $v $dir 'mock-splash' @('-mock') @{} 10 $null
  $all += Run-Case $v $dir 'mock-dark' @('-mock') @{ Theme = 'DarkTheme.xaml' } 12 $null
  if ($v -ne 'v3.0.2.1') { continue }
  $all += Run-Case $v $dir 'mock-midnight' @('-mock') @{ Theme = 'MidnightTheme.xaml' } 12 $null
  $all += Run-Case $v $dir 'mock-cleanwhite' @('-mock') @{ Theme = 'CleanWhiteTheme.xaml' } 12 $null
  $all += Run-Case $v $dir 'mock-slatelight' @('-mock') @{ Theme = 'SlateLightTheme.xaml' } 12 $null
  $all += Run-Case $v $dir 'mock-compact' @('-mock') @{ DisplayDensity = 'Compact' } 12 $null
  $all += Run-Case $v $dir 'mock-allsources' @('-mock') @{ SettingSourceDriver = 'true'; SettingSourceConstants = 'true'; SettingSourceReference = 'true'; SettingSourceScan = 'true'; ShowSettingIdInName = 'true' } 14 $null
  $all += Run-Case $v $dir 'mock-search-dlss' @('-mock') @{} 12 { param($h, $p) Set-Search $h 'dlss' }
  $all += Run-Case $v $dir 'mock-search-rebar' @('-mock') @{ SettingSourceReference = 'true' } 12 { param($h, $p) Set-Search $h 'rebar' }
  $all += Run-Case $v $dir 'mock-search-frame' @('-mock') @{} 12 { param($h, $p) Set-Search $h 'frame rate' }
  $all += Run-Case $v $dir 'mock-about' @('-mock') @{} 12 { param($h, $p) Invoke-ByHelp $h 'About' }
  $all += Run-Case $v $dir 'mock-biteditor' @('-mock') @{} 12 { param($h, $p) Invoke-ByHelp $h 'Open the Bit Value Editor' }
  $all += Run-Case $v $dir 'mock-export' @('-mock') @{} 12 { param($h, $p) Invoke-ByHelp $h 'Export profiles to file' }
  $all += Run-Case $v $dir 'mock-newprofile' @('-mock') @{} 12 { param($h, $p) Invoke-ByHelp $h 'Create a new profile' }
  $all += Run-Case $v $dir 'mock-appearance' @('-mock') @{} 12 { param($h, $p) Invoke-ByHelp $h 'Appearance' }
  $all += Run-Case $v $dir 'mock-filter' @('-mock') @{} 12 { param($h, $p) Invoke-ByHelp $h 'Filter setting and value sources' }
  $all += Run-Case $v $dir 'mock-restore-driver' @('-mock') @{} 12 { param($h, $p) Invoke-ByHelp $h 'Restore profile to NVIDIA default settings' }
  $all += Run-Case $v $dir 'mock-import-interactive' @('-mock', 'npilab-sample.nip') @{} 14 $null
  $all += Run-Case $v $dir 'mock-import-silent' @('-mock', '-silentImport', 'npilab-sample.nip') @{} 14 $null
  $all += Run-Case $v $dir 'mock-import-merge' @('-mock', '-mergeImport', 'npilab-sample.nip') @{} 14 $null
  $all += Run-Case $v $dir 'mock-exportCustomized' @('-mock', '-exportCustomized') $null 15 $null
  $all += Run-Case $v $dir 'mock-import-then-modified' @('-mock', '-silentImport', 'npilab-sample.nip') @{} 14 { param($h, $p) Invoke-ByHelp $h 'View Modified Profiles' }

  # ---- round 3: populated profiles, NPI's Replace/Merge logic, prompts and resets (mock mode) ----
  $games = @('game-cyberpunk-2077.nip', 'game-fortnite.nip', 'game-skyrim-se.nip', 'game-rdr2.nip')
  $all += Run-Case $v $dir 'r3-populated-modified-list' @('-mock') @{ WindowLeft = 120 } 26 { param($h, $p) $f = Forward $p $games @('-silentImport'); $m = Invoke-ByHelp $h 'View Modified Profiles'; "$f ; $m" }
  $all += Run-Case $v $dir 'r3-profile-cyberpunk' @('-mock') @{ WindowLeft = 120 } 26 { param($h, $p) $f = Forward $p $games @('-silentImport'); $s = Select-Profile $h 'Cyberpunk 2077'; Set-Search $h 'dlss' | Out-Null; "$f ; $s" }
  $all += Run-Case $v $dir 'r3-profile-fortnite' @('-mock') @{ WindowLeft = 120 } 26 { param($h, $p) $f = Forward $p $games @('-silentImport'); $s = Select-Profile $h 'Fortnite'; "$f ; $s" }
  $all += Run-Case $v $dir 'r3-profile-rdr2-rebar' @('-mock') @{ WindowLeft = 120; SettingSourceReference = 'true' } 26 { param($h, $p) $f = Forward $p $games @('-silentImport'); $s = Select-Profile $h 'Red Dead Redemption 2'; Set-Search $h 'rbar' | Out-Null; "$f ; $s" }
  $all += Run-Case $v $dir 'r3-import-prompt' @('-mock') @{ WindowLeft = 120 } 22 { param($h, $p) Forward $p @('game-skyrim-se.nip') @() }
  $all += Run-Case $v $dir 'r3-replace' @('-mock') @{ WindowLeft = 120 } 30 { param($h, $p) $a = Forward $p @('replace-a.nip') @('-silentImport'); $b = Forward $p @('replace-b.nip') @('-replaceImport', '-silentImport'); $s = Select-Profile $h 'NPI Lab Replace Test'; "$a ; $b ; $s" }
  $all += Run-Case $v $dir 'r3-merge' @('-mock') @{ WindowLeft = 120 } 30 { param($h, $p) $a = Forward $p @('replace-a.nip') @('-silentImport'); $b = Forward $p @('replace-b.nip') @('-mergeImport', '-silentImport'); $s = Select-Profile $h 'NPI Lab Replace Test'; "$a ; $b ; $s" }
  $all += Run-Case $v $dir 'r3-defaults-on-custom' @('-mock') @{ WindowLeft = 120 } 30 { param($h, $p) $a = Forward $p @('replace-a.nip') @('-silentImport'); $s = Select-Profile $h 'NPI Lab Replace Test'; $d = Invoke-ByHelp $h 'Restore profile to NVIDIA default settings'; Start-Sleep 2; $y = Click-Dialog-Button $p 'Yes'; Start-Sleep 2; "$a ; $s ; defaults=$d ; $y" }
  $all += Run-Case $v $dir 'r3-copy-populated' @('-mock') @{ WindowLeft = 120 } 28 { param($h, $p) $f = Forward $p $games @('-silentImport'); $s = Select-Profile $h 'Fortnite'; $r = Invoke-ByHelp $h 'Copy settings to clipboard'; Start-Sleep 1; $c = Get-Clipboard -Raw; if ($c) { [IO.File]::WriteAllText((Join-Path $out "$v\r3-copy-populated\clipboard.txt"), $c) }; "$f ; $s ; $r ; chars=$($c.Length)" }
  $all += Run-Case $v $dir 'mock-update-check-on' @('-mock') @{ DisableUpdateCheck = 'false' } 20 $null
  $all += Run-Case $v $dir 'mock-software-render' @('-mock', '-useSoftwareRendering', '-disableTransparency') @{} 12 $null

  $all += Run-Case $v $dir 'mock-search-hexid' @('-mock') @{} 12 { param($h, $p) Set-Search $h '0x10835002' }
  $all += Run-Case $v $dir 'mock-search-fps' @('-mock') @{} 12 { param($h, $p) Set-Search $h 'fps' }
  $all += Run-Case $v $dir 'mock-search-vsync' @('-mock') @{} 12 { param($h, $p) Set-Search $h 'vsync' }
  $all += Run-Case $v $dir 'mock-search-preset' @('-mock') @{ SettingSourceReference = 'true'; SettingSourceDriver = 'true' } 12 { param($h, $p) Set-Search $h 'preset' }
  $all += Run-Case $v $dir 'mock-biteditor-ao' @('-mock') @{} 12 { param($h, $p) $a = Select-Row $h 'Ambient Occlusion - Compatibility'; Start-Sleep 1; $b = Invoke-ByHelp $h 'Open the Bit Value Editor'; "$a ; $b" }
  $all += Run-Case $v $dir 'mock-row-frl' @('-mock') @{} 12 { param($h, $p) Set-Search $h 'Frame Rate Limiter V3' | Out-Null; Start-Sleep 1; Select-Row $h 'Frame Rate Limiter V3' }
  $all += Run-Case $v $dir 'mock-copy-clipboard' @('-mock') @{} 12 { param($h, $p) $r = Invoke-ByHelp $h 'Copy settings to clipboard'; Start-Sleep 1; $c = Get-Clipboard -Raw; if ($c) { [IO.File]::WriteAllText((Join-Path $out "$v\mock-copy-clipboard\clipboard.txt"), $c) }; "$r ; clipboard chars=$($c.Length)" }
  $all += Run-Case $v $dir 'mock-addapp' @('-mock') @{} 12 { param($h, $p) Invoke-ByHelp $h 'Add Application' }
  $all += Run-Case $v $dir 'mock-modified-empty' @('-mock') @{} 12 { param($h, $p) Invoke-ByHelp $h 'View Modified Profiles' }
  $all += Run-Case $v $dir 'mock-import-button' @('-mock') @{} 12 { param($h, $p) Invoke-ByHelp $h 'Import profiles from file' }
  $all += Run-Case $v $dir 'mock-forward-import' @('-mock') @{ WindowLeft = 120 } 20 {
    param($h, $p)
    # A second process with a .nip forwards the file to the running instance (single-instance import).
    $work2 = Split-Path -Parent $p.Path
    $q = Start-Process -FilePath $p.Path -ArgumentList @('-mock', (Join-Path $work2 'npilab-sample.nip')) -WorkingDirectory $work2 -PassThru
    Start-Sleep -Seconds 6
    $second = if ($q.HasExited) { "second-exited:$($q.ExitCode)" } else { 'second-running' }
    "forwarded ; $second"
  }
  $all += Run-Case $v $dir 'mock-forward-import-modified' @('-mock') @{ WindowLeft = 120 } 22 {
    param($h, $p)
    $work2 = Split-Path -Parent $p.Path
    $q = Start-Process -FilePath $p.Path -ArgumentList @('-mock', '-silentImport', (Join-Path $work2 'npilab-sample.nip')) -WorkingDirectory $work2 -PassThru
    Start-Sleep -Seconds 6
    $m = Invoke-ByHelp $h 'View Modified Profiles'
    "silent-forward ; modified=$m"
  }
}
Save-Json $all (Join-Path $out 'cases.json')
Write-Host "done: $($all.Count) cases"
