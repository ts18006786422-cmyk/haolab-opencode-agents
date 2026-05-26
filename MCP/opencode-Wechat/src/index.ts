import crypto from "node:crypto"
import { mkdir } from "node:fs/promises"
import path from "node:path"
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { z } from "zod"

const env = process.env
const DEFAULT_BASE_URL = "https://ilinkai.weixin.qq.com"
const DEFAULT_BOT_TYPE = "3"
const CHANNEL_VERSION = "2.4.4"
const ILINK_APP_ID = "bot"
const ILINK_APP_CLIENT_VERSION = String(buildClientVersion(CHANNEL_VERSION))
const STATE_DIR = path.resolve(process.cwd(), env.ILINK_STATE_DIR || ".opencode/ilink-weixin")
const CREDENTIALS_PATH = path.join(STATE_DIR, "credentials.json")
const SYNC_BUF_PATH = path.join(STATE_DIR, "sync-buf.txt")
const CONTEXT_TOKENS_PATH = path.join(STATE_DIR, "context-tokens.json")
const EVENTS_PATH = path.join(STATE_DIR, "events.json")
const INBOX_DIR = path.resolve(process.cwd(), env.ILINK_INBOX_DIR || ".opencode/ilink-weixin/inbox")
const LEGACY_DOWNLOAD_DIR = path.resolve(process.cwd(), env.ILINK_DOWNLOAD_DIR || ".opencode/ilink-downloads")
const DEFAULT_SIDECAR_PATH = path.join(env.HOME || process.cwd(), "Library/Application Support/ai.opencode.desktop/sidecar.json")
const SESSION_EXPIRED_ERRCODE = -14

const server = new McpServer({ name: "ilink-weixin", version: "0.2.0" })
const persistedCredential = await readJson<Credential>(CREDENTIALS_PATH)
const persistedEvents = await readJson<WeixinEvent[]>(EVENTS_PATH)

let login: { sessionKey: string; qrcode: string; qrcodeUrl: string; baseUrl: string; startedAt: string } | undefined
let credential: Credential = {
  token: env.ILINK_BOT_TOKEN || persistedCredential?.token,
  accountId: env.ILINK_ACCOUNT_ID || persistedCredential?.accountId,
  baseUrl: env.ILINK_BASE_URL || persistedCredential?.baseUrl || DEFAULT_BASE_URL,
  userId: env.ILINK_USER_ID || persistedCredential?.userId,
}
let updatesBuf = env.ILINK_UPDATES_BUF || (await Bun.file(SYNC_BUF_PATH).text().catch(() => ""))
let contextTokens = (await readJson<Record<string, string>>(CONTEXT_TOKENS_PATH)) ?? {}
let events = persistedEvents ?? []
let lastMessage: WeixinMessage | undefined
let watch: WatchState = { running: false, delivered: 0, received: 0, failures: 0 }

server.registerTool(
  "ilink_login_start",
  {
    title: "Start iLink Weixin login",
    description: "Create a Weixin iLink Bot QR login URL without requiring OpenClaw or QClaw to be installed.",
    inputSchema: {
      force: z.boolean().optional().describe("Force a new QR code even if the last one is still cached."),
      botType: z.string().optional().describe("iLink bot_type. Defaults to 3, matching openclaw-weixin."),
    },
  },
  async (input) => {
    if (!input.force && login) return jsonResult(login)
    const response = await postJson<QRCodeResponse>({
      baseUrl: DEFAULT_BASE_URL,
      endpoint: `ilink/bot/get_bot_qrcode?bot_type=${encodeURIComponent(input.botType || DEFAULT_BOT_TYPE)}`,
      body: { local_token_list: credential.token ? [credential.token] : [] },
    })
    login = {
      sessionKey: crypto.randomUUID(),
      qrcode: response.qrcode,
      qrcodeUrl: response.qrcode_img_content,
      baseUrl: DEFAULT_BASE_URL,
      startedAt: new Date().toISOString(),
    }
    return jsonResult(login)
  },
)

server.registerTool(
  "ilink_login_wait",
  {
    title: "Wait for iLink Weixin login",
    description: "Poll the current iLink QR login session and persist bot_token after Weixin scan confirmation.",
    inputSchema: {
      qrcode: z.string().optional().describe("QR code id. Defaults to the last ilink_login_start result."),
      verifyCode: z.string().optional().describe("Optional numeric verify code shown on the phone."),
      baseUrl: z.string().optional().describe("Polling base URL. Defaults to the current redirected login base URL."),
    },
  },
  async (input) => {
    const qrcode = requireValue(input.qrcode ?? login?.qrcode, "qrcode or an active login")
    const endpoint = `ilink/bot/get_qrcode_status?qrcode=${encodeURIComponent(qrcode)}${input.verifyCode ? `&verify_code=${encodeURIComponent(input.verifyCode)}` : ""}`
    const response = await getJson<StatusResponse>({ baseUrl: input.baseUrl ?? login?.baseUrl ?? DEFAULT_BASE_URL, endpoint })
    if (response.status === "scaned_but_redirect" && response.redirect_host && login) {
      login = { ...login, baseUrl: `https://${response.redirect_host}` }
    }
    if (response.status === "confirmed") {
      credential = {
        token: response.bot_token,
        accountId: response.ilink_bot_id,
        baseUrl: response.baseurl || login?.baseUrl || DEFAULT_BASE_URL,
        userId: response.ilink_user_id,
      }
      login = undefined
      await saveCredential()
      return jsonResult({
        status: response.status,
        token: credential.token,
        accountId: credential.accountId,
        baseUrl: credential.baseUrl,
        userId: credential.userId,
        persistedTo: CREDENTIALS_PATH,
      })
    }
    return jsonResult({ status: response.status, redirectHost: response.redirect_host, hasToken: Boolean(response.bot_token) })
  },
)

