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

Automatic checks on, automatic installs **off**. Neon restarting into a new
build unannounced while somebody is mid-sentence is exactly the wrong behaviour
for something that lives in a room. She notices an update and waits to be told,
from the settings panel.

Sparkle raises its own native windows, which land behind the kiosk — `Updater`
calls `onNeedsScreen` first so the shell steps aside, the same machinery TCC
prompts use.

## Building without Sparkle

`Updater.swift` is behind `#if canImport(Sparkle)`. That matters more than it
sounds: the wake-model pipeline and the offline harnesses get run from
checkouts where pulling a UI framework in to score a WAV file would be silly.
Without it the settings panel shows the version and no update button.
