## HeyGen talking-head plugin for GuiAssert.
##
## Implements GuiAssert's `TalkingHeadProvider` contract on top of the
## commercial HeyGen v2 REST API
## (https://docs.heygen.com/reference/create-an-avatar-video-v2). Like
## the sibling D-ID plugin (`GuiAssert-Did`), this is a pure-Nim HTTP
## client — no Python, no model weights, no GPU toolchain. Unlike D-ID
## the upload-audio-then-render flow does not apply: HeyGen synthesises
## its own voice from a text input on the `generate` endpoint.
##
## ## Wire shape
##
##   * `heygenProvider()` builds a `TalkingHeadProvider` value with
##     `name = "heygen"`, an `isAvailable` check (is `HEYGEN_API_KEY`
##     set?), and a `generate` proc that performs the
##     create / poll / download cycle.
##   * `registerHeyGen(reg)` is the one-liner plugin registration entry
##     point.
##
## ## Important deviation from the generic contract
##
## The `TalkingHeadProvider.generate` contract is
## `generate(narrationWav, outputMp4, opts)` — i.e. the *audio is
## provided as a pre-rendered WAV*. HeyGen v2's `video/generate`
## endpoint does NOT accept uploaded audio in its default mode; it
## takes an `input_text` string plus a `voice_id` and synthesises the
## voiceover internally. This plugin therefore:
##
##   * IGNORES the `narrationWav` parameter for the actual API call,
##     and
##   * REQUIRES `opts.providerSettings["input_text"]` (a string) to be
##     present.
##
## The `narrationWav` parameter is still hashed into the cache key, so
## consumers can carry per-session uniqueness in the WAV (e.g. by
## passing a unique audio file per render call). This keeps the cache
## key compatible with the rest of the GuiAssert ecosystem while making
## the HeyGen plugin a drop-in for the same call sites the local-ML
## plugins use.
##
## ## Configuration
##
## All knobs are read from `TalkingHeadOpts.providerSettings` (a
## JsonNode), falling back to environment variables / sensible
## defaults:
##
##   * `api_key` — HeyGen API key. Falls back to `$HEYGEN_API_KEY`.
##     `isAvailable()` returns false when neither is set.
##   * `api_base` — API base URL. Defaults to `https://api.heygen.com`.
##     Tests point this at a local `std/asynchttpserver` mock so the
##     full create / poll / download cycle is exercised without
##     network.
##   * `input_text` — the script HeyGen should speak. REQUIRED;
##     `generate` raises `TalkingHeadError` if missing/empty.
##   * `avatar_id` — HeyGen avatar identifier. Defaults to
##     `Daisy-inskirt-20220818` (a public stock avatar).
##   * `voice_id` — HeyGen voice identifier. Defaults to a public
##     English voice.
##   * `width` / `height` — output dimensions (default 1280x720).
##
## ## API flow
##
##   1. `POST /v2/video/generate` (JSON) — creates the video job. The
##      JSON body wraps a `video_inputs[]` array with one
##      `character`+`voice` entry. The response is wrapped in
##      `{"data": {"video_id": ...}, "code": 100, ...}`.
##   2. `GET /v1/video_status.get?video_id=...` — polled every
##      `intervalMs` until the status is `completed` (or `failed`).
##      Response shape: `{"data": {"status": ..., "video_url": ...}}`.
##      Honours a 10-minute timeout — HeyGen renders can be slow.
##   3. `GET <video_url>` — downloads the rendered MP4 to disk. The
##      download URL is served from HeyGen's CDN and does NOT require
##      the auth header.
##
## Errors at any step raise `HeyGenError` with the HTTP status code and
## (when present) the response body excerpt.

import std/[os, options, json, httpclient, sha1, strutils, times]

import gui_assert/talking_head

type
  HeyGenError* = object of TalkingHeadError
    ## Raised by the low-level HTTP entry points. Subclasses
    ## `TalkingHeadError` so the generic dispatch in
    ## `gui_assert/talking_head` can catch it uniformly.

