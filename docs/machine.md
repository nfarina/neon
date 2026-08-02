# Machine

State of the MacBook Neon runs on, the tooling installed on it, and the
permissions that keep breaking in interesting ways.

Baseline as of July 31, 2026, amended since:

- Apple Command Line Tools are installed.
- Homebrew is installed and available for additional tools.
- The full Xcode application is not installed.
- The current preference is to avoid installing full Xcode unless Neon
  eventually requires it.
- `imsg` was installed through Homebrew for local Messages access.
- Node is installed through Homebrew, primarily so `npx`-based MCP servers work.
- The `chrome-devtools` MCP server is configured at user scope in
  `~/.claude.json` as `npx chrome-devtools-mcp@latest --autoConnect`, matching
  the MacBook Air.
- `--autoConnect` attaches to the normal running Chrome rather than a separate
  profile. It needs remote debugging enabled at
  `chrome://inspect/#remote-debugging` *and* the Chrome-side dialog approving
  the incoming debugging connection. Enabling the toggle only opens the port;
  it does not authorize a client.
- If the server reports `Could not find DevToolsActivePort`, that message is
  misleading. The package wraps the port-file read and the WebSocket connect in
  one `try`, so a refused connection is reported as a missing file. Check
  whether the connection was approved in Chrome before suspecting the file.
  **The usual cause is a timing race, not configuration** (diagnosed
  2026-08-02): Chrome raises the consent dialog per connection, the MCP client
  gives up in well under a second, and `allow-chrome-mcp` was polling at 1 Hz —
  so the first call after an idle period failed and the retry succeeded. Before
  suspecting anything else, verify the endpoint directly: the port file, a
  listener on 9222, and a WebSocket handshake against the UUID path in the file
  (`curl -i -H "Connection: Upgrade" -H "Upgrade: websocket" -H
  "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="
  http://127.0.0.1:9222/devtools/browser/<uuid>` → expect `101`). If that
  handshake works, Chrome is fine and the problem is approval timing.
  `~/Library/Logs/allow-chrome-mcp.log` timestamps show it plainly. The helper
  is now event-driven, so this should stay fixed; a *single* failed call
  followed by a working retry is the signature of it regressing.
- `--browserUrl` is not a usable fallback on Chrome 151: the classic
  `/json/version` discovery endpoint returns 404 in this mode.
- The Chrome DevTools skills that ship inside the `chrome-devtools-mcp` package
  are installed in `~/.claude/skills`. `~/.claude-update-chrome-mcp-skills`
  refreshes them from the latest published package; it also lists skills in
  that directory that did not come from the package, so stale ones are visible.
- Nick's `allow-chrome-mcp` helper lives in its own repo at
  `~/Code/allow-chrome-mcp` (moved out of Neon 2026-08-02 — it is a general
  Chrome/MCP tool, not a Neon one). It installs as the user LaunchAgent
  `com.nfarina.allow-chrome-mcp` and needs macOS Accessibility permission.
  Its Makefile builds against the installed macOS 15.4 SDK with a macOS 15
  deployment target, because Neon's Swift 6.3.3 compiler and default macOS
  26.5 SDK are mismatched.
- macOS keys Accessibility (and other TCC grants) to the code signature, so
  an ad-hoc-signed binary loses its permission on every rebuild — the agent
  then sits in "Waiting for Accessibility permission" while Chrome dialogs go
  unanswered, which looks exactly like the MCP being broken. Both this helper
  and `eyes/build.sh` sign with the stable self-signed "Neon Dev" identity for
  that reason. Same trick, two different permissions (Accessibility, mic).
- Nick's MacBook Air can be mounted through Finder's Network view for small,
  selective file transfers.
- This directory is a Git repository on the `main` branch.
- The app is signed with the self-signed "Neon Dev" certificate (login
  keychain; generated files in `~/.config/neon/codesign*`). This matters:
  ad-hoc signing gives each build a new identity, so macOS silently resets
  the Microphone TCC grant on every rebuild and the wake listener hangs
  forever awaiting an invisible permission callback. `build.sh` prefers
  "Neon Dev", then any Apple Development identity (a machine signed into
  Xcode already has one, and it is just as stable — no cert to generate or
  trust), and only then falls back to ad-hoc with a warning.
