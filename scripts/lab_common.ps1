# Shared helpers for the nvprofileinspector.com Windows labs (dot-sourced). Callers define $root, $out, $Machine first.
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


function Forward($p, $files, $flags) {
  # Hand .nip files to the running instance (single-instance forwarding) and wait.
  $work2 = Split-Path -Parent $p.Path
  $args2 = @('-mock') + $flags + @($files | ForEach-Object { Join-Path $work2 $_ })
  $q = Start-Process -FilePath $p.Path -ArgumentList $args2 -WorkingDirectory $work2 -PassThru
  Start-Sleep -Seconds 6
  if ($q.HasExited) { "fwd-exit:$($q.ExitCode)" } else { 'fwd-running' }
}
function Select-Profile($hwnd, $name) {
  # Type a profile name into the profile box (AutomationId ProfileCombo) and press Enter.
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'ProfileCombo')
    $combo = $el.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    if (-not $combo) { return 'no-ProfileCombo' }
    $ec = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    $edit = $combo.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $ec)
    $target = if ($edit) { $edit } else { $combo }
    $target.SetFocus(); Start-Sleep -Milliseconds 300
    [System.Windows.Forms.SendKeys]::SendWait('^a'); Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait($name); Start-Sleep -Milliseconds 800
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); Start-Sleep -Seconds 2
    return "typed-into-$(if ($edit) {'edit'} else {'combo'})"
  } catch { return "error: $($_.Exception.Message)" }
}
function Click-Dialog-Button($p, $label) {
  foreach ($h in [W]::ForPid([uint32]$p.Id)) {
    $r = Invoke-ByHelp $h $label
    if ($r -ne 'not-found') { return "$label=$r" }
  }
  return "$label=not-found"
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

