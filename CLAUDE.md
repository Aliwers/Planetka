# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Planetka — push-to-talk dictation for macOS (Apple Silicon, macOS 14+), a fork of
[Parakey](https://github.com/rcourtman/parakey). Transcription is local: FluidAudio drives Parakeet TDT v3
on the Neural Engine. The only network paths are the GitHub update check and the opt-in AI cleanup.

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

# Install into /Applications and restart the agent — the ONLY supported local install
./scripts/install-local.sh
```

Suite names (`--self-test <name>`): `hotkey`, `readiness`, `paste`, `history`, `statistics`, `corrections`,
`fillers`, `ai-cleanup`, `audio-level`, `audio-conversion`, `audio-input`, `model-status`, `audio-route`,
`recording-lifecycle`, `power-state`, `model-integrity`, `update`, `hostile-env`, `logging`, `diagnostics`,
`insertion-target`, `legacy-rename`, `speech-language`, `all`. Two live suites (`audio-input-live`, `insertion-target-live`) touch real hardware
and are excluded from `all`.

CI (`.github/workflows/build.yml`) runs exactly `check.sh` → `--self-test all` → `build-app.sh` → installer +
uninstaller round-trip on a clean runner.

## Layout

Essentially the whole app is **one file**: [swift/Sources/Planetka/main.swift](swift/Sources/Planetka/main.swift)
(~25k lines) plus [Localization.swift](swift/Sources/Planetka/Localization.swift). This is deliberate; do not
split it up on your own initiative. Navigate by `// MARK: -` headers:

Constants · Text correction transfer · Correction sync path safety · Model registry hardening · Speech model
integrity · Audio input devices · Logger · Settings · Permissions · Hotkey listener · Audio capture ·
Transcription worker · Transcript corrections · Speech language · Filler word removal · AI transcript cleanup · Recording
lifecycle decisions · Text insertion · System audio mute · Sounds · Bundle version helpers · Diagnostics ·
Update check · Palette · App · Legacy rename migration · Entry point

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

Other things worth knowing before editing:

- **UI is hand-rolled AppKit**, no SwiftUI, no nibs. Every user-facing string goes through
  `localizedText("ru", "en", language:)` — both languages are required, RU/EN switches live.
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
- `install.sh` `RELEASE_SHA256` == `update.json` `sha256`.
- README install commands must pin `.../Planetka/v<version>/...`, never `/main/`.
- Both microphone entitlement keys stay in `entitlements.plist` (Tahoe uses `device.audio-input`,
  macOS 14–25 falls back to `device.microphone`).

Release assets are immutable: publish a new version rather than replacing a ZIP, then update the pinned
SHA-256. `install.sh` also pins `SOURCE_COMMIT` and refuses to run a downloaded `build-app.sh` whose commit
does not match.

## Conventions

- Tests are cases in the `PlanetkaSelfTest` enum, not XCTest/Swift Testing. Adding behavior means adding a
  `case "<name>":` to `run(arguments:)` **and** a call in `testAll()` — a suite missing from `testAll` is
  silently never run in CI.
- Multi-step features get a plan/spec pair in [docs/superpowers/](docs/superpowers/) before implementation.
- Commit messages here are short imperative sentences ("Harden optional AI cleanup integration"), not
  Conventional Commits.
