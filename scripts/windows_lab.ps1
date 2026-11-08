# nvprofileinspector.com test lab: Windows matrix for NVIDIA Profile Inspector (NPI).
# Runs on GitHub-hosted Windows runners (no NVIDIA GPU, no NVIDIA driver).
# What it can prove: release files, hashes, signatures, manifest, Defender verdict, behaviour
# without an NVIDIA driver, the built-in -mock mode UI (themes, views, dialogs), CLI switches,
# .nip import/export in mock mode. What it cannot prove: anything that needs a real driver.
param([string]$Run = 'run-manual', [string]$Machine = 'windows')
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  public static List<IntPtr> ForPid(uint pid) {
    var list = new List<IntPtr>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) list.Add(h); return true; }, IntPtr.Zero);
    return list;
  }
  public static string Title(IntPtr h) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); return sb.ToString(); }
  public static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll")] public static extern int EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll")] public static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
  public static string SetRes(int w, int h) {
    var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (EnumDisplaySettings(null, -1, ref dm) == 0) return "enum-failed";
    dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmFields = 0x80000 | 0x100000;
    return ChangeDisplaySettings(ref dm, 1).ToString();
  }
}
"@

$root = (Get-Location).Path
$out = Join-Path $root "results\$Run\$Machine"
$dl = Join-Path $root 'dl'
New-Item -ItemType Directory -Force -Path $out, $dl | Out-Null

function Save-Json($obj, $path) { $obj | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8 }

function Shot($path, $hwnd) {
  try {
    if ($hwnd -and $hwnd -ne [IntPtr]::Zero) {
      $r = New-Object W+RECT; [W]::GetWindowRect($hwnd, [ref]$r) | Out-Null
      $w = $r.R - $r.L; $h = $r.B - $r.T
      if ($w -gt 50 -and $h -gt 50) {
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose(); return "$w x $h"
      }
    }
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose(); return "screen $($b.Width) x $($b.Height)"
  } catch { return "shot-failed: $($_.Exception.Message)" }
}

function Texts($hwnd) {
  # All visible text of a window via UI Automation (dialog messages, button labels).
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    $all = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $t = @(); foreach ($e in $all) { $n = $e.Current.Name; if ($n -and $n.Trim().Length -gt 0 -and $t -notcontains $n) { $t += $n } }
    return $t
  } catch { return @("uia-failed: $($_.Exception.Message)") }
}

function Invoke-ByHelp($hwnd, $help) {
  # Click a WPF button whose tooltip (UIA HelpText) or name matches.
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    $all = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) {
      if ($e.Current.HelpText -eq $help -or $e.Current.Name -eq $help) {
        $p = $null
        if ($e.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return "invoked" }
        if ($e.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { $p.Toggle(); return "toggled" }
        if ($e.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) { $p.Expand(); return "expanded" }
        return "found-no-pattern"
      }
    }
    return "not-found"
  } catch { return "error: $($_.Exception.Message)" }
}

function Set-Search($hwnd, $text) {
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    $edits = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    foreach ($e in $edits) {
      if ($e.Current.HelpText -like 'Search settings*') {
        $p = $null
        if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) { $p.SetValue($text); return "set" }
      }
    }
    $names = @(); foreach ($e in $edits) { $names += "$($e.Current.Name)|$($e.Current.HelpText)|$($e.Current.AutomationId)" }
    return "no-search-edit: " + ($names -join ' ; ')
  } catch { return "error: $($_.Exception.Message)" }
}


function Select-Row($hwnd, $name) {
  # Select the settings-list row whose text is $name (walks up to the selectable list item).
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)
    $hit = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $hit) { return "row-not-found" }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $cur = $hit
    for ($i = 0; $i -lt 6 -and $cur; $i++) {
      $p = $null
      if ($cur.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select(); return "selected:$($cur.Current.ControlType.ProgrammaticName)" }
      $cur = $walker.GetParent($cur)
    }
    return "no-selectable-parent"
  } catch { return "error: $($_.Exception.Message)" }
}

function Write-Settings($dir, $extra) {
  # Portable settings.xml (NPI reads settings.xml from the working directory first).
  $base = [ordered]@{ WindowTop = 0; WindowLeft = 0; WindowWidth = 1360; WindowHeight = 860; WindowState = 'Normal';
    DisableUpdateCheck = 'true'; DisableSplashScreen = 'false'; Theme = 'DarkTheme.xaml'; DisplayDensity = 'Modern' }
  foreach ($k in $extra.Keys) { $base[$k] = $extra[$k] }
  $xml = '<?xml version="1.0" encoding="utf-16"?>' + "`r`n" + '<UserSettings xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">' + "`r`n"
  foreach ($k in $base.Keys) { $xml += "  <$k>$($base[$k])</$k>`r`n" }
  $xml += '</UserSettings>'
  [System.IO.File]::WriteAllText((Join-Path $dir 'settings.xml'), $xml, [System.Text.Encoding]::Unicode)
}