server.registerTool(
  "ilink_get_updates",
  {
    title: "Get iLink Weixin updates",
    description: "Long-poll Weixin iLink Bot updates using persisted credentials or ILINK_BOT_TOKEN.",
    inputSchema: {
      token: z.string().optional().describe("iLink bot token. Defaults to persisted/in-memory token or ILINK_BOT_TOKEN."),
      baseUrl: z.string().optional().describe("iLink API base URL. Defaults to persisted/in-memory baseUrl, ILINK_BASE_URL, or ilinkai.weixin.qq.com."),
      updatesBuf: z.string().optional().describe("Sync cursor. Defaults to the server's persisted/in-memory cursor."),
      timeoutMs: z.number().int().positive().optional().describe("Long-poll timeout in ms. Defaults to 35000."),
    },
  },
  async (input) => {
    const response = await fetchUpdates({
      token: input.token ?? credential.token,
      baseUrl: input.baseUrl ?? credential.baseUrl,
      updatesBuf: input.updatesBuf ?? updatesBuf,
      timeoutMs: input.timeoutMs ?? 35_000,
    })
    return jsonResult({ ...response, saved_updates_buf: updatesBuf, lastMessage: summarizeMessage(lastMessage) })
  },
)

server.registerTool(
  "ilink_watch_start",
  {
    title: "Start iLink watch loop",
    description: "Start background Weixin long-polling, auto-download media into the workspace inbox, and optionally deliver prompts to an opencode sidecar session.",
    inputSchema: {
      sessionId: z.string().optional().describe("opencode session id to deliver prompts to. Defaults to ILINK_OPENCODE_SESSION_ID."),
      agent: z.string().optional().describe("opencode agent name for delivered prompts. Defaults to ILINK_OPENCODE_AGENT."),
      sidecarPath: z.string().optional().describe("Path to sidecar.json. Defaults to the desktop sidecar path."),
      directory: z.string().optional().describe("Workspace directory for sidecar x-opencode-directory. Defaults to current working directory."),
      timeoutMs: z.number().int().positive().optional().describe("Long-poll timeout in ms. Defaults to 35000."),
      deliver: z.boolean().optional().describe("Whether to deliver events to sidecar. Defaults to true when a session id is available."),
    },
  },
  async (input) => {
    if (watch.running) return jsonResult(watchSummary())
    watch = {
      running: true,
      delivered: watch.delivered,
      received: watch.received,
      failures: 0,
      startedAt: new Date().toISOString(),
      sessionId: input.sessionId || env.ILINK_OPENCODE_SESSION_ID,
      agent: input.agent || env.ILINK_OPENCODE_AGENT,
      sidecarPath: input.sidecarPath || env.ILINK_OPENCODE_SIDECAR || DEFAULT_SIDECAR_PATH,
      directory: input.directory || env.ILINK_OPENCODE_DIRECTORY || process.cwd(),
      timeoutMs: input.timeoutMs ?? 35_000,
      deliver: input.deliver ?? Boolean(input.sessionId || env.ILINK_OPENCODE_SESSION_ID),
    }
    void watchLoop()
    return jsonResult(watchSummary())
  },
)

server.registerTool(
  "ilink_watch_stop",
  {
    title: "Stop iLink watch loop",
    description: "Stop the background Weixin long-polling loop.",
  },
  async () => {
    watch.running = false
    watch.stoppedAt = new Date().toISOString()
    return jsonResult(watchSummary())
  },
)

server.registerTool(
  "ilink_next_event",
  {
    title: "Get next iLink event",
    description: "Return the oldest queued Weixin event. Events are also persisted under .opencode/ilink-weixin/events.json.",
    inputSchema: {
      remove: z.boolean().optional().describe("Remove the returned event from the queue. Defaults to false."),
    },
  },
  async (input) => {
    const event = events[0]
    if (input.remove && event) {
      events = events.slice(1)
      await saveEvents()
    }
    return jsonResult({ event, remaining: events.length })
  },
)

