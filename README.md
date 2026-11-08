# test-NVIDIA-Profile-Inspector: nvprofileinspector.com test lab (temporary, public)

Temporary public repository that runs the automated hands-on tests behind nvprofileinspector.com
on throwaway GitHub-hosted Windows machines. It will be deleted when the site is finished (its
results are mirrored into the private planning repo first). Nothing here is NVIDIA Profile
Inspector itself: the tool is downloaded from the official releases at
https://github.com/Orbmu2k/nvidiaProfileInspector/releases during each run.

| Path | What |
|---|---|
| `scripts/windows_lab.ps1` | Windows matrix: downloads releases, records hashes/signature/manifest/Defender verdict, runs the app without an NVIDIA driver, runs the built-in `-mock` mode (themes, views, dialogs, search), tests CLI switches and `.nip` import/export; round 3 adds populated game profiles via forwarded imports, Replace vs Merge, the import prompt and the clipboard format |
| `scripts/lab_common.ps1` | Shared helpers for the Windows scripts (UI Automation, screenshots, JSON output, dialog handling) |
| `scripts/round4_windows.ps1` | Round 4 on Windows: official hashes for every release asset, Mark-of-the-Web, updater channels, Procmon trace of network and registry access, package-manager builds (winget, Chocolatey), import tolerance, NVPI Revamped |
| `scripts/round4_linux.sh` | Round 4 on Ubuntu: ClamAV scan of every official asset, lookalike download-site audit |
| `scripts/driver_lab.ps1` | Driver-package lab: downloads NVIDIA's public driver package, lists its contents, probes the bundled NVAPI without a GPU, records what the installer and `pnputil` do on a machine with no NVIDIA GPU, runs NPI against the package DLL |
| `scripts/linux_wine.sh` | Wine lab: .NET 4.8 under Wine, then NPI with and without DXVK-NVAPI |
| `samples/*.nip` | Hand-written profiles used as import inputs (`npilab-sample.nip`, four game profiles, `replace-a/b.nip` for Replace vs Merge) |
| `.github/workflows/lab.yml` | Windows UI/CLI lab on Windows Server 2025 and 2022 (runs `ci-*`) |
| `.github/workflows/round4.yml` | Round 4 on Windows and Ubuntu (runs `r4-*`) |
| `.github/workflows/driver-lab.yml` | Driver-package lab on Windows and Wine lab on Ubuntu (runs `drv-*`) |
| `results/<run>/` | Raw output of each run (JSON, CSV, logs, screenshots), committed by the workflow |

Limits: these machines have no NVIDIA GPU and no NVIDIA driver. They prove file facts, start-up
behaviour without a driver, the mock-mode user interface and command-line behaviour. Anything that
needs a real NVIDIA GPU (driver behaviour, performance) is not measured here: the site cites
published independent measurements and NVIDIA's own documentation for those (see the planning
repo's zero-hardware plan).
