# allow-chrome-mcp

A tiny macOS background daemon that auto-dismisses two Chrome annoyances
that come with chrome-devtools-mcp attaching to your running browser
(`--autoConnect`):

1. The **"Allow remote debugging?"** consent dialog — clicks Allow.
2. The **"Chrome is being controlled by automated test software"** banner —
   clicks its X.

## How it works

Every second it walks the native (non-web-content) accessibility tree of any
running Chrome window.

For the consent dialog, it only presses an **Allow** button when the dialog
text mentions **debug** or **DevTools** — so Chrome's other Allow-style
prompts (camera, microphone, notifications) are never touched.

For the banner, it finds the "automated test software" text and searches for
the close button only within the banner's own container — so it can never
hit a tab's Close button.

## Install

```sh
make install
```

This builds the binary, copies it to `~/.local/bin/allow-chrome-mcp`,
installs a launchd agent (`~/Library/LaunchAgents/com.nfarina.allow-chrome-mcp.plist`),
and starts it. It runs at login and is restarted automatically if it dies.

**First run:** macOS will prompt you to grant Accessibility permission. Enable
`allow-chrome-mcp` under **System Settings > Privacy & Security >
Accessibility**. The daemon waits patiently until you do.

**After rebuilding:** macOS ties the Accessibility grant to the binary's
ad-hoc code signature, which changes on every build. After `make install` of
a new build, toggle the permission off and back on (or remove and re-add the
entry).

## Commands

```sh
make install    # build + install + (re)start the agent
make uninstall  # stop the agent and remove everything
make status     # is it running?
make log        # tail the log (~/Library/Logs/allow-chrome-mcp.log)
```

## Debugging the matcher

Run it manually in dry-run mode — it logs what it *would* click, including
the dialog text it saw, without clicking anything:

```sh
./allow-chrome-mcp --dry-run
```

If the dialog text ever changes and stops matching, adjust `keywords` at the
top of `main.swift`.