server.registerTool(
  "ilink_download_last_media",
  {
    title: "Download last iLink media",
    description: "Download and decrypt a file/image/voice/video from the most recent message returned by ilink_get_updates. Files are saved under the current workspace.",
    inputSchema: {
      itemIndex: z.number().int().nonnegative().optional().describe("Media item index in lastMessage.media. Defaults to 0."),
      downloadDir: z.string().optional().describe("Workspace-relative or absolute output directory. Defaults to .opencode/ilink-downloads."),
      cdnBaseUrl: z.string().optional().describe("CDN base URL used when media.full_url is missing. Defaults to baseUrl."),
    },
  },
  async (input) => {
    if (!lastMessage) return textResult("No last message. Call ilink_get_updates first.")
    const item = mediaItems(lastMessage)[input.itemIndex ?? 0]
    if (!item) return textResult("No media item found in the last message.")
    const result = await downloadMediaItem({
      item,
      cdnBaseUrl: input.cdnBaseUrl ?? credential.baseUrl,
      downloadDir: input.downloadDir ? path.resolve(process.cwd(), input.downloadDir) : LEGACY_DOWNLOAD_DIR,
    })
    return jsonResult(result)
  },
)

server.registerTool(
  "ilink_reply_last_text",
  {
    title: "Reply to last iLink message",
    description: "Send a text reply to the most recent message returned by ilink_get_updates.",
    inputSchema: {
      text: z.string().describe("Reply text."),
      token: z.string().optional().describe("iLink bot token. Defaults to persisted/in-memory token or ILINK_BOT_TOKEN."),
      baseUrl: z.string().optional().describe("iLink API base URL."),
    },
  },
  async (input) => {
    if (!lastMessage?.from_user_id) return textResult("No last inbound message with from_user_id. Call ilink_get_updates first.")
    await sendTextMessage({
      baseUrl: input.baseUrl ?? credential.baseUrl,
      token: input.token ?? credential.token,
      toUserId: lastMessage.from_user_id,
      contextToken: lastMessage.context_token || contextTokens[lastMessage.from_user_id],
      text: input.text,
    })
    return jsonResult({ toUserId: lastMessage.from_user_id, contextToken: lastMessage.context_token, text: input.text })
  },
)

server.registerTool(
  "ilink_reply_event_text",
  {
    title: "Reply to iLink event",
    description: "Send a text reply to a queued Weixin event using its persisted context_token.",
    inputSchema: {
      eventId: z.string().describe("Event id from ilink_next_event or delivered sidecar prompt."),
      text: z.string().describe("Reply text."),
    },
  },
  async (input) => {
    const event = events.find((item) => item.id === input.eventId) ?? (await readJson<WeixinEvent>(path.join(INBOX_DIR, input.eventId, "message.json")))
    if (!event) return textResult(`Event not found: ${input.eventId}`)
    await sendTextMessage({
      baseUrl: credential.baseUrl,
      token: credential.token,
      toUserId: event.fromUserId,
      contextToken: event.contextToken || contextTokens[event.fromUserId],
      text: input.text,
    })
    return jsonResult({ eventId: input.eventId, toUserId: event.fromUserId, text: input.text })
  },
)

server.registerTool(
  "ilink_reply_event_file",
  {
    title: "Reply to iLink event with file",
    description: "Upload a local file to iLink CDN and send it as a reply to a queued Weixin event.",
    inputSchema: {
      eventId: z.string().describe("Event id from ilink_next_event or delivered sidecar prompt."),
      filePath: z.string().describe("Workspace-relative or absolute local file path to send."),
      text: z.string().optional().describe("Optional text caption sent before the file."),
    },
  },
  async (input) => {
    const event = events.find((item) => item.id === input.eventId) ?? (await readJson<WeixinEvent>(path.join(INBOX_DIR, input.eventId, "message.json")))
    if (!event) return textResult(`Event not found: ${input.eventId}`)
    const result = await sendFileMessage({
      baseUrl: credential.baseUrl,
      token: credential.token,
      toUserId: event.fromUserId,
      contextToken: event.contextToken || contextTokens[event.fromUserId],
      filePath: path.resolve(process.cwd(), input.filePath),
      text: input.text || "",
    })
    return jsonResult({ eventId: input.eventId, toUserId: event.fromUserId, ...result })
  },
)

server.registerTool(
  "ilink_send_text",
  {
    title: "Send iLink text message",
    description: "Send a Weixin iLink text message. For reliable replies, pass the contextToken from an inbound message.",
    inputSchema: {
      toUserId: z.string().describe("Target iLink user id."),
      text: z.string().describe("Message text."),
      contextToken: z.string().optional().describe("Conversation context_token from getupdates."),
      token: z.string().optional().describe("iLink bot token. Defaults to persisted/in-memory token or ILINK_BOT_TOKEN."),
      baseUrl: z.string().optional().describe("iLink API base URL."),
    },
  },
  async (input) => {
    await sendTextMessage({
      baseUrl: input.baseUrl ?? credential.baseUrl,
      token: input.token ?? credential.token,
      toUserId: input.toUserId,
      contextToken: input.contextToken || contextTokens[input.toUserId],
      text: input.text,
    })
    return jsonResult({ toUserId: input.toUserId, contextToken: input.contextToken || contextTokens[input.toUserId], text: input.text })
  },
)

