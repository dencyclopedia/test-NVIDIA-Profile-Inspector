# test-NVIDIA-Profile-Inspector: nvprofileinspector.com test lab (temporary, public)

Temporary public repository that runs the automated hands-on tests behind nvprofileinspector.com
on throwaway GitHub-hosted Windows machines. It will be deleted when the site is finished (its
results are mirrored into the private planning repo first). Nothing here is NVIDIA Profile
Inspector itself: the tool is downloaded from the official releases at
https://github.com/Orbmu2k/nvidiaProfileInspector/releases during each run.

| Path | What |
|---|---|
| `scripts/windows_lab.ps1` | Windows matrix: downloads releases, records hashes/signature/manifest/Defender verdict, runs the app without an NVIDIA driver, runs the built-in `-mock` mode (themes, views, dialogs, search), tests CLI switches and `.nip` import/export |
| `samples/npilab-sample.nip` | A tiny hand-written profile (one app, frame-rate cap 141, power mode) used for import tests |
| `.github/workflows/lab.yml` | Runs the matrix on Windows Server 2025 and 2022 and commits `results/` |
| `results/<run>/<machine>/` | `machine.json`, `downloads.json`, `cases.json`, `manifest-*.xml`, and one folder per version/case with `result.json` and screenshots |

Limits: these machines have no NVIDIA GPU and no NVIDIA driver. They prove file facts, start-up
behaviour without a driver, the mock-mode user interface and command-line behaviour. Anything that
reads or writes real driver profiles is tested by hand on real NVIDIA PCs (see the
nvprofileinspector.com testing guide).
