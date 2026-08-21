# Planetka Development Invariants

## One Installed Application

- The only runnable installed bundle is `/Applications/Planetka.app`.
- Always use bundle identifier `com.local.planetka`.
- Local installation must atomically replace that bundle and restart only
  `com.local.planetka.agent`.
- Never launch a copied, test, smoke, or temporary `.app` bundle. Exercise
  diagnostics through the command-line self-tests instead.
- Never change the signing identity during an installation. Local builds on
  this Mac are signed with the self-signed `Planetka Local Signing`
  certificate in the login keychain, which keeps the designated requirement
  (`identifier "com.local.planetka" and certificate root = H"74deb796…"`)
  identical across rebuilds and preserves granted permissions. An Apple
  Development certificate would serve equally well; ad-hoc would not, because
  its requirement is pinned to the hash of one binary.
- Release archives on GitHub are built ad-hoc, so installing one over a
  locally signed bundle resets macOS permissions. Update this Mac with
  `PLANETKA_SIGN_IDENTITY="Planetka Local Signing" scripts/install-local.sh`,
  not with the in-app updater or `install.sh`.
- Never call `tccutil reset` automatically. Permission removal is an explicit
  user action.
- Never open more than one macOS privacy pane for a permission request.

## Local Installation

Run `scripts/install-local.sh`. It builds into a temporary directory, signs
with the stable local identity when available, replaces the single installed
bundle, and restarts the background agent without opening another app window.
