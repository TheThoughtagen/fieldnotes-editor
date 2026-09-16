# App icon

`AppIcon.png` is the 1024 × 1024 RGBA master. The artwork was generated with the built-in image generation tool: a cream field notebook on a forest-green rounded tile, a brass bookmark, and an embossed F. Transparent space around the tile preserves its silhouette in the macOS Dock.

On macOS, rebuild the committed `AppIcon.icns` with:

```sh
scripts/build-app-icon.sh
```

An optional first argument selects a different 1024 × 1024 PNG master. The script validates PNG format and dimensions, uses `sips` for every standard 16, 32, 128, 256, and 512-point size at 1× and 2×, and combines them with `iconutil`. The app bundle includes the resulting icon as `Contents/Resources/AppIcon.icns`.
