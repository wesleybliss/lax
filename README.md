# Lax

A minimal, native Slack desktop client. Zig + [nanoui](https://github.com/justrach/nanoui), no webview. Linux first.

Personal use: one human, one install, no automation.

## Run

```sh
zig build run -- --team "My Workspace" --channel C0123456789
```

`--team` picks a workspace by name or domain substring (the first one otherwise).
`--channel` opens a conversation by id on start (otherwise the first channel alphabetically).
`LAX_DEBUG=1` logs update counts to stderr, never content, tokens or cookies.

Dev tools: `zig build test`, `zig build spike` (protocol CLI), `zig build net-check` (headless network check), `zig build ui-spike` (10k synthetic messages).

## What this reads from disk, and why

There is no OAuth flow and no registered Slack app. Lax reuses the session the **Slack desktop app already has**, like wee-slack and slk do.
On startup it reads, from a temporary copy (the live profile is locked while Slack runs):

- `Local Storage/leveldb/` in Slack's profile: the `xoxc-` token for each signed-in workspace (`localConfig_v2`).
- `Cookies` (sqlite) in the same profile: the encrypted `d` cookie.
- The OS keyring entry Chromium uses to encrypt that cookie (Linux: Secret Service, via `secret-tool`).

Profile locations tried on Linux: `$XDG_CONFIG_HOME/Slack`, `~/.config/Slack`, the Flatpak path `~/.var/app/com.slack.Slack/config/Slack`, and the Snap path. Copies live in `$XDG_RUNTIME_DIR` and are deleted right after reading.

Tokens and cookies are held in memory only and never logged (`slack/redact.zig`).

**This is unsupported by Slack, and may break without notice or violate their terms. Each user accepts that risk.**
Lax only calls endpoints the web client calls, at human-plausible rates, and uses the websocket instead of polling.

## Layout

- `src/slack/`: protocol (HTTP, websocket, events, mrkdwn, credential extraction). No UI imports.
- `src/store/`: in-memory cache, bounded per channel; UI-thread owned. Queue and self-pipe for cross-thread wake.
- `src/app/`: the network thread feeding the store.
- `src/ui/`: nanoui views.

## Status

Working: all signed-in workspaces (rail on the left with icons and name tooltips, last used remembered, each workspace cached in memory so switching is instant and can be changed mid-load), resizable sidebar laid out like Slack's (Threads, Huddles, Drafts & sent and Saved rows, then Starred, your own sections, Channels, Direct messages and Apps, read from `users.channelSections.list`; listed by your own Slack "sidebar" preference: with "Most recent" the conversations Slack marks dormant fold behind "Show N hidden"; unread dots and mention badges from `client.counts`, presence dots), busy conversations load in the background after connecting, opens with the last known state (conversations, people and the last 25 messages of the ones loaded, kept in `~/.cache/lax`, readable only by you; the network then updates it), account menu on your avatar (away toggle, profile, settings, exit), Settings (interface and chat font, interface zoom, message text size; `~/.config/lax/settings.json`), window and sidebar size remembered (`~/.config/lax/layout.json`), message box of 2 lines with a button on its border for 10, message list (variable height, bottom anchored, older pages on scroll up, selectable text, mrkdwn, clickable links, avatars), reactions (pills, hover toolbar), threads (side panel, reply), typing indicators (in and out), live receive, send, edits and deletes, mark read, `@mention` / `#channel` / `:emoji:` completion, emoji shortcodes.

Credentials: your saved session lives in the system keyring. If Slack rejects it, Lax re-reads the desktop app's session once, then asks you to paste a token and cookie.

Reconnecting: the socket is pinged every 20s. Silence for 60s (`LAX_STALE_SECS` to change) or a socket error ends the session, then it reconnects with backoff (1, 2, 4 … 30s) and refetches the open conversation. HTTP calls use a 10s connect timeout and no kept-alive connections, so a dead network fails fast.

Color emoji come from a COLRv1 patch to the vendored nanoui (see `third_party/nanoui/PATCHES.md`; needs a color emoji font such as Noto Color Emoji, otherwise outlines).

Not yet: pages behind the Threads, Huddles, Drafts & sent and Saved rows (they say "Coming soon"), JPEG workspace icons and profile photos (nanoui decodes PNG only; the initial shows instead), a status editor, a full emoji picker, editing and deleting your own messages, file uploads (out of scope), settings (font size).
