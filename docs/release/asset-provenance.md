# Candidate asset provenance

The Plenty Strong app icon is original geometric artwork created for this repository: an ivory dumbbell and light green leaf on a dark green square. No font, SF Symbol, Kado artwork, downloaded image or third-party library is used. The source and output are covered by the repository MIT license. The square is deliberately opaque; iOS applies its own corner treatment.

`scripts/generate-app-icon.swift` draws original NSBezierPath/NSRect shapes with native AppKit and encodes opaque sRGB PNG through CoreGraphics/ImageIO. It is contributor tooling, excluded from all app/test/harness runtime targets. Generate from the repository root with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift scripts/generate-app-icon.swift
```

`PlentyStrong/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` is the 1024 × 1024 RGB source with no alpha; the app alone compiles the catalog with `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`. The original source paths and output were visually inspected for a centered, legible mark before committing the candidate. Build/archive inspection must confirm its compiled resource and Info.plist icon entry; source membership alone is insufficient.

Candidate screenshots are captured by native UI tests using only DEBUG synthetic fixtures and native test gestures. They are raw app captures, without marketing overlays or personal setups. Their exact fixed source, simulator, test/attachment origin and SHA-256 inventory are recorded separately in `screenshots/README.md` after execution. The unsigned generic-device Release archive and the DEBUG screenshot executable are different artifacts from that same source. Neither proves real service access or App Store readiness.
