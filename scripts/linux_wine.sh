#!/usr/bin/env bash
# nvprofileinspector.com test lab: NVIDIA Profile Inspector under Wine on Linux (no NVIDIA GPU).
# W1 NPI without any NVAPI, W2 NPI in -mock mode (does the WPF UI render under Wine?), W3 NPI with DXVK-NVAPI installed.
set -u
RUN=${1:-run-manual}; OUT="results/$RUN/ubuntu-24.04/wine"; mkdir -p "$OUT"
export WINEPREFIX="$HOME/pfx-npi" WINEDEBUG=-all DISPLAY=:99
Xvfb :99 -screen 0 1600x1000x24 & sleep 2
{ wine --version; winetricks --version; } > "$OUT/versions.txt" 2>&1
wineboot -i >/dev/null 2>&1
start=$(date +%s); timeout 2400 winetricks -q dotnet48 > "$OUT/winetricks-dotnet48.log" 2>&1; echo "dotnet48 exit=$? seconds=$(( $(date +%s)-start ))" >> "$OUT/versions.txt"
curl -sSL -o npi.zip https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/v3.0.2.1/nvidiaProfileInspector.zip
mkdir -p npi && (cd npi && unzip -oq ../npi.zip)
run_case () { # name, extra args, env
  local name=$1; shift
  ( cd npi && timeout 60 env "$@" wine nvidiaProfileInspector.exe ${ARGS:-} > "../$OUT/$name.stdout.txt" 2> "../$OUT/$name.stderr.txt" & )
  sleep 40; import -window root "$OUT/$name.png" 2>/dev/null
  wmctrl -l > "$OUT/$name.windows.txt" 2>/dev/null || xwininfo -root -tree | grep -i '"' | head -40 > "$OUT/$name.windows.txt"
  wineserver -k; sleep 3
}
ARGS="" run_case w1-no-nvapi WINEDLLOVERRIDES=nvapi,nvapi64=d
ARGS="-mock" run_case w2-mock WINEDLLOVERRIDES=nvapi,nvapi64=d
# W3: DXVK-NVAPI (latest release) as nvapi/nvapi64, allowed on non-NVIDIA (software) adapters
tag=$(curl -sSL https://api.github.com/repos/jp7677/dxvk-nvapi/releases/latest | grep -m1 '"tag_name"' | cut -d'"' -f4)
echo "dxvk-nvapi $tag" >> "$OUT/versions.txt"
curl -sSL -o dn.tar.gz "https://github.com/jp7677/dxvk-nvapi/releases/download/$tag/dxvk-nvapi-$tag.tar.gz" && mkdir -p dn && tar -xzf dn.tar.gz -C dn
cp dn/x64/nvapi64.dll "$WINEPREFIX/drive_c/windows/system32/" 2>/dev/null; cp dn/x32/nvapi.dll "$WINEPREFIX/drive_c/windows/syswow64/" 2>/dev/null
ls -la dn/x64 dn/x32 >> "$OUT/versions.txt" 2>&1
ARGS="" run_case w3-dxvk-nvapi WINEDLLOVERRIDES=nvapi,nvapi64=n DXVK_NVAPI_ALLOW_OTHER_DRIVERS=1 DXVK_NVAPI_LOG_LEVEL=info DXVK_NVAPI_LOG_PATH=/tmp
cp /tmp/nvapi*.log "$OUT/" 2>/dev/null || true
ls -la "$OUT"
