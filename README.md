# YTControl
MFi controller support for YouTube (iOS), same idea as FControl.

| Control | Action |
|---|---|
| Left stick | move pointer |
| A | click at pointer (tap video in feed, buttons, captions, ...) |
| B | back / minimize / exit fullscreen |
| X | play / pause |
| Y | fullscreen |
| D-pad ◀ ▶ | seek -10s / +10s (hold = repeat) |
| D-pad ▲ ▼ | volume up / down |
| LB / RB | previous / next video |
| LT / RT | seek -30s / +30s |
| Right stick ↕ | scroll feed |
| Right stick ↔ | scrub |
| Menu | show / hide pointer |

Target: iOS 8 jailbreak (rootful, MobileSubstrate), armv7 + arm64.

Build with Theos: `make package`

## Build without Theos (GitHub Actions)
1. Create a GitHub repo and upload all files of this folder (including `.github`).
2. Open the **Actions** tab -> "Build YTControl" -> **Run workflow**.
3. When done, download the `.deb` from **Artifacts**:
   `YTControl-ios8`.