const
  ProviderName* = "heygen"
  DefaultHeyGenApiBase* = "https://api.heygen.com"
  DefaultMaxPollSecs* = 600.0
    ## HeyGen renders can take a couple of minutes; we give 10 minutes
    ## of slack before giving up. This is the per-request wall-clock
    ## cap on the polling loop, not the HTTP request timeout.
  DefaultPollIntervalMs* = 5000
  DefaultAvatarId* = "Daisy-inskirt-20220818"
    ## HeyGen public stock avatar. Documented in the v2 quick-start.
  DefaultVoiceId* = "1bd001e7e50f421d891986aad5158bc8"
    ## HeyGen public English voice. Documented in the v2 quick-start.
  DefaultWidth* = 1280
  DefaultHeight* = 720
  ApiKeyEnvVar* = "HEYGEN_API_KEY"
  ApiBaseSetting* = "api_base"
  ApiKeySetting* = "api_key"
  InputTextSetting* = "input_text"
  AvatarIdSetting* = "avatar_id"
  VoiceIdSetting* = "voice_id"
  WidthSetting* = "width"
  HeightSetting* = "height"

# ---------------------------------------------------------------------------
# Pure helpers — testable without any network access.
# ---------------------------------------------------------------------------

proc heygenAuthHeader*(apiKey: string): HttpHeaders =
  ## Build the auth header table HeyGen expects. HeyGen uses a single
  ## `X-Api-Key: <key>` header (NOT HTTP Basic auth). We pin
  ## `Content-Type: application/json` alongside because every
  ## authenticated HeyGen request from this plugin sends a JSON body
  ## (or, for `GET /v1/video_status.get`, no body — the
  ## Content-Type is harmless on a GET).
  newHttpHeaders({"X-Api-Key": apiKey, "Content-Type": "application/json"})

proc buildGenerateBody*(inputText, avatarId, voiceId: string;
                        width = DefaultWidth,
                        height = DefaultHeight): JsonNode =
  ## Construct the JSON body for `POST /v2/video/generate`. Mirrors the
  ## documented v2 quick-start shape exactly: a single-element
  ## `video_inputs` array whose only element wraps a `character`
  ## (typed `avatar` with the canonical `normal` style) and a
  ## `voice` (typed `text`, with `input_text` + `voice_id`). The
  ## `dimension` object sits at the top level.
  result = %*{
    "video_inputs": [{
      "character": {
        "type": "avatar",
        "avatar_id": avatarId,
        "avatar_style": "normal"
      },
      "voice": {
        "type": "text",
        "input_text": inputText,
        "voice_id": voiceId
      }
    }],
    "dimension": {
      "width": width,
      "height": height
    }
  }

proc resolveApiKey*(opts: TalkingHeadOpts): string =
  ## Order of precedence: `opts.providerSettings.api_key`, then the
  ## `$HEYGEN_API_KEY` env var, then "" (signalling unavailability).
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{ApiKeySetting}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      return n.getStr
  result = getEnv(ApiKeyEnvVar)

proc resolveApiBase*(opts: TalkingHeadOpts): string =
  ## Order of precedence: `opts.providerSettings.api_base`, then the
  ## `DefaultHeyGenApiBase` constant. Trailing slashes are stripped so
  ## downstream string-concatenation stays predictable.
  var base = DefaultHeyGenApiBase
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{ApiBaseSetting}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      base = n.getStr
  while base.endsWith('/'):
    base.setLen(base.len - 1)
  result = base

proc resolveStringSetting(opts: TalkingHeadOpts, key, default: string): string =
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{key}
    if not n.isNil and n.kind == JString and n.getStr.len > 0:
      return n.getStr
  result = default

proc resolveIntSetting(opts: TalkingHeadOpts, key: string, default: int): int =
  if not opts.providerSettings.isNil and opts.providerSettings.kind == JObject:
    let n = opts.providerSettings{key}
    if not n.isNil:
      case n.kind
      of JInt: return int(n.getInt)
      of JString:
        try: return parseInt(n.getStr)
        except ValueError: discard
      else: discard
  result = default

