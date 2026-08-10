# ReadBoard Icon Family

All final icons are 1024 x 1024 PNG files with transparent corners. They preserve the original ReadBoard document/control-strip geometry and differ only in finish and palette.

## Files

- `readboard-standard-1024.png` — light standard ReadBoard master; warm paper, charcoal, muted ink blue.
- `readboard-standard-dark-1024.png` — dark standard ReadBoard; deep neutral charcoal, graphite, clear ReadBoard blue.
- `readboard-pro-light-1024.png` — light Pro; warm ivory ceramic, champagne gold, obsidian charcoal.
- `readboard-pro-dark-1024.png` — dark Pro; warm graphite/obsidian, smoked glass, champagne gold.
- `readboard-go-light-1024.png` — light Go; mist white, frosted sky blue, cyan teal, cool graphite.
- `readboard-go-dark-1024.png` — dark Go; deep navy, frosted blue layers, soft cyan teal, cool gray.

## Generation specification

The 256 x 256 `docs/icon.png` file was used as the strict geometry reference. The standard light master was reconstructed at high resolution with exact internal composition and restrained Apple-platform icon depth; its dark counterpart retains the standard blue identity on neutral graphite. Pro variants add quiet-luxury ceramic, smoked-glass, and satin-metal finishes without extra symbols or ornament. Go variants use lighter visual mass, cool frosted layers, and cyan/teal accents without neon, arrows, or speed motifs.

The built-in image generation edit workflow was used. A flat magenta chroma background was removed locally, and all final deliverables were normalized to 1024 x 1024 with alpha transparency.

## Build integration

Run `Scripts/generate_app_icons.sh` after changing either standard master. The packaging flow installs both `AppIconLight.icns` and `AppIconDark.icns`, then selects the current macOS appearance as `AppIcon.icns`. Set `READBOARD_ICON_APPEARANCE=light` or `dark` to override that choice.