server.registerTool(
  "ilink_send_file",
  {
    title: "Send iLink file message",
    description: "Upload a local file to iLink CDN and send it to a Weixin iLink user. For reliable replies, pass a contextToken or use ilink_reply_event_file.",
    inputSchema: {
      toUserId: z.string().describe("Target iLink user id."),
      filePath: z.string().describe("Workspace-relative or absolute local file path to send."),
      text: z.string().optional().describe("Optional text caption sent before the file."),
      contextToken: z.string().optional().describe("Conversation context_token from getupdates."),
      token: z.string().optional().describe("iLink bot token. Defaults to persisted/in-memory token or ILINK_BOT_TOKEN."),
      baseUrl: z.string().optional().describe("iLink API base URL."),
    },
  },
  async (input) => {
    const result = await sendFileMessage({
      baseUrl: input.baseUrl ?? credential.baseUrl,
      token: input.token ?? credential.token,
      toUserId: input.toUserId,
      contextToken: input.contextToken || contextTokens[input.toUserId],
      filePath: path.resolve(process.cwd(), input.filePath),
      text: input.text || "",
    })
    return jsonResult({ toUserId: input.toUserId, contextToken: input.contextToken || contextTokens[input.toUserId], ...result })
  },
)

server.registerTool(
  "ilink_status",
  {
    title: "iLink Weixin status",
    description: "Show current login, credential, cursor, watch, queue, and last message metadata.",
  },
  async () =>
    jsonResult({
      login,
      credential: { ...credential, token: credential.token ? "***" : undefined },
      hasUpdatesBuf: Boolean(updatesBuf),
      contextTokenCount: Object.keys(contextTokens).length,
      queuedEvents: events.length,
      watch: watchSummary(),
      stateDir: STATE_DIR,
      inboxDir: INBOX_DIR,
      lastMessage: summarizeMessage(lastMessage),
    }),
)

await server.connect(new StdioServerTransport())

process.on("SIGINT", () => stopAndExit())
process.on("SIGTERM", () => stopAndExit())

async function fetchUpdates(input: { token?: string; baseUrl: string; updatesBuf: string; timeoutMs: number }) {
  const response = await postJson<GetUpdatesResponse>({
    baseUrl: input.baseUrl,
    endpoint: "ilink/bot/getupdates",
    token: requireValue(input.token, "token or ILINK_BOT_TOKEN"),
    timeoutMs: input.timeoutMs,
    body: { get_updates_buf: input.updatesBuf, base_info: buildBaseInfo() },
  })
  if (response.errcode === SESSION_EXPIRED_ERRCODE || response.ret === SESSION_EXPIRED_ERRCODE) {
    watch.lastError = "iLink session expired; please scan login again"
    watch.running = false
    return response
  }
  updatesBuf = response.get_updates_buf ?? updatesBuf
  await saveText(SYNC_BUF_PATH, updatesBuf)
  lastMessage = response.msgs?.at(-1) ?? lastMessage
  for (const message of response.msgs ?? []) {
    if (message.from_user_id && message.context_token) contextTokens[message.from_user_id] = message.context_token
  }
  if (response.msgs?.length) await writeJson(CONTEXT_TOKENS_PATH, contextTokens)
  return response
}

async function watchLoop() {
  while (watch.running) {
    try {
      const response = await fetchUpdates({
        token: credential.token,
        baseUrl: credential.baseUrl,
        updatesBuf,
        timeoutMs: watch.timeoutMs ?? 35_000,
      })
      if (!watch.running) break
      for (const message of response.msgs ?? []) {
        watch.received += 1
        const event = await buildEvent(message)
        events = [...events, event].slice(-200)
        await saveEvents()
        await writeJson(path.join(event.dir, "message.json"), event)
        if (watch.deliver && watch.sessionId) await deliverEvent(event)
      }
      watch.failures = 0
    } catch (error) {
      watch.failures += 1
      watch.lastError = error instanceof Error ? error.message : String(error)
      await sleep(watch.failures >= 3 ? 30_000 : 2_000)
    }
  }
}

async function buildEvent(message: WeixinMessage): Promise<WeixinEvent> {
  const eventId = `weixin-${message.message_id || message.seq || Date.now()}-${crypto.randomUUID().slice(0, 8)}`
  const dir = path.join(INBOX_DIR, eventId)
  const filesDir = path.join(dir, "files")
  await mkdir(filesDir, { recursive: true })
  const files = []
  for (const item of mediaItems(message)) {
    files.push(await downloadMediaItem({ item, cdnBaseUrl: credential.baseUrl, downloadDir: filesDir }))
  }
  return {
    id: eventId,
    receivedAt: new Date().toISOString(),
    fromUserId: message.from_user_id ?? "",
    toUserId: message.to_user_id,
    messageId: message.message_id,
    sessionId: message.session_id,
    contextToken: message.context_token,
    text: messageText(message),
    files,
    dir,
  }
}