proc resolveInputText*(opts: TalkingHeadOpts): string =
  ## Read `opts.providerSettings.input_text`. HeyGen has no env-var
  ## fallback for the script — it is structurally part of the per-call
  ## payload. Returns "" when missing; the caller is expected to raise
  ## a `TalkingHeadError` in that case.
  resolveStringSetting(opts, InputTextSetting, "")

proc resolveAvatarId*(opts: TalkingHeadOpts): string =
  resolveStringSetting(opts, AvatarIdSetting, DefaultAvatarId)

proc resolveVoiceId*(opts: TalkingHeadOpts): string =
  resolveStringSetting(opts, VoiceIdSetting, DefaultVoiceId)

proc resolveWidth*(opts: TalkingHeadOpts): int =
  resolveIntSetting(opts, WidthSetting, DefaultWidth)

proc resolveHeight*(opts: TalkingHeadOpts): int =
  resolveIntSetting(opts, HeightSetting, DefaultHeight)

proc shortHashOf(s: string): string =
  ## 16-hex-char SHA-1 prefix — used to fold the HeyGen-specific knobs
  ## (input_text, avatar_id, voice_id, dimensions) into the cache-key
  ## device slot.  See `heygenCacheSalt`.
  let d = secureHash(s)
  let full = $d
  result = full[0 ..< 16].toLowerAscii

proc heygenCacheSalt*(device, inputText, avatarId, voiceId: string;
                     width, height: int): string =
  ## Per-call cache discriminator. `cacheKeyFor`'s signature is fixed
  ## by the GuiAssert contract (avatar + narration + provider + device)
  ## — for HeyGen the "avatar" is server-side (an avatar_id), and the
  ## actual narration is the `input_text` string, so we fold the
  ## HeyGen-specific knobs into the `device` slot. Two different
  ## input_text values for the same WAV therefore produce different
  ## cache entries; identical inputs short-circuit the API calls.
  ##
  ## Returned as `<device>|<sha1prefix>` so debug dumps stay legible.
  let mix = inputText & "|" & avatarId & "|" & voiceId & "|" &
            $width & "x" & $height
  result = device.toLowerAscii & "|" & shortHashOf(mix)

# ---------------------------------------------------------------------------
# HTTP client construction.
# ---------------------------------------------------------------------------

proc newHeyGenHttpClient*(apiKey: string, timeoutMs = 60_000): HttpClient =
  ## Build an `HttpClient` pre-configured with the HeyGen `X-Api-Key`
  ## header. We pin `Connection: close` so each call opens a fresh TCP
  ## socket — this sidesteps the same `std/asynchttpserver` keep-alive
  ## race the sibling D-ID plugin documents, and helps real-world
  ## upstream proxies that drop idle sockets during the polling sleep
  ## gap.
  let headers = newHttpHeaders({
    "X-Api-Key": apiKey,
    "Accept": "application/json",
    "Content-Type": "application/json",
    "User-Agent": "GuiAssert-HeyGen/0.1 (+https://github.com/metacraft-labs/GuiAssert)",
    "Connection": "close",
  })
  result = newHttpClient(timeout = timeoutMs, headers = headers)

proc closeQuietly(client: HttpClient) =
  ## Best-effort close — swallows OSError from already-closed sockets
  ## so callers don't have to wrap every defer in a try.
  try: client.close()
  except CatchableError: discard

template withFreshClient(apiKey: string, body: untyped): untyped =
  ## Build a one-shot HttpClient, run `body` with it bound to
  ## `client`, and close it afterwards. The block-scoped name makes
  ## the per-call client easy to spot vs. any long-lived provider
  ## client. Used to dodge keep-alive issues in the mock server +
  ## upstream proxies.
  block:
    let client {.inject.} = newHeyGenHttpClient(apiKey)
    try:
      body
    finally:
      closeQuietly(client)

# ---------------------------------------------------------------------------
# Low-level HTTP entry points. Each one performs exactly one HeyGen API
# call and raises `HeyGenError` on non-2xx responses. They are kept
# parameter-driven (apiBase passed in) so tests can point them at a
# localhost mock without touching globals.
# ---------------------------------------------------------------------------

