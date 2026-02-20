# Release Checklist

## Pre-flight

- Confirm `main` is up to date and builds locally.
- Run readiness dashboard:
  - `powershell -ExecutionPolicy Bypass -File scripts/release_dashboard.ps1`
- Verify `flutter analyze` passes.
- Verify Windows release build succeeds.
- Review `README.md` install instructions for accuracy.

## Versioning

- Choose next version (for example `v0.0.3`).
- Update installer output version in build command/inputs.
- Create git tag matching release version (`0.0.3` style tag if that is the project convention).

## Build

- Run installer build script:
  - `powershell -ExecutionPolicy Bypass -File scripts/build_installer.ps1`
- Verify installer output exists under `dist/installer/`.
- Smoke-test installer on a clean Windows machine/VM.
- Verify VC++ redistributable install flow works.

## Smoke Tests

- Launch two app instances on same LAN.
- Verify peer discovery both directions.
- Verify drop-in sync both directions.
- Verify drag-out transfer works (including VS Code drop target sanity check).
- Verify manual `Download...` flow and overwrite behavior.
- Verify nudge both directions.
- Verify minimize-to-tray + restore + tray menu exit.

## Publish

- Push `main`.
- Create GitHub release:
  - Tag: release tag for version
  - Title: `vX.Y.Z`
  - Notes: delta since last release (not full feature list)
- Upload installer artifact to release.
- Confirm “latest release” link in `README.md` is still valid.

## Rollback

- If severe regression after publish:
  - Mark release as pre-release or draft a patched release.
  - Revert offending commit(s) on `main`.
  - Rebuild installer and publish hotfix version.