async function deliverEvent(event: WeixinEvent) {
  const sidecar = await readJson<Sidecar>(watch.sidecarPath || DEFAULT_SIDECAR_PATH)
  if (!sidecar) throw new Error(`sidecar not found: ${watch.sidecarPath || DEFAULT_SIDECAR_PATH}`)
  const response = await fetch(`${sidecar.url}/session/${encodeURIComponent(requireValue(watch.sessionId, "watch.sessionId"))}/prompt_async`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${Buffer.from(`${sidecar.username}:${sidecar.password}`).toString("base64")}`,
      "Content-Type": "application/json",
      "x-opencode-directory": watch.directory || process.cwd(),
    },
    body: JSON.stringify({
      agent: watch.agent || undefined,
      parts: [
        {
          type: "text",
          text: eventPrompt(event),
          metadata: { source: "ilink-weixin", eventId: event.id },
        },
        ...event.files.map((file) => ({
          type: "file" as const,
          mime: file.mime,
          filename: file.filename,
          url: `file://${file.path}`,
        })),
      ],
    }),
  })
  if (!response.ok) throw new Error(`sidecar prompt_async failed ${response.status}: ${await response.text().catch(() => "")}`)
  watch.delivered += 1
}

function eventPrompt(event: WeixinEvent) {
  return [
    "收到一条微信消息。",
    `event_id: ${event.id}`,
    `from_user_id: ${event.fromUserId}`,
    event.text ? `text:\n${event.text}` : "text: (empty)",
    event.files.length
      ? `downloaded_files:\n${event.files.map((file) => `- ${file.path} (${file.mime}, ${file.bytes} bytes)`).join("\n")}`
      : "downloaded_files: none",
    "处理完成后，如需回复微信，请调用 MCP 工具 ilink_reply_event_text，传入 eventId 和回复文本。",
  ].join("\n")
}

async function sendTextMessage(input: {
  baseUrl: string
  token?: string
  toUserId: string
  contextToken?: string
  text: string
}) {
  await postJson({
    baseUrl: input.baseUrl,
    endpoint: "ilink/bot/sendmessage",
    token: requireValue(input.token, "token or ILINK_BOT_TOKEN"),
    body: {
      msg: {
        to_user_id: input.toUserId,
        context_token: input.contextToken,
        item_list: [{ type: 1, text_item: { text: input.text } }],
      },
      base_info: buildBaseInfo(),
    },
  })
}

async function sendFileMessage(input: {
  baseUrl: string
  token?: string
  toUserId: string
  contextToken?: string
  filePath: string
  text: string
}) {
  const uploaded = await uploadFileToWeixin({
    baseUrl: input.baseUrl,
    token: input.token,
    toUserId: input.toUserId,
    filePath: input.filePath,
  })
  const mime = mimeFromFilename(input.filePath)
  const fileName = path.basename(input.filePath)
  const mediaItem = mime.startsWith("image/")
    ? {
        type: 2,
        image_item: {
          media: uploadMedia(uploaded),
          mid_size: uploaded.fileSizeCiphertext,
        },
      }
    : mime.startsWith("video/")
      ? {
          type: 5,
          video_item: {
            media: uploadMedia(uploaded),
            video_size: uploaded.fileSizeCiphertext,
          },
        }
      : {
          type: 4,
          file_item: {
            media: uploadMedia(uploaded),
            file_name: fileName,
            len: String(uploaded.fileSize),
          },
        }
  const messageIds = []
  if (input.text) messageIds.push(await sendMessageItem({ ...input, item: { type: 1, text_item: { text: input.text } } }))
  messageIds.push(await sendMessageItem({ ...input, item: mediaItem }))
  return { fileName, mime, uploaded, messageIds }
}

async function sendMessageItem(input: {
  baseUrl: string
  token?: string
  toUserId: string
  contextToken?: string
  item: MessageItem
}) {
  const clientId = `ilink-weixin-${crypto.randomUUID()}`
  await postJson({
    baseUrl: input.baseUrl,
    endpoint: "ilink/bot/sendmessage",
    token: requireValue(input.token, "token or ILINK_BOT_TOKEN"),
    body: {
      msg: {
        from_user_id: "",
        to_user_id: input.toUserId,
        client_id: clientId,
        message_type: 2,
        message_state: 2,
        item_list: [input.item],
        context_token: input.contextToken,
      },
      base_info: buildBaseInfo(),
    },
  })
  return clientId
}

async function uploadFileToWeixin(input: { baseUrl: string; token?: string; toUserId: string; filePath: string }): Promise<UploadedFileInfo> {
  const plaintext = Buffer.from(await Bun.file(input.filePath).arrayBuffer())
  const aeskey = crypto.randomBytes(16)
  const filekey = crypto.randomBytes(16).toString("hex")
  const upload = await postJson<GetUploadUrlResponse>({
    baseUrl: input.baseUrl,
    endpoint: "ilink/bot/getuploadurl",
    token: requireValue(input.token, "token or ILINK_BOT_TOKEN"),
    timeoutMs: 15_000,
    body: {
      filekey,
      media_type: uploadMediaType(input.filePath),
      to_user_id: input.toUserId,
      rawsize: plaintext.length,
      rawfilemd5: crypto.createHash("md5").update(plaintext).digest("hex"),
      filesize: aesEcbPaddedSize(plaintext.length),
      no_need_thumb: true,
      aeskey: aeskey.toString("hex"),
      base_info: buildBaseInfo(),
    },
  })
  const downloadEncryptedQueryParam = await uploadBufferToCdn({
    plaintext,
    uploadFullUrl: upload.upload_full_url,
    uploadParam: upload.upload_param,
    filekey,
    cdnBaseUrl: input.baseUrl,
    aeskey,
  })
  return {
    filekey,
    downloadEncryptedQueryParam,
    aeskey: aeskey.toString("hex"),
    fileSize: plaintext.length,
    fileSizeCiphertext: aesEcbPaddedSize(plaintext.length),
  }
}