proc raiseHttp(prefix: string, resp: Response) {.noreturn.} =
  ## Helper for surfacing non-2xx HTTP responses with body context.
  var body = ""
  try: body = resp.body
  except CatchableError: discard
  let excerpt =
    if body.len > 800: body[0 ..< 800] & " ...(truncated)"
    else: body
  raise newException(HeyGenError,
    prefix & ": HTTP " & resp.status & "\n" & excerpt)

proc unwrapData(parsed: JsonNode, prefix: string): JsonNode =
  ## HeyGen wraps every JSON response in `{"data": {...}, "code": 100,
  ## "message": "Success"}`. We unwrap the `data` object for the
  ## caller; the outer envelope is ignored. Raises `HeyGenError` if the
  ## envelope is missing or malformed.
  if parsed.kind != JObject:
    raise newException(HeyGenError,
      prefix & ": expected JSON object, got " & $parsed.kind & ": " & $parsed)
  let dataNode = parsed{"data"}
  if dataNode.isNil:
    raise newException(HeyGenError,
      prefix & ": response missing top-level 'data' key: " & $parsed)
  if dataNode.kind != JObject:
    raise newException(HeyGenError,
      prefix & ": expected 'data' to be a JSON object, got " &
      $dataNode.kind & ": " & $parsed)
  result = dataNode

proc generateVideo*(apiKey, apiBase: string, body: JsonNode): string =
  ## `POST /v2/video/generate`. Returns the HeyGen `video_id`. The body
  ## is whatever `buildGenerateBody` produced (the caller is free to
  ## hand-craft it for advanced flows).
  ##
  ## Each call opens a fresh `HttpClient` via the same template the
  ## polling loop uses — keep-alive races would otherwise show up as
  ## ProtocolError after the response socket is closed by the server.
  var videoId: string
  withFreshClient(apiKey):
    let url = apiBase & "/v2/video/generate"
    let resp = client.request(url, httpMethod = HttpPost, body = $body)
    if not resp.code.is2xx:
      raiseHttp("POST /v2/video/generate", resp)
    let parsed =
      try: parseJson(resp.body)
      except JsonParsingError as e:
        raise newException(HeyGenError,
          "POST /v2/video/generate: bad JSON: " & e.msg &
          "\nBody: " & resp.body)
    let data = unwrapData(parsed, "POST /v2/video/generate")
    let idNode = data{"video_id"}
    if idNode.isNil or idNode.kind != JString or idNode.getStr.len == 0:
      raise newException(HeyGenError,
        "POST /v2/video/generate: response missing data.video_id: " &
        resp.body)
    videoId = idNode.getStr
  result = videoId

proc getVideoStatusOnce*(apiKey, apiBase, videoId: string): JsonNode =
  ## Single `GET /v1/video_status.get?video_id=...` round-trip. Returns
  ## the unwrapped `data` JSON object so callers can read both
  ## `data.status` and `data.video_url` (the latter populated only when
  ## status reaches `completed`).
  ##
  ## Exposed for tests that want to inspect a single poll without the
  ## sleep loop.
  var data: JsonNode
  withFreshClient(apiKey):
    let url = apiBase & "/v1/video_status.get?video_id=" & videoId
    let resp = client.request(url, httpMethod = HttpGet)
    if not resp.code.is2xx:
      raiseHttp("GET /v1/video_status.get", resp)
    let parsed =
      try: parseJson(resp.body)
      except JsonParsingError as e:
        raise newException(HeyGenError,
          "GET /v1/video_status.get: bad JSON: " & e.msg &
          "\nBody: " & resp.body)
    data = unwrapData(parsed, "GET /v1/video_status.get")
  result = data

