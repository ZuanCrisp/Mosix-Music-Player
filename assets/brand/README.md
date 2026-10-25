# Mornye branding

Use the artwork supplied in `mornye-brand-kit.zip` for all new Mornye
branding, including the app, Reddit community, and Telegram community and
updates channel. The original vector and raster logo variants are in `logo/`.

- Deep Teal: `#1E4E4F`.
- Mist: `#BBEBEC`.
- Ink: `#121616`.
- Paper: `#FFFFFF`.

Preserve the supplied proportions, colors, and outlined wordmark. Do not
stretch, rotate, outline, recolor, or add shadows or gradients to the logo.
Use the supplied platform containers for launcher icons.

`icon.png` uses the supplied iOS icon. `icon_android.png` uses the Android
store icon. The Android foreground and monochrome files already contain
adaptive-icon safe-zone padding, so the launcher generator adds no inset.
Regenerate launcher resources with the pinned Flutter SDK:

```sh
.fvm/flutter_sdk/bin/dart run flutter_launcher_icons
```

The transparent in-app mark is white so existing themed image tinting keeps
working. This branding change does not change application theme colors.