async function uploadBufferToCdn(input: {
  plaintext: Buffer
  uploadFullUrl?: string
  uploadParam?: string
  filekey: string
  cdnBaseUrl: string
  aeskey: Buffer
}) {
  const ciphertext = encryptAesEcb(input.plaintext, input.aeskey)
  const uploadUrl = input.uploadFullUrl || buildCdnUploadUrl(input.uploadParam, input.filekey, input.cdnBaseUrl)
  let lastError: unknown
  for (const attempt of [1, 2, 3]) {
    try {
      const response = await fetch(uploadUrl, {
        method: "POST",
        headers: { "Content-Type": "application/octet-stream" },
        body: new Uint8Array(ciphertext),
      })
      if (response.status >= 400 && response.status < 500) throw new Error(`CDN upload client error ${response.status}: ${await response.text()}`)
      if (response.status !== 200) throw new Error(`CDN upload server error ${response.status}`)
      const downloadParam = response.headers.get("x-encrypted-param")
      if (!downloadParam) throw new Error("CDN upload response missing x-encrypted-param header")
      return downloadParam
    } catch (error) {
      lastError = error
      if (attempt === 3) break
      await sleep(500 * attempt)
    }
  }
  throw lastError instanceof Error ? lastError : new Error("CDN upload failed")
}

async function getJson<T>(input: { baseUrl: string; endpoint: string; timeoutMs?: number }) {
  return requestJson<T>({ ...input, method: "GET" })
}

async function postJson<T = unknown>(input: { baseUrl: string; endpoint: string; body: unknown; token?: string; timeoutMs?: number }) {
  return requestJson<T>({ ...input, method: "POST" })
}

async function requestJson<T>(input: {
  method: "GET" | "POST"
  baseUrl: string
  endpoint: string
  body?: unknown
  token?: string
  timeoutMs?: number
}) {
  const controller = input.timeoutMs ? new AbortController() : undefined
  const timeout = controller && input.timeoutMs ? setTimeout(() => controller.abort(), input.timeoutMs) : undefined
  try {
    const response = await fetch(new URL(input.endpoint, input.baseUrl.endsWith("/") ? input.baseUrl : `${input.baseUrl}/`), {
      method: input.method,
      headers: buildHeaders(input.token),
      body: input.body === undefined ? undefined : JSON.stringify(input.body),
      signal: controller?.signal,
    })
    const text = await response.text()
    if (!response.ok) throw new Error(`${input.method} ${input.endpoint} failed ${response.status}: ${text}`)
    return JSON.parse(text) as T
  } finally {
    if (timeout) clearTimeout(timeout)
  }
}

function buildHeaders(token: string | undefined) {
  return {
    "Content-Type": "application/json",
    "iLink-App-Id": ILINK_APP_ID,
    "iLink-App-ClientVersion": ILINK_APP_CLIENT_VERSION,
    AuthorizationType: "ilink_bot_token",
    "X-WECHAT-UIN": Buffer.from(String(crypto.randomBytes(4).readUInt32BE(0)), "utf-8").toString("base64"),
    ...(token?.trim() ? { Authorization: `Bearer ${token.trim()}` } : {}),
  }
}

function buildBaseInfo() {
  return { channel_version: CHANNEL_VERSION, bot_agent: env.ILINK_BOT_AGENT || "OpenClaw" }
}

async function downloadMediaItem(input: { item: MessageItem; cdnBaseUrl: string; downloadDir: string }): Promise<DownloadedFile> {
  const media = mediaRef(input.item)
  if (!media) throw new Error("Selected item has no downloadable media reference")
  const encrypted = await fetchBytes(media.full_url || buildCdnDownloadUrl(media.encrypt_query_param, input.cdnBaseUrl))
  const aesKey = mediaAesKey(input.item)
  const buffer = aesKey ? decryptAesEcb(encrypted, parseAesKey(aesKey)) : encrypted
  const filename = uniqueFilename(filenameForItem(input.item))
  const output = path.join(input.downloadDir, filename)
  await mkdir(input.downloadDir, { recursive: true })
  await Bun.write(output, buffer)
  return {
    path: output,
    type: mediaTypeName(input.item.type),
    mime: mimeForItem(input.item),
    filename,
    bytes: buffer.byteLength,
    encryptedBytes: encrypted.byteLength,
    decrypted: Boolean(aesKey),
  }
}

