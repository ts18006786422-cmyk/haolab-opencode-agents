# opencode-Wechat MCP

MCP server for Weixin iLink Bot integration. It can scan-login through iLink, receive Weixin messages, download/decrypt media into the workspace, send text/file replies, and optionally deliver inbound events to an opencode Desktop session through `sidecar.json`.

Requires Bun because the package entrypoint uses the Bun runtime.

## Install in opencode

Project config example:

```jsonc
{
  "mcp": {
    "opencode-wechat": {
      "type": "local",
      "command": ["bunx", "haolab-opencode-wechat"],
      "enabled": true,
      "environment": {
        "ILINK_STATE_DIR": ".opencode/ilink-weixin",
        "ILINK_INBOX_DIR": ".opencode/ilink-weixin/inbox",
        "ILINK_OPENCODE_SESSION_ID": "{env:ILINK_OPENCODE_SESSION_ID}",
        "ILINK_OPENCODE_AGENT": "{env:ILINK_OPENCODE_AGENT}",
        "ILINK_OPENCODE_DIRECTORY": "{env:ILINK_OPENCODE_DIRECTORY}",
        "ILINK_OPENCODE_SIDECAR": "{env:ILINK_OPENCODE_SIDECAR}"
      }
    }
  }
}
```

If installing from a local tarball before publishing:

```jsonc
"command": ["bunx", "/absolute/path/to/haolab-opencode-wechat-0.1.0.tgz"]
```

Restart opencode after changing config.

## First login

1. Call `ilink_login_start`.
2. Open the returned `qrcodeUrl` in Weixin and confirm binding.
3. Call `ilink_login_wait`.

Credentials are persisted under `ILINK_STATE_DIR`:

```text
credentials.json
sync-buf.txt
context-tokens.json
events.json
inbox/
```

Do not commit this directory.

## Background delivery

Call `ilink_watch_start` with a target session:

```json
{
  "sessionId": "ses_xxx",
  "agent": "build",
  "directory": "/path/to/workspace",
  "deliver": true
}
```

Incoming Weixin events are written to:

```text
.opencode/ilink-weixin/inbox/<event-id>/message.json
.opencode/ilink-weixin/inbox/<event-id>/files/
```

When delivery is enabled, the MCP server posts to opencode Desktop:

```text
POST /session/:sessionID/prompt_async
```

using the Basic Auth credentials from `sidecar.json`.

## Tools

- `ilink_login_start`
- `ilink_login_wait`
- `ilink_get_updates`
- `ilink_watch_start`
- `ilink_watch_stop`
- `ilink_next_event`
- `ilink_download_last_media`
- `ilink_reply_last_text`
- `ilink_reply_event_text`
- `ilink_reply_event_file`
- `ilink_send_text`
- `ilink_send_file`
- `ilink_status`

## Environment

- `ILINK_STATE_DIR`: credential and runtime state directory. Defaults to `.opencode/ilink-weixin`.
- `ILINK_INBOX_DIR`: inbound media directory. Defaults to `.opencode/ilink-weixin/inbox`.
- `ILINK_OPENCODE_SESSION_ID`: default session for sidecar delivery.
- `ILINK_OPENCODE_AGENT`: optional agent for delivered prompts.
- `ILINK_OPENCODE_DIRECTORY`: workspace sent as `x-opencode-directory`.
- `ILINK_OPENCODE_SIDECAR`: sidecar JSON path. Defaults to macOS Desktop sidecar path.
- `ILINK_BOT_AGENT`: self-declared bot agent string sent to iLink.

## Notes

This uses the iLink Bot HTTP protocol shape used by `@tencent-weixin/openclaw-weixin`. The iLink service decides token validity. If `getupdates` returns session-expired code `-14`, scan login again.
