# Forecast Studio

macOS app for local time-series forecasting. SwiftUI client in `app/`, Python engine in `engine/`. Minimum system is macOS 14. Apple Silicon.

## UI

The app is for someone who is not a forecasting specialist. It should look like a finished Mac app, not a technical console and not a custom-skinned website.

Read `.claude/skills/macos-ui/SKILL.md` before changing SwiftUI.

Shared pieces live in `app/Sources/COGLF1/Views/Theme.swift`: spacing, the five text sizes, `Theme.shape`, `Theme.fill`, `Theme.border`, `.card()`, `EmptyState`, `ChoiceCard`, `HintButton`. Use those. Do not invent a second visual style.

## Tests

`scripts/check.sh` runs the app's tests (`app/Tests`, `swift test`) and the engine's (`engine/tests`, pytest in `.venv`). The pre-push hook in `.githooks` runs it. When you fix a bug, add a test that fails without the fix.

## Release

`__version__` in `engine/coglf1_engine/__init__.py` must match the git tag. Pushing `v1.0.1` builds and notarizes `dist/Forecast-Studio-1.0.1.dmg` via `.github/workflows/release.yml`. Official releases are `v1.0.1`; development versions carry a suffix, `v1.1.0-dev.1`, and are published as pre-releases that only people who asked for development versions are offered. Installed apps find that release themselves (`Core/Updater.swift`) and need the `.dmg` and its `.dmg.sha256` among the release assets.