async function fetchBytes(url: string) {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`CDN download failed ${response.status}: ${await response.text().catch(() => "")}`)
  return Buffer.from(await response.arrayBuffer())
}

function decryptAesEcb(ciphertext: Buffer, key: Buffer) {
  const decipher = crypto.createDecipheriv("aes-128-ecb", key, null)
  return Buffer.concat([decipher.update(ciphertext), decipher.final()])
}

function encryptAesEcb(plaintext: Buffer, key: Buffer) {
  const cipher = crypto.createCipheriv("aes-128-ecb", key, null)
  return Buffer.concat([cipher.update(plaintext), cipher.final()])
}

function aesEcbPaddedSize(plaintextSize: number) {
  return Math.ceil((plaintextSize + 1) / 16) * 16
}

function parseAesKey(aesKeyBase64: string) {
  const decoded = Buffer.from(aesKeyBase64, "base64")
  if (decoded.length === 16) return decoded
  if (decoded.length === 32 && /^[0-9a-fA-F]{32}$/.test(decoded.toString("ascii"))) return Buffer.from(decoded.toString("ascii"), "hex")
  throw new Error(`aes_key must decode to 16 raw bytes or 32-char hex string, got ${decoded.length} bytes`)
}

function buildCdnDownloadUrl(encryptedQueryParam: string | undefined, cdnBaseUrl: string) {
  if (!encryptedQueryParam) throw new Error("media.full_url is missing and encrypt_query_param is empty")
  return `${cdnBaseUrl.replace(/\/$/, "")}/download?encrypted_query_param=${encodeURIComponent(encryptedQueryParam)}`
}

function buildCdnUploadUrl(uploadParam: string | undefined, filekey: string, cdnBaseUrl: string) {
  if (!uploadParam) throw new Error("getUploadUrl returned no upload_full_url or upload_param")
  return `${cdnBaseUrl.replace(/\/$/, "")}/upload?encrypted_query_param=${encodeURIComponent(uploadParam)}&filekey=${encodeURIComponent(filekey)}`
}

function uploadMedia(input: UploadedFileInfo): CDNMedia {
  return {
    encrypt_query_param: input.downloadEncryptedQueryParam,
    aes_key: Buffer.from(input.aeskey).toString("base64"),
    encrypt_type: 1,
  }
}

function uploadMediaType(filePath: string) {
  const mime = mimeFromFilename(filePath)
  if (mime.startsWith("image/")) return 1
  if (mime.startsWith("video/")) return 2
  return 3
}

function buildClientVersion(version: string) {
  const parts = version.split(".").map((part) => Number.parseInt(part, 10))
  return (((parts[0] ?? 0) & 0xff) << 16) | (((parts[1] ?? 0) & 0xff) << 8) | ((parts[2] ?? 0) & 0xff)
}

function summarizeMessage(message: WeixinMessage | undefined) {
  if (!message) return undefined
  return {
    fromUserId: message.from_user_id,
    toUserId: message.to_user_id,
    sessionId: message.session_id,
    contextToken: message.context_token,
    text: messageText(message),
    media: mediaItems(message).map((item, index) => ({
      index,
      type: mediaTypeName(item.type),
      filename: filenameForItem(item),
      hasFullUrl: Boolean(mediaRef(item)?.full_url),
      hasEncryptedQueryParam: Boolean(mediaRef(item)?.encrypt_query_param),
      hasAesKey: Boolean(mediaAesKey(item)),
    })),
  }
}

function mediaItems(message: WeixinMessage) {
  return message.item_list?.filter((item) => Boolean(mediaRef(item))) ?? []
}

function mediaRef(item: MessageItem) {
  if (item.type === 2) return item.image_item?.media
  if (item.type === 3) return item.voice_item?.media
  if (item.type === 4) return item.file_item?.media
  if (item.type === 5) return item.video_item?.media
  return undefined
}

function mediaAesKey(item: MessageItem) {
  if (item.type === 2 && item.image_item?.aeskey) return Buffer.from(item.image_item.aeskey, "hex").toString("base64")
  return mediaRef(item)?.aes_key
}

function messageText(message: WeixinMessage) {
  return message.item_list
    ?.flatMap((item) => {
      if (item.text_item?.text) return [item.text_item.text]
      if (item.voice_item?.text) return [item.voice_item.text]
      return []
    })
    .join("\n")
}

function filenameForItem(item: MessageItem) {
  if (item.type === 4 && item.file_item?.file_name) return safeFilename(item.file_item.file_name)
  if (item.type === 2) return `image-${Date.now()}.jpg`
  if (item.type === 3) return `voice-${Date.now()}.silk`
  if (item.type === 5) return `video-${Date.now()}.mp4`
  return `media-${Date.now()}.bin`
}

function uniqueFilename(filename: string) {
  const parsed = path.parse(filename)
  return `${parsed.name}-${Date.now()}${parsed.ext || ".bin"}`
}

