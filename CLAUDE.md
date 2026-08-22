# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Planetka — push-to-talk dictation for macOS (Apple Silicon, macOS 14+), a fork of
[Parakey](https://github.com/rcourtman/parakey), published as `Aliwers/Planetka`. Transcription is local:
FluidAudio drives Parakeet TDT v3 on the Neural Engine. The only network paths are the GitHub update check
and the opt-in AI cleanup.

Read [AGENTS.md](AGENTS.md) first — it holds the non-negotiable installation invariants.

## Commands

```bash
# Full pre-commit gate (version/checksum/plist/script consistency). Run before every commit.
./scripts/check.sh

# Whole test suite (self-tests are #if DEBUG — `-c debug` is mandatory)
swift run -c debug --package-path swift Planetka --self-test all

# One suite (fast iteration)
swift run -c debug --package-path swift Planetka --self-test ai-cleanup

# Build a signed .app (ad-hoc by default; SIGN_IDENTITY="Apple Development: ..." to override)
./scripts/build-app.sh ./dist/Planetka.app
codesign --verify --deep --strict ./dist/Planetka.app

# Install into /Applications and restart the agent — the ONLY supported local install.
# The identity is mandatory: install-local.sh refuses ad-hoc, which would reset macOS permissions.
PLANETKA_SIGN_IDENTITY="Planetka Local Signing" ./scripts/install-local.sh

# Render every HUD phase to PNG frames — inspect the capsule without dictating
swift run -c debug --package-path swift Planetka --export-hud-animation /tmp/hud
```

Suite names (`--self-test <name>`): `hotkey`, `readiness`, `paste`, `history`, `statistics`, `corrections`,
`fillers`, `ai-cleanup`, `audio-level`, `audio-conversion`, `audio-input`, `model-status`, `audio-route`,
`recording-lifecycle`, `power-state`, `model-integrity`, `update`, `hostile-env`, `logging`, `diagnostics`,
`insertion-target`, `legacy-rename`, `speech-language`, `all`. Two live suites (`audio-input-live`, `insertion-target-live`) touch real hardware
and are excluded from `all`.

CI (`.github/workflows/build.yml`) runs exactly `check.sh` → `--self-test all` → `build-app.sh` → installer +
uninstaller round-trip on a clean runner. `.github/workflows/release-smoke.yml` then installs the published
release end to end.

## Layout

Essentially the whole app is **one file**: [swift/Sources/Planetka/main.swift](swift/Sources/Planetka/main.swift)
(~25k lines) plus [Localization.swift](swift/Sources/Planetka/Localization.swift). This is deliberate; do not
split it up on your own initiative. Navigate by `// MARK: -` headers:

Constants · Text correction transfer · Correction sync path safety · Model registry hardening · Speech model
integrity · Audio input devices · Logger · Settings · Permissions · Hotkey listener · Audio capture ·
Transcription worker · Transcript corrections · Speech language · Filler word removal · AI transcript cleanup ·
Recording lifecycle decisions · Text insertion · System audio mute · System audio mute lifecycle · Sounds ·
Bundle version helpers · Diagnostics · Update check · Palette · App · Legacy rename migration · Entry point

`grep -n '^// MARK:' main.swift` is the table of contents; the self-test harness is everything after
`// MARK: - Entry point`.

## Architecture

**One binary, three roles**, dispatched by argv at the bottom of `main.swift`:

| Invocation | Role |
|---|---|
| no arguments | `PlanetkaControlPanelApp` — the control panel window (status, permissions, updates, settings) |
| `--agent` | `PlanetkaApp` — the menu-bar background service that actually dictates; run by LaunchAgent `com.local.planetka.agent` |
| `--update-progress` | throwaway progress window spawned by the self-updater |
| `--self-test`, `--diagnose-audio-capture`, `--export-hud-animation` | diagnostics, no UI |

Panel and agent are **separate processes** and communicate only through the filesystem:
`AgentRuntimeStateStore` (JSON at `~/Library/Application Support/Planetka/AgentStatus.json`),
the shared `UserDefaults` suite `com.local.planetka` (`Settings`), and a PID file
(`PlanetkaControlPanelRegistry`, claimed with `O_EXCL|O_NOFOLLOW`). Settings edits are drafted in the
panel and applied by restarting the agent — so a new setting must be readable from the agent side too.

**Dictation pipeline** (`PlanetkaApp`): `HotkeyListener` (CGEventTap) → `AudioCapture` (AVAudioEngine, 16 kHz)
→ `TranscriptionWorker` (actor wrapping FluidAudio) → `processedDictationText()` → optional
`AICleanupService.clean` → history + `TextInserter` (pasteboard + Cmd+V, falls back to synthetic Unicode
events, restores the previous clipboard).

`processedDictationText()` is the single postprocessing funnel — model repair → user corrections → filler
removal → final-period rule — and it has **three call sites**: the normal completion path, the crash-recovery
path (`PendingDictationRecovery`), and the interrupted-recording path. New postprocessing goes inside that
function, not at a call site. Note that AI cleanup wraps only the normal path; any cleanup failure falls back
to the local transcript, and a dictation is never lost.

**The recording HUD** (`RecordingHUDView`) is a dark capsule with a five-bar equaliser driven by the live
audio level. Its colour comes from spoken language: while recording, `scheduleSpeechLanguageProbe()`
re-transcribes the trailing ~1.9 s every ~0.9 s and runs `detectSpeechLanguage` (Cyrillic vs Latin share,
`SPEECH_LANGUAGE_DOMINANT_SHARE`), so switching language mid-dictation repaints the capsule red↔blue.
The probe shares the ANE with the real transcription, so the release path cancels it and awaits it before
transcribing. `recordingHUDAccent(mode:languageAccent:…)` is the single rule for which colour wins — the
language colour deliberately holds through `.transcribing` so the capsule never flashes at the end. Change
the rule there, not in `draw`, and it is unit-tested in the `speech-language` suite.

Other things worth knowing before editing:

- **UI is hand-rolled AppKit**, no SwiftUI, no nibs. Every user-facing string goes through
  `localizedText("ru", "en", language:)` — both languages are required, RU/EN switches live.
- **All colour comes from `Palette`** (`canvas`/`surface`/`sunk`/`ink*`/`accent`, each with its own dark
  variant); AppKit's semantic colours are deliberately not used, they render a grey Mac panel. Build UI from
  the existing helpers — `PaletteBlock`, `PaletteButton`, `PaletteSwitch`, `paletteSegmented`, `section(_:)`,
  `settingsGroup(_:_:)`, `hairline()`, `displayFont(size:weight:)` for the serif titles — rather than new
  one-off views.
- **Resources are not in the SwiftPM target** on purpose (see the comment in [swift/Package.swift](swift/Package.swift));
  `build-app.sh` copies the menubar PNGs and icon into `Contents/Resources/`.
- **The AI cleanup API key lives in the Keychain** (`AIKeyStore`), never in `UserDefaults`. Cleanup is
  off by default, BYOK, OpenAI-compatible, Groq by default.
- **Hardening is load-bearing** and covered by self-tests: `ModelIntegrity` (pinned model digests),
  `refuseHostileRegistryEnvironmentAndExit()` (tampered download host), update archive verification
  (SHA-256 + bundle ID + version + signature, with rollback), correction-sync path limits.

## Release invariants

`check.sh` enforces these; a mismatch fails CI:

- `swift/Info.plist` `CFBundleShortVersionString` == `install.sh` `RELEASE_VERSION` == `update.json` `version`.
  Exactly three components — `normalizedReleaseVersion` rejects `1.2`, which would break the update check.
- `install.sh` `RELEASE_SHA256` == `update.json` `sha256`.
- README install commands must pin `.../Aliwers/Planetka/v<version>/...`, never `/main/`.
- `release-smoke.yml` must read the expected version from the manifest, never hardcode one.
- Both microphone entitlement keys stay in `entitlements.plist` (Tahoe uses `device.audio-input`,
  macOS 14–25 falls back to `device.microphone`).

Release assets are immutable: publish a new version rather than replacing a ZIP, then update the pinned
SHA-256. `install.sh` also pins `SOURCE_COMMIT` and refuses to run a downloaded `build-app.sh` whose commit
does not match.

## Conventions

- Tests are cases in the `PlanetkaSelfTest` enum, not XCTest/Swift Testing. Adding behavior means adding a
  `case "<name>":` to `run(arguments:)` **and** a call in `testAll()` — a suite missing from `testAll` is
  silently never run in CI.
- The version number measures how much has changed, not release ceremony: bump the patch (all four places
  above) as part of every user-requested change, without being asked.
- Multi-step features get a plan/spec pair in [docs/superpowers/](docs/superpowers/) before implementation.
- Commit messages here are short imperative sentences ("Harden optional AI cleanup integration"), not
  Conventional Commits.
