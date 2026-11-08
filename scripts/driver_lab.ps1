# nvprofileinspector.com test lab: what can be learned from NVIDIA's public driver package on a PC without an NVIDIA GPU.
# D1 download + signature, D2 extract + inventory + search for profile data, D3 NVAPI probe via P/Invoke,
# D4 NPI with the package's nvapi64.dll beside it, D5 silent installer attempt, D6 pnputil attempt, D7 NPI after attempts.
param([string]$Run = 'run-manual', [string]$Machine = 'windows', [string]$Driver = '621.14')
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient

$root = (Get-Location).Path
$out = Join-Path $root "results\$Run\$Machine\driver-$Driver"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$work = Join-Path $env:RUNNER_TEMP 'drv'
New-Item -ItemType Directory -Force -Path $work | Out-Null
function Save-Json($o, $p) { $o | ConvertTo-Json -Depth 8 | Set-Content -Path $p -Encoding UTF8 }
$rep = [ordered]@{ driver = $Driver; machine = $Machine; run = $Run; date = (Get-Date).ToString('o') }

# D1 download
$url = "https://us.download.nvidia.com/Windows/$Driver/$Driver-desktop-win10-win11-64bit-international-dch-whql.exe"
$pkg = Join-Path $work "driver-$Driver.exe"
$sw = [Diagnostics.Stopwatch]::StartNew()
try { & curl.exe -sSL -o $pkg $url; $rep.downloadSeconds = [math]::Round($sw.Elapsed.TotalSeconds) } catch { $rep.downloadError = $_.Exception.Message }
if (Test-Path $pkg) {
  $rep.url = $url; $rep.bytes = (Get-Item $pkg).Length
  $rep.sha256 = (Get-FileHash $pkg -Algorithm SHA256).Hash.ToLower()
  $sig = Get-AuthenticodeSignature $pkg
  $rep.signature = [ordered]@{ status = "$($sig.Status)"; signer = "$($sig.SignerCertificate.Subject)" }
}

