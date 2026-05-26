# opencode-Wechat MCP

MCP server for Weixin iLink Bot integration. It can scan-login through iLink, receive Weixin messages, download/decrypt media into the workspace, send text/file replies, and optionally deliver inbound events to an opencode Desktop session through `sidecar.json`.

Requires Bun because the package entrypoint uses the Bun runtime.

## Install in opencode

The package is published on npm as `haolab-opencode-wechat`.

Global config example (`~/.config/opencode/opencode.jsonc`):

```jsonc
{
  "mcp": {
    "opencode-wechat": {
      "type": "local",
      "command": ["bunx", "haolab-opencode-wechat"],
      "enabled": true,
      "environment": {
        "ILINK_STATE_DIR": "/Users/lose/.opencode/ilink-weixin",
        "ILINK_INBOX_DIR": "/Users/lose/.opencode/ilink-weixin/inbox",
        "ILINK_BOT_TOKEN": "{env:ILINK_BOT_TOKEN}",
        "ILINK_ACCOUNT_ID": "{env:ILINK_ACCOUNT_ID}",
        "ILINK_BASE_URL": "{env:ILINK_BASE_URL}",
        "ILINK_USER_ID": "{env:ILINK_USER_ID}",
        "ILINK_UPDATES_BUF": "{env:ILINK_UPDATES_BUF}",
        "ILINK_BOT_AGENT": "{env:ILINK_BOT_AGENT}",
        "ILINK_OPENCODE_SESSION_ID": "{env:ILINK_OPENCODE_SESSION_ID}",
        "ILINK_OPENCODE_AGENT": "{env:ILINK_OPENCODE_AGENT}",
        "ILINK_OPENCODE_DIRECTORY": "{env:ILINK_OPENCODE_DIRECTORY}",
        "ILINK_OPENCODE_SIDECAR": "{env:ILINK_OPENCODE_SIDECAR}"
      }
    }
  }
}
```

If installing from a local tarball instead of npm:

```jsonc
"command": ["bunx", "/absolute/path/to/haolab-opencode-wechat-0.1.0.tgz"]
```

Restart opencode after changing config. Do not enable this package together with a local copy of the same MCP server, because both expose the same `ilink_*` tools and can share the same iLink state directory.

Use absolute `ILINK_STATE_DIR` and `ILINK_INBOX_DIR` paths in global config when you want all projects to share one Weixin login. Use project-relative paths only when each project should have an isolated login and inbox.

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

- `ILINK_STATE_DIR`: credential and runtime state directory. Defaults to `.opencode/ilink-weixin`; use an absolute path in global config to share one login across projects.
- `ILINK_INBOX_DIR`: inbound media directory. Defaults to `.opencode/ilink-weixin/inbox`; use an absolute path in global config to share one inbox across projects.
- `ILINK_BOT_TOKEN`: optional iLink token override. Usually persisted by `ilink_login_wait` instead.
- `ILINK_ACCOUNT_ID`: optional iLink bot account id override.
- `ILINK_BASE_URL`: optional iLink API base URL. Defaults to `https://ilinkai.weixin.qq.com`.
- `ILINK_USER_ID`: optional iLink user id override.
- `ILINK_UPDATES_BUF`: optional initial iLink sync cursor override.
- `ILINK_BOT_AGENT`: self-declared bot agent string sent to iLink.
- `ILINK_OPENCODE_SESSION_ID`: default session for sidecar delivery.
- `ILINK_OPENCODE_AGENT`: optional agent for delivered prompts.
- `ILINK_OPENCODE_DIRECTORY`: workspace sent as `x-opencode-directory`.
- `ILINK_OPENCODE_SIDECAR`: sidecar JSON path. Defaults to macOS Desktop sidecar path.

## Notes

This uses the iLink Bot HTTP protocol shape used by `@tencent-weixin/openclaw-weixin`. The iLink service decides token validity. If `getupdates` returns session-expired code `-14`, scan login again.
