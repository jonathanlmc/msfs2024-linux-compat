# MSFS 2024 addon compatibility shims for Linux (Proton)

Fixes and investigation notes for third-party MSFS 2024 addons and apps
under Proton on Linux (Steam Flatpak or regular; tested with Proton-Cachyos).

_Disclaimer:_ Everything here was found and fixed by a LLM (Qwen 3.8 Flash Next) with guidance & review by myself. Take everything (especially any suggested upstream fixes) with a grain of salt. Assume any fixes you apply will delete that one folder you've been meaning to back up.

## Contents

- `gsx/` - FSDT GSX Pro: complete, tested fix. Start with `gsx/README.md`.

## Status

| Addon | Status |
|---|---|
| GSX Pro | WORKING - tested one-script fix |
| ChasePlane | investigation ongoing - bridge + SimConnect healthy; in-game panel blocked by a missing http.sys WebSocket layer |

## License

CC BY-NC-SA 4.0 (see `LICENSE`). Free to use, modify and share, but not to
sell or bundle into paid products. Picked deliberately: most of the
flightsim community is great, but there's some weird ones who will happily
take existing work, bundle it into a package and try to sell it. This license
makes that copyright infringement rather than just rude.