# D2 extract and inventory
$x = Join-Path $work 'x'
$7z = 'C:\Program Files\7-Zip\7z.exe'
& $7z x -y "-o$x" $pkg | Out-Null
$rep.extracted = Test-Path $x
if ($rep.extracted) {
  $rep.topLevel = @(Get-ChildItem $x | ForEach-Object {
    $size = (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    [ordered]@{ name = $_.Name; isDir = $_.PSIsContainer; bytes = $size } })
  $all = Get-ChildItem $x -Recurse -File
  $rep.fileCount = $all.Count
  $all | Select-Object @{n='path';e={$_.FullName.Substring($x.Length+1)}}, Length | Export-Csv (Join-Path $out 'package-files.csv') -NoTypeInformation
  $nv = $all | Where-Object Name -match '^nvapi(64)?\.dll$'
  $rep.nvapi = @($nv | ForEach-Object { [ordered]@{ path = $_.FullName.Substring($x.Length+1); bytes = $_.Length; version = $_.VersionInfo.FileVersion } })
  $rep.drsNamedFiles = @($all | Where-Object { $_.Name -match 'drs|nvdrs|profile' } | ForEach-Object { [ordered]@{ path = $_.FullName.Substring($x.Length+1); bytes = $_.Length } })
  $rep.infFiles = @($all | Where-Object Extension -eq '.inf' | ForEach-Object { $_.FullName.Substring($x.Length+1) })
  # Search for well-known game profile names (UTF-16 and ASCII) to locate predefined profile data.
  $needles = @('Cyberpunk 2077', 'cyberpunk2077.exe', 'Red Dead Redemption 2', 'nvdrsdb', 'Base Profile')
  $hits = @()
  foreach ($f in ($all | Where-Object { $_.Length -lt 120MB })) {
    try { $bytes = [IO.File]::ReadAllBytes($f.FullName) } catch { continue }
    $a = [Text.Encoding]::ASCII.GetString($bytes); $u = [Text.Encoding]::Unicode.GetString($bytes)
    foreach ($n in $needles) {
      if ($a.Contains($n)) { $hits += [ordered]@{ file = $f.FullName.Substring($x.Length+1); needle = $n; enc = 'ascii' } }
      if ($u.Contains($n)) { $hits += [ordered]@{ file = $f.FullName.Substring($x.Length+1); needle = $n; enc = 'utf16' } }
    }
  }
  $rep.profileStringHits = $hits
}
Save-Json $rep (Join-Path $out 'driver-report.json')

# D3 NVAPI probe from the extracted package (64-bit process)
$nvapiPath = ($rep.nvapi | Where-Object { $_.path -match 'nvapi64\.dll$' } | Select-Object -First 1).path
$probe = [ordered]@{}
if ($nvapiPath) {
  $full = Join-Path $x $nvapiPath
  Copy-Item $full (Join-Path $work 'nvapi64.dll') -Force
  Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class NvProbe {
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr LoadLibrary(string p);
  [DllImport("kernel32", SetLastError=true)] public static extern IntPtr GetProcAddress(IntPtr h, string n);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate IntPtr QI(uint id);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int F0();
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int F1(out IntPtr a);
  public static string Run(string path) {
    var h = LoadLibrary(path);
    if (h == IntPtr.Zero) return "LoadLibrary failed: " + Marshal.GetLastWin32Error();
    var p = GetProcAddress(h, "nvapi_QueryInterface");
    if (p == IntPtr.Zero) return "no nvapi_QueryInterface export";
    var qi = (QI)Marshal.GetDelegateForFunctionPointer(p, typeof(QI));
    var r = "";
    var init = qi(0x0150E828);
    if (init == IntPtr.Zero) r += "Initialize=missing; ";
    else { var f = (F0)Marshal.GetDelegateForFunctionPointer(init, typeof(F0)); r += "Initialize=" + f() + "; "; }
    var cs = qi(0x0694D52E);
    if (cs == IntPtr.Zero) r += "DRS_CreateSession=missing; ";
    else { IntPtr s; var f = (F1)Marshal.GetDelegateForFunctionPointer(cs, typeof(F1)); r += "DRS_CreateSession=" + f(out s) + "; "; }
    return r;
  }
}
"@
  try { $probe.result = [NvProbe]::Run((Join-Path $work 'nvapi64.dll')) } catch { $probe.result = "exception: $($_.Exception.Message)" }
  $probe.note = 'Status codes: 0 = NVAPI_OK, -3 = NVAPI_NO_IMPLEMENTATION / library not initialised, -6 = NVAPI_NVIDIA_DEVICE_NOT_FOUND, -1 = NVAPI_ERROR'
}
Save-Json $probe (Join-Path $out 'nvapi-probe.json')

# helper: run NPI and capture the first dialog
function Run-Npi($case, $dir) {
  $exe = Join-Path $dir 'nvidiaProfileInspector.exe'
  $p = Start-Process -FilePath $exe -WorkingDirectory $dir -PassThru
  Start-Sleep -Seconds 10
  $r = [ordered]@{ case = $case; exited = $p.HasExited }
  if (-not $p.HasExited) {
    $p.Refresh(); $h = $p.MainWindowHandle
    $r.title = $p.MainWindowTitle
    try {
      $el = [System.Windows.Automation.AutomationElement]::FromHandle($h)
      $r.texts = @($el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name } | Where-Object { $_ } | Select-Object -Unique -First 40)
    } catch {}
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save((Join-Path $out "$case.png"), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
    Stop-Process -Id $p.Id -Force
  } else { $r.exitCode = $p.ExitCode }
  return $r
}

# D4 NPI with the package's nvapi64.dll in its folder
$npiZip = Join-Path $work 'npi.zip'
& curl.exe -sSL -o $npiZip 'https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/v3.0.2.1/nvidiaProfileInspector.zip'
$npi = Join-Path $work 'npi'; Expand-Archive $npiZip $npi -Force
$npiDll = Join-Path $work 'npi-with-dll'; Copy-Item -Recurse $npi $npiDll
if ($nvapiPath) { Copy-Item (Join-Path $work 'nvapi64.dll') $npiDll }
$cases = @()
$cases += Run-Npi 'npi-with-package-nvapi64' $npiDll

# D5 silent installer attempt (expected to refuse without NVIDIA hardware)
$inst = [ordered]@{}
$setup = Join-Path $x 'setup.exe'
if (Test-Path $setup) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath $setup -ArgumentList '-s', '-noreboot', '-noeula' -PassThru -Wait
  $inst.exitCode = $p.ExitCode; $inst.seconds = [math]::Round($sw.Elapsed.TotalSeconds)
  $logs = Get-ChildItem "$env:ProgramData\NVIDIA Corporation\Installer2" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 5
  $inst.logs = @($logs | ForEach-Object { $_.FullName })
  foreach ($l in $logs) { Copy-Item $l.FullName (Join-Path $out ("installer-" + $l.Name)) -ErrorAction SilentlyContinue }
}
# D6 pnputil attempt
$inf = Get-ChildItem $x -Recurse -Filter 'nv_disp*.inf' | Select-Object -First 1
if ($inf) { $inst.pnputilInf = $inf.Name; $inst.pnputil = (& pnputil.exe /add-driver $inf.FullName /install 2>&1 | Out-String).Trim() }
$inst.afterServices = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'NV|nvidia' } | ForEach-Object { "$($_.Name)=$($_.Status)" })
$inst.afterSystemNvapi64 = Test-Path "$env:WINDIR\System32\nvapi64.dll"
$inst.afterDrsFolder = Test-Path "$env:ProgramData\NVIDIA Corporation\Drs"
if ($inst.afterDrsFolder) { $inst.drsFiles = @(Get-ChildItem "$env:ProgramData\NVIDIA Corporation\Drs" | ForEach-Object { "$($_.Name) $($_.Length)" }) }
Save-Json $inst (Join-Path $out 'install-attempts.json')

# D7 NPI after the attempts
$cases += Run-Npi 'npi-after-install-attempts' $npi
Save-Json $cases (Join-Path $out 'npi-cases.json')
Write-Host ($rep | ConvertTo-Json -Depth 4); Write-Host ($probe | ConvertTo-Json); Write-Host ($inst | ConvertTo-Json -Depth 4); Write-Host ($cases | ConvertTo-Json -Depth 4)
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
