#!/usr/bin/env bash
# Round 4 (Linux runner): hashes of every official NPI release asset, lookalike-site downloads (hashed, never executed),
# ClamAV verdicts. Results: results/$RUN/ubuntu-24.04/round4/
set -u
RUN=${1:-run-manual}; OUT="results/$RUN/ubuntu-24.04/round4"; mkdir -p "$OUT" dl/official dl/lookalike
TAGS="2.1.3.11 2.1.3.12 2.1.3.16 2.1.3.19 2.2.0.0 2.2.0.2 2.2.0.29 2.3.0.0 2.3.0.1 2.3.0.10 2.3.0.11 2.3.0.12 2.3.0.13 2.3.0.2 2.3.0.3 2.3.0.4 2.3.0.5 2.3.0.6 2.3.0.8 2.3.0.9 2.4.0.1 2.4.0.10 2.4.0.11 2.4.0.12 2.4.0.13 2.4.0.14 2.4.0.15 2.4.0.16 2.4.0.17 2.4.0.18 2.4.0.19 2.4.0.2 2.4.0.20 2.4.0.21 2.4.0.22 2.4.0.23 2.4.0.24 2.4.0.25 2.4.0.26 2.4.0.27 2.4.0.29 2.4.0.3 2.4.0.30 2.4.0.31 2.4.0.32 2.4.0.33 2.4.0.34 2.4.0.4 2.4.0.5 2.4.0.8 2.4.0.9 RELEASE_2.1.2.0 Release v2.1.3.11 v2.4.0.35 v3.0.1.10 v3.0.1.11 v3.0.1.12 v3.0.1.13 v3.0.1.14 v3.0.1.15 v3.0.1.16 v3.0.1.3 v3.0.1.4 v3.0.1.5 v3.0.1.6 v3.0.1.7 v3.0.1.8 v3.0.1.9 v3.0.2.1 v3.0.2.2 v3.0.2.3 "
echo "tag,http,bytes,sha256" > "$OUT/official-hashes.csv"
for t in $TAGS; do
  f="dl/official/$t.zip"
  code=$(curl -sSL -o "$f" -w '%{http_code}' "https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/$t/nvidiaProfileInspector.zip")
  if [ "$code" = "200" ]; then echo "$t,$code,$(stat -c %s "$f"),$(sha256sum "$f" | cut -d' ' -f1)" >> "$OUT/official-hashes.csv"
    mkdir -p "dl/official/$t" && unzip -oq "$f" -d "dl/official/$t" 2>/dev/null
  else echo "$t,$code,," >> "$OUT/official-hashes.csv"; rm -f "$f"; fi
done
# inner exe hashes
echo "tag,file,bytes,sha256" > "$OUT/official-inner-hashes.csv"
for d in dl/official/*/; do t=$(basename "$d"); find "$d" -type f | while read -r x; do echo "$t,${x#$d},$(stat -c %s "$x"),$(sha256sum "$x" | cut -d' ' -f1)" >> "$OUT/official-inner-hashes.csv"; done; done
# lookalikes: fetch pages, collect candidate download links, download (max 60 MB), hash. NEVER executed.
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130 Safari/537.36"
PAGES="https://nvidiaprofileinspector.com/ https://nvidiaprofileinspector.com/download/ https://nvidiaprofileinspector.net/ https://nvidiaprofileinspector.net/download https://profileinspector.org/ https://profileinspector.org/download/ https://nvidiainspector.com/ https://nvidiainspector.com/nvidia-profile-inspector-download/ https://www.filehorse.com/download-nvidia-profile-inspector/ https://nvidiaprofileinspector.en.lo4d.com/ https://fpsunlocker.co/"
echo "page,http,final_url" > "$OUT/lookalike-pages.csv"; : > links.txt
for p in $PAGES; do
  r=$(curl -sSL -A "$UA" -m 40 -o page.html -w '%{http_code},%{url_effective}' "$p"); echo "$p,$r" >> "$OUT/lookalike-pages.csv"
  grep -oiE 'href="[^"]+"' page.html | sed -E 's/^href="//I; s/"$//' | grep -iE '\.(zip|exe|7z|rar)(\?|$)|r2\.dev|wp-content/uploads|/download' | grep -viE 'github\.com/Orbmu2k' | sed "s#^/#$(echo $p | grep -oE '^https?://[^/]+')/#" >> links.txt
  grep -oiE 'https?://[^" ]+\.(zip|exe|7z)' page.html >> links.txt
done
sort -u links.txt | grep -E '^https?://' | head -60 > "$OUT/lookalike-links.txt"
echo "link,http,final_url,content_type,bytes,sha256,matches_official" > "$OUT/lookalike-downloads.csv"
i=0; while read -r L; do i=$((i+1)); f="dl/lookalike/f$i"
  r=$(curl -sSL -A "$UA" -m 90 --max-filesize 62914560 -o "$f" -w '%{http_code},%{url_effective},%{content_type}' "$L")
  if [ -s "$f" ] && ! file "$f" | grep -qi 'html'; then h=$(sha256sum "$f" | cut -d' ' -f1); m=$(grep -m1 ",$h$" "$OUT/official-hashes.csv" | cut -d, -f1)
    echo "\"$L\",$r,$(stat -c %s "$f"),$h,${m:-none}" >> "$OUT/lookalike-downloads.csv"
    if file "$f" | grep -qi zip; then mkdir -p "$f.x"; unzip -oq "$f" -d "$f.x" 2>/dev/null; find "$f.x" -type f -exec sha256sum {} \; | sed "s#dl/lookalike/##" >> "$OUT/lookalike-inner-hashes.txt"; fi
  else rm -f "$f"; fi
done < "$OUT/lookalike-links.txt"
# ClamAV
sudo apt-get install -y -qq clamav >/dev/null 2>&1; sudo systemctl stop clamav-freshclam 2>/dev/null; sudo freshclam --quiet || sudo freshclam
{ clamscan --version; clamscan -r --infected=no dl/official dl/lookalike 2>&1 | tail -15; } > "$OUT/clamav.txt" 2>&1
clamscan -r -i dl/ > "$OUT/clamav-infected.txt" 2>&1 || true
ls -la "$OUT"