function Run-Case($ver, $exeDir, $case, $argList, $settings, $wait, $action) {
  $cdir = Join-Path $out "$ver\$case"; New-Item -ItemType Directory -Force -Path $cdir | Out-Null
  $work = Join-Path $env:RUNNER_TEMP "npi-$ver-$case"
  if (Test-Path $work) { Remove-Item -Recurse -Force $work }
  Copy-Item -Recurse $exeDir $work
  if ($settings -ne $null) { Write-Settings $work $settings }
  Get-ChildItem (Join-Path $root 'samples') | Copy-Item -Destination $work
  $crashDir = Join-Path $env:LOCALAPPDATA 'nvidiaProfileInspector\Logs'
  $crashBefore = @(); if (Test-Path $crashDir) { $crashBefore = @(Get-ChildItem $crashDir | ForEach-Object Name) }
  $exe = Join-Path $work 'nvidiaProfileInspector.exe'
  $res = [ordered]@{ case = $case; version = $ver; machine = $Machine; args = ($argList -join ' '); settings = $settings; started = (Get-Date).ToString('o') }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    if ($argList.Count -gt 0) { $p = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $work -PassThru }
    else { $p = Start-Process -FilePath $exe -WorkingDirectory $work -PassThru }
  } catch { $res.startError = $_.Exception.Message; Save-Json $res (Join-Path $cdir 'result.json'); return $res }
  $firstWindowMs = $null; $titles = @()
  while ($sw.ElapsedMilliseconds -lt ($wait * 1000)) {
    Start-Sleep -Milliseconds 250
    if ($p.HasExited) { break }
    $ws = [W]::ForPid([uint32]$p.Id)
    if ($ws.Count -gt 0 -and $firstWindowMs -eq $null) { $firstWindowMs = $sw.ElapsedMilliseconds }
    foreach ($h in $ws) { $t = [W]::Title($h); if ($t -and $titles -notcontains $t) { $titles += $t } }
    if ($case -eq 'mock-splash' -and $firstWindowMs -ne $null) { break }
  }
  $res.firstWindowMs = $firstWindowMs
  $res.windowTitlesSeen = $titles
  $res.exitedEarly = $p.HasExited
  if ($p.HasExited) { $res.exitCode = $p.ExitCode; $res.exitMs = $sw.ElapsedMilliseconds }
  $windows = @()
  if (-not $p.HasExited) {
    $ws = [W]::ForPid([uint32]$p.Id)
    $i = 0
    foreach ($h in $ws) {
      [W]::ShowWindow($h, 9) | Out-Null; [W]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 400
      $info = [ordered]@{ title = [W]::Title($h); class = [W]::Cls($h); texts = (Texts $h) }
      $info.shot = Shot (Join-Path $cdir "window-$i.png") $h
      $windows += $info; $i++
    }
    if ($action -ne $null -and $ws.Count -gt 0) {
      $main = $ws | Where-Object { [W]::Title($_) -like '*PROFILE INSPECTOR*' -or [W]::Title($_) -like '*Profile Inspector*' } | Select-Object -First 1
      if (-not $main) { $main = $ws[0] }
      [W]::SetForegroundWindow($main) | Out-Null
      $res.action = & $action $main $p
      Start-Sleep -Seconds 3
      $ws2 = [W]::ForPid([uint32]$p.Id); $j = 0
      foreach ($h in $ws2) {
        $info = [ordered]@{ title = [W]::Title($h); class = [W]::Cls($h); texts = (Texts $h) }
        $info.shot = Shot (Join-Path $cdir "after-$j.png") $h
        $res["after_$j"] = $info; $j++
      }
      Shot (Join-Path $cdir 'after-screen.png') ([IntPtr]::Zero) | Out-Null
    }
    Shot (Join-Path $cdir 'screen.png') ([IntPtr]::Zero) | Out-Null
    try { $res.workingSetMB = [math]::Round((Get-Process -Id $p.Id).WorkingSet64 / 1MB, 1) } catch {}
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
  $res.windows = $windows
  $res.elapsedMs = $sw.ElapsedMilliseconds
  # Files the app created in its folder (settings, CSN, exports)
  $created = @()
  foreach ($f in Get-ChildItem -Recurse $work -File) {
    $orig = Join-Path $exeDir ($f.FullName.Substring($work.Length + 1))
    if (-not (Test-Path $orig) -and $f.Name -ne 'npilab-sample.nip') {
      $created += [ordered]@{ name = $f.FullName.Substring($work.Length + 1); bytes = $f.Length }
      if ($f.Extension -in '.nip', '.xml', '.txt', '.log') { Copy-Item $f.FullName (Join-Path $cdir ('created-' + $f.Name)) }
    }
  }
  $res.filesCreated = $created
  if (Test-Path $crashDir) {
    $new = @(Get-ChildItem $crashDir | Where-Object { $crashBefore -notcontains $_.Name })
    $res.crashLogs = @($new | ForEach-Object Name)
    foreach ($c in $new) { Copy-Item $c.FullName (Join-Path $cdir $c.Name) }
  }
  Save-Json $res (Join-Path $cdir 'result.json')
  Write-Host "[$ver/$case] firstWindow=$firstWindowMs exited=$($res.exitedEarly) titles=$($titles -join ' | ')"
  return $res
}

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