proc pollVideoStatus*(apiKey, apiBase, videoId: string,
                     maxSecs = DefaultMaxPollSecs,
                     intervalMs = DefaultPollIntervalMs): string =
  ## `GET /v1/video_status.get?video_id=...` until `status: completed`
  ## or `status: failed`, subject to a `maxSecs` wall-clock cap.
  ## Returns the `data.video_url` from which the rendered MP4 can be
  ## downloaded.
  let deadline = epochTime() + maxSecs
  while true:
    let data = getVideoStatusOnce(apiKey, apiBase, videoId)
    let status =
      if data{"status"}.isNil: ""
      else: data{"status"}.getStr
    case status
    of "completed":
      let urlNode = data{"video_url"}
      if urlNode.isNil or urlNode.kind != JString or urlNode.getStr.len == 0:
        raise newException(HeyGenError,
          "HeyGen video " & videoId &
          ": status=completed but no data.video_url: " & $data)
      return urlNode.getStr
    of "failed":
      raise newException(HeyGenError,
        "HeyGen video " & videoId & " failed: " & $data)
    else:
      discard
    if epochTime() >= deadline:
      raise newException(HeyGenError,
        "HeyGen video " & videoId & " did not reach status=completed within " &
        $maxSecs & "s (last status=" & status & ")")
    sleep(intervalMs)

proc downloadVideo*(videoUrl, outputPath: string) =
  ## Download the rendered MP4. The `video_url` is served from HeyGen's
  ## CDN and does NOT require the `X-Api-Key` header; we open a vanilla
  ## `HttpClient` (no auth) for the download to keep the request as
  ## plain as possible.
  let outParent = outputPath.parentDir()
  if outParent.len > 0 and not dirExists(outParent):
    createDir(outParent)
  let client = newHttpClient(timeout = 120_000,
                             headers = newHttpHeaders({
                               "User-Agent":
                                 "GuiAssert-HeyGen/0.1 (+https://github.com/metacraft-labs/GuiAssert)",
                               "Connection": "close",
                             }))
  try:
    let resp = client.request(videoUrl, httpMethod = HttpGet)
    if not resp.code.is2xx:
      raiseHttp("GET " & videoUrl, resp)
    writeFile(outputPath, resp.body)
    if not fileExists(outputPath) or getFileSize(outputPath) == 0:
      raise newException(HeyGenError,
        "HeyGen result download produced no bytes at " & outputPath)
  finally:
    closeQuietly(client)

# ---------------------------------------------------------------------------
# Provider integration. Glues the HTTP layer to GuiAssert's contract.
# ---------------------------------------------------------------------------

proc heygenIsAvailable*(): bool {.gcsafe.} =
  ## True iff a HeyGen API key is set in the environment. We can't
  ## check the per-call `opts.providerSettings.api_key` here because
  ## `isAvailable` is parameterless by contract; the provider's
  ## `generate` proc re-resolves the key (including the YAML override
  ## path) and raises a clear error if the resolved key is empty.
  getEnv(ApiKeyEnvVar).len > 0