function safeFilename(filename: string) {
  return path.basename(filename).replace(/[^A-Za-z0-9._ -]/g, "_").slice(0, 160) || "file.bin"
}

function mediaTypeName(type: number | undefined) {
  if (type === 2) return "image"
  if (type === 3) return "voice"
  if (type === 4) return "file"
  if (type === 5) return "video"
  return "unknown"
}

function mimeForItem(item: MessageItem) {
  if (item.type === 2) return "image/jpeg"
  if (item.type === 3) return "audio/silk"
  if (item.type === 5) return "video/mp4"
  if (item.type === 4) return mimeFromFilename(item.file_item?.file_name)
  return "application/octet-stream"
}

function mimeFromFilename(filename: string | undefined) {
  const ext = filename?.split(".").pop()?.toLowerCase()
  if (ext === "pdf") return "application/pdf"
  if (ext === "png") return "image/png"
  if (ext === "jpg" || ext === "jpeg") return "image/jpeg"
  if (ext === "gif") return "image/gif"
  if (ext === "txt") return "text/plain"
  if (ext === "md") return "text/markdown"
  if (ext === "json") return "application/json"
  if (ext === "csv") return "text/csv"
  if (ext === "doc") return "application/msword"
  if (ext === "docx") return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  if (ext === "xls") return "application/vnd.ms-excel"
  if (ext === "xlsx") return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  if (ext === "zip") return "application/zip"
  return "application/octet-stream"
}

async function saveCredential() {
  await writeJson(CREDENTIALS_PATH, credential)
}

async function saveEvents() {
  await writeJson(EVENTS_PATH, events)
}

async function readJson<T>(filePath: string): Promise<T | undefined> {
  return Bun.file(filePath)
    .json()
    .catch(() => undefined) as Promise<T | undefined>
}

async function writeJson(filePath: string, value: unknown) {
  await mkdir(path.dirname(filePath), { recursive: true })
  await Bun.write(filePath, JSON.stringify(value, null, 2))
}

async function saveText(filePath: string, value: string) {
  await mkdir(path.dirname(filePath), { recursive: true })
  await Bun.write(filePath, value)
}

function watchSummary() {
  return { ...watch, tokenLoaded: Boolean(credential.token) }
}

async function sleep(ms: number) {
  await new Promise((resolve) => setTimeout(resolve, ms))
}

function stopAndExit() {
  watch.running = false
  process.exit(0)
}

function requireValue(value: string | undefined, name: string) {
  if (value) return value
  throw new Error(`Missing ${name}`)
}

function textResult(text: string) {
  return { content: [{ type: "text" as const, text }] }
}

function jsonResult(value: unknown) {
  return textResult(JSON.stringify(value, null, 2))
}

type Credential = {
  token?: string
  accountId?: string
  baseUrl: string
  userId?: string
}

type WatchState = {
  running: boolean
  delivered: number
  received: number
  failures: number
  startedAt?: string
  stoppedAt?: string
  sessionId?: string
  agent?: string
  sidecarPath?: string
  directory?: string
  timeoutMs?: number
  deliver?: boolean
  lastError?: string
}

type Sidecar = {
  url: string
  username: string
  password: string
}

type QRCodeResponse = {
  qrcode: string
  qrcode_img_content: string
}

type StatusResponse = {
  status: "wait" | "scaned" | "confirmed" | "expired" | "scaned_but_redirect" | "need_verifycode" | "verify_code_blocked" | "binded_redirect"
  bot_token?: string
  ilink_bot_id?: string
  baseurl?: string
  ilink_user_id?: string
  redirect_host?: string
}

type GetUpdatesResponse = {
  ret?: number
  errcode?: number
  errmsg?: string
  msgs?: WeixinMessage[]
  get_updates_buf?: string
  longpolling_timeout_ms?: number
}

type WeixinEvent = {
  id: string
  receivedAt: string
  fromUserId: string
  toUserId?: string
  messageId?: number
  sessionId?: string
  contextToken?: string
  text?: string
  files: DownloadedFile[]
  dir: string
}

type DownloadedFile = {
  path: string
  type: string
  mime: string
  filename: string
  bytes: number
  encryptedBytes: number
  decrypted: boolean
}

type WeixinMessage = {
  seq?: number
  message_id?: number
  from_user_id?: string
  to_user_id?: string
  session_id?: string
  context_token?: string
  item_list?: MessageItem[]
}

type MessageItem = {
  type?: number
  text_item?: { text?: string }
  image_item?: { media?: CDNMedia; aeskey?: string }
  voice_item?: { media?: CDNMedia; text?: string }
  file_item?: { media?: CDNMedia; file_name?: string; md5?: string; len?: string }
  video_item?: { media?: CDNMedia }
}

type CDNMedia = {
  encrypt_query_param?: string
  aes_key?: string
  encrypt_type?: number
  full_url?: string
}

type GetUploadUrlResponse = {
  upload_param?: string
  upload_full_url?: string
}

type UploadedFileInfo = {
  filekey: string
  downloadEncryptedQueryParam: string
  aeskey: string
  fileSize: number
  fileSizeCiphertext: number
}
