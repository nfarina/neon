# Releasing

Getting a new build onto a machine bolted to a wall, and onto anyone else's.

Sparkle, an appcast on GitHub Pages, and `tools/release.sh`. The same shape as
Nick's other projects (`../RAMBLR/Scripts/`), adapted for a SwiftPM package
with a hand-assembled `.app` and no Xcode project.

## Setting it up (once, ever)

```sh
tools/release-setup.sh
```

Generates the EdDSA key pair Sparkle signs updates with. The private half goes
into the login keychain under `com.nickfarina.neon` and **must never leave it**
— losing it means no installed copy will ever accept another update, and the
only recovery is asking everyone to download a fresh app. The public half gets
pasted into `tools/sparkle-config.sh` and committed; it is meant to be public,
and it is what lets every copy of Neon verify an update came from Nick.

Then:

- `xcrun notarytool store-credentials neon-notary --apple-id … --team-id …
  --password <app-specific-password>`
- GitHub → Settings → Pages → Deploy from branch → `main` `/docs`.
  `docs/.nojekyll` is there so Pages serves the folder as files rather than
  building the implementation notes into a website; the only file anybody is
  meant to fetch is `appcast.xml`.

Until the public key is filled in, `build.sh` leaves the Sparkle keys out of
`Info.plist` entirely and the settings panel reports that this build doesn't do
updates. That is the truth, and better than a Check for Updates button that can
only fail — which is also what anyone building from a fresh clone gets, and
should.

## Cutting one

```sh
tools/release.sh 0.3 [--notes notes.md]
```

Stamps `eyes/VERSION`, builds with `--release`, notarizes, staples, tags,
creates the GitHub release with the zip attached, regenerates
`docs/appcast.xml` with a signature, and pushes. Each step is a separate
command if something goes wrong halfway; the script is a sequence, not a state
machine.

**The feed goes live a few minutes after the script finishes.** Pages has to
rebuild, and then Fastly caches the result for around ten minutes — so
fetching the appcast straight after a release can return the *previous*
version and look like the release silently failed. It hasn't; check with a
cache-buster before believing it:

```sh
curl -sS "https://nfarina.github.io/neon/appcast.xml?cb=$(date +%s)" | head -8
gh api repos/nfarina/neon/pages/builds/latest --jq .status   # "built"
```

The same delay means a client that checked in the last few minutes may not see
a new release immediately. Nothing to fix — just don't stand at the kitchen
counter pressing Check for Updates and concluding it's broken.

## What `--release` changes

`eyes/shell/build.sh` has two modes and the kitchen only ever uses the first.

|  | development | `--release` |
|---|---|---|
| identity | "Neon Dev", or Apple Development | Developer ID Application |
| hardened runtime | no | yes |
| entitlements | none | mic, camera, location, calendars |

The entitlements only appear in release builds because hardened runtime is
what makes them mandatory: with it on and them absent, macOS denies the
microphone outright instead of asking. Development builds deliberately skip all
of it — the kitchen Mac's TCC grants are keyed to how it is signed, and
changing that resets them (see `docs/machine.md`, which is the same lesson
learned three different ways).

## Versioning

`eyes/VERSION` is the marketing version. `CFBundleVersion` is the **commit
count** — `git rev-list --count HEAD`. Sparkle needs a number that only ever
increases, and the commit count does that on its own: no file to remember to
bump, and no way for two releases to claim the same build number.

## Sparkle inside a hand-built bundle

Everything else Neon links is static; Sparkle is a real framework, so:

- `Package.swift` adds `-rpath @executable_path/../Frameworks`. Without it the
  app dies at launch with a dyld error and no window ever appears.
- `build.sh` `ditto`s `Sparkle.framework` out of `.build/artifacts` into
  `Contents/Frameworks`. `ditto` rather than `cp`: a framework is a tree of
  symlinks into `Versions/`, and flattening them breaks the signature.
- Sparkle ships signed by the Sparkle project. Re-signing the app with a
  different identity leaves those nested signatures mismatched, so `Autoupdate`,
  both XPC services and `Updater.app` are re-signed too — **inside out**,
  because each enclosing bundle's signature has to cover the inner ones as they
  finally are.
- The version is pinned exactly rather than floating. A minor bump that renamed
  a nested component would break that copy-and-sign list rather than the
  compile, which is a much worse failure to discover.

`codesign --verify --deep --strict` runs at the end of every build, release or
not, so a broken embed fails at build time rather than at launch in a kitchen.

## Update behaviour

Checks are always automatic. **Installing is a setting**, off by default
(Settings → About → "Install updates on her own"), because an install means a
relaunch, and a relaunch mid-sentence is exactly wrong for something that lives
in a room.

Switched on, the hard part isn't downloading — Sparkle does that — it is
choosing the moment. Sparkle's model is "install when the app next quits", and
Neon never quits: she is an appliance that runs for months. So
`SPUUpdaterDelegate.updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`
returns true to take ownership of the timing, holds the block, and the shell's
20-second idle sweep fires it when the room is genuinely empty:

- deep asleep (ten minutes with nobody speaking to her — the load-bearing one)
- no voice session
- no timer counting down
- nobody in settings
- nothing waiting to be announced

She updates herself at 3am and is back before anyone notices. Turning the
setting off also drops any block already held, so it can't leave a loaded gun.

Sparkle raises its own native windows for a manual check, which land behind the
kiosk — `Updater` calls `onNeedsScreen` first so the shell steps aside, the same
machinery TCC prompts use.

**The obvious risk is the one worth saying out loud**: with this on, a bad
release restarts the kitchen display into a bad build with nobody there. There
is no rollback. Run a release build locally before publishing it.

## The first Developer ID build resets every permission

TCC keys grants to the code signature, and a release is signed with Developer
ID where the kitchen build is signed with "Neon Dev". macOS sees a different
application, so **microphone, speech recognition, camera, location and
calendars all go back to unasked** the first time a released build runs on a
machine that had been running a local one.

That is survivable but not silent: she comes up unable to hear until the
prompts are answered, and the prompts appear behind the kiosk (Ctrl-Opt-Cmd-H
steps aside; the panel's own Allow button handles calendars). It happens once.
Every Developer ID build after that is the same identity and keeps its grants.

Worth doing deliberately, standing at the machine, rather than discovering it
the morning after an unattended update.

## Building without Sparkle

`Updater.swift` is behind `#if canImport(Sparkle)`. That matters more than it
sounds: the wake-model pipeline and the offline harnesses get run from
checkouts where pulling a UI framework in to score a WAV file would be silly.
Without it the settings panel shows the version and no update button.
