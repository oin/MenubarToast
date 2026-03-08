# MenubarToast

A lightweight macOS utility that displays toast notifications in the menu bar.

Non-blocking CLI — the command returns immediately while the toast is displayed by a background process. Subsequent calls update the existing toast with a smooth text cross-fade.

# Usage

```bash
./MenubarToast "Hello, world!"
./MenubarToast -d 5 "Visible for 5 seconds"
```

# Markup

MenubarToast supports inline markup for rich text:

```bash
# Bold
./MenubarToast "**Build succeeded** — 0 warnings"

# Colors (named or hex)
./MenubarToast "{color:green}All tests passed{/color}"
./MenubarToast "{color:#FF6B9D}Custom color{/color}"

# SF Symbols icons
./MenubarToast "{icon:checkmark.circle.fill} Done"

# Combined
./MenubarToast "{color:green}{icon:checkmark.circle.fill}{/color} {color:green}**All 128 tests passed**{/color}"
```

Long text automatically scrolls horizontally.

# Build

```bash
make
```

Requires macOS and Xcode command-line tools.

# Known Issues

- The toast background uses `NSVisualEffectMaterialMenu` which doesn't perfectly match the menu bar's native translucency. A left-edge fade gradient helps blend the transition, but a slight color difference may be visible on some wallpapers.

# Acknowledgements

Built with [Claude Code](https://claude.ai/claude-code).