proc heygenGenerateImpl(narrationWav, outputMp4: string,
                       opts: TalkingHeadOpts,
                       maxPollSecs: float,
                       pollIntervalMs: int) {.gcsafe.} =
  ## Real `generate` body, parameterised on the polling cadence so the
  ## mock-server test can run the full create / poll / download cycle
  ## in milliseconds. The public `generateHeyGen` proc forwards to here
  ## with the production defaults.
  ##
  ## NOTE: `narrationWav` is intentionally *not uploaded*. HeyGen v2's
  ## generate endpoint synthesises its own voice from `input_text`.
  ## We still validate the WAV exists because it is hashed into the
  ## cache key — see the module-level docstring for the rationale.
  if not fileExists(narrationWav):
    raise newException(TalkingHeadError,
      "heygen provider: narration WAV not found: " & narrationWav)

  let apiKey = resolveApiKey(opts)
  if apiKey.len == 0:
    raise newException(TalkingHeadError,
      "heygen provider: API key not set. Either export HEYGEN_API_KEY=<key> " &
      "or pass it via TalkingHeadOpts.providerSettings.api_key.")
  let apiBase = resolveApiBase(opts)
  let inputText = resolveInputText(opts)
  if inputText.len == 0:
    raise newException(TalkingHeadError,
      "heygen provider: providerSettings.input_text is required " &
      "(HeyGen synthesises its own voice from text; the narration WAV " &
      "is not uploaded). Set TalkingHeadOpts.providerSettings[\"input_text\"].")
  let avatarId = resolveAvatarId(opts)
  let voiceId = resolveVoiceId(opts)
  let width = resolveWidth(opts)
  let height = resolveHeight(opts)

  # For HeyGen the "avatar image" is purely server-side: we identify
  # it by `avatar_id`. To still benefit from GuiAssert's generic
  # `cacheKeyFor` we use the narration WAV as the only file-based
  # cache ingredient — but in practice consumers will pass distinct
  # WAVs for distinct sessions (e.g. the `say`-rendered preview audio
  # that drives the rest of the GuiAssert pipeline), so cache
  # locality is preserved.
  if not fileExists(narrationWav):
    # Double-checked above; this branch is unreachable but keeps the
    # cacheKeyFor invariant visible.
    raise newException(TalkingHeadError,
      "heygen provider: narration WAV vanished mid-call: " & narrationWav)

  let device = effectiveDevice(opts)
  let cacheDir = effectiveCacheDir(opts)
  if not dirExists(cacheDir):
    createDir(cacheDir)
  # `cacheKeyFor` insists both file paths exist. For HeyGen the
  # "avatar image" is conceptual (avatar_id is server-side), so we
  # alias narrationWav into both slots and fold the HeyGen-specific
  # knobs (input_text, avatar_id, voice_id, dimensions) into the
  # device slot via `heygenCacheSalt`. This keeps two different
  # input_text strings on the same WAV from colliding in the cache.
  let salt = heygenCacheSalt(device, inputText, avatarId, voiceId,
                            width, height)
  let key = cacheKeyFor(narrationWav, narrationWav, ProviderName, salt)

  let generator = proc() =
    let body = buildGenerateBody(inputText, avatarId, voiceId, width, height)
    let videoId = generateVideo(apiKey, apiBase, body)
    let videoUrl = pollVideoStatus(apiKey, apiBase, videoId,
                                   maxSecs = maxPollSecs,
                                   intervalMs = pollIntervalMs)
    downloadVideo(videoUrl, outputMp4)

  {.cast(gcsafe).}:
    discard applyCache(cacheDir, key, outputMp4, generator)

proc generateHeyGen*(narrationWav, outputMp4: string,
                    opts: TalkingHeadOpts) {.gcsafe.} =
  ## Production-defaults entry point. Tests that need fast polling can
  ## use `heygenProviderWithPolling` (below) to build a provider with a
  ## millisecond-interval poll, avoiding the 5-second production
  ## default.
  heygenGenerateImpl(narrationWav, outputMp4, opts,
                    DefaultMaxPollSecs, DefaultPollIntervalMs)

proc heygenProvider*(): TalkingHeadProvider =
  ## Build the HeyGen provider value with production polling defaults.
  result = TalkingHeadProvider(
    name: ProviderName,
    isAvailable: heygenIsAvailable,
    generate: generateHeyGen,
  )

proc heygenProviderWithPolling*(maxPollSecs: float,
                               pollIntervalMs: int): TalkingHeadProvider =
  ## Variant for tests: lets the mock-server suite drive the full
  ## cycle without sleeping for seconds between polls. Production
  ## callers use `heygenProvider()`.
  let captured = (maxPollSecs, pollIntervalMs)
  let gen = proc(narrationWav, outputMp4: string,
                 opts: TalkingHeadOpts) {.gcsafe.} =
    {.cast(gcsafe).}:
      heygenGenerateImpl(narrationWav, outputMp4, opts,
                        captured[0], captured[1])
  result = TalkingHeadProvider(
    name: ProviderName,
    isAvailable: heygenIsAvailable,
    generate: gen,
  )

proc registerHeyGen*(r: TalkingHeadRegistry) =
  ## One-liner plugin entry point. Callers do:
  ##
  ## ```nim
  ## import gui_assert/talking_head
  ## import gui_assert_heygen
  ##
  ## let reg = newRegistry()
  ## registerHeyGen(reg)
  ## generateTalkingHead(reg, "heygen", wav, mp4, opts)
  ## ```
  r.registerProvider(heygenProvider())
