## Unit + integration tests for the HeyGen GuiAssert plugin.
##
## ## Pure tests (always run)
##
##   * `heygenAuthHeader` produces an `HttpHeaders` carrying the
##     documented `X-Api-Key` value,
##   * `buildGenerateBody` emits the expected JSON shape,
##   * `resolveApiKey` honours providerSettings -> env-var precedence,
##   * `resolveApiBase` strips trailing slashes + defaults correctly,
##   * `resolveInputText` / `resolveAvatarId` / `resolveVoiceId` honour
##     providerSettings,
##   * `heygenProvider()` is wired up with the canonical name + non-nil
##     callbacks,
##   * `registerHeyGen` integrates with the registry,
##   * `isAvailable()` reflects the presence of `HEYGEN_API_KEY`,
##   * cache-key determinism + per-input sensitivity (different
##     `input_text` -> different key).
##
## ## Mock-server integration test (always run, no network)
##
## A `std/asynchttpserver` mock spun up on a random free localhost
## port mirrors HeyGen's `POST /v2/video/generate` +
## `GET /v1/video_status.get` + `GET /result.mp4` surface. The mock
## records every request (method, path, headers, body) so the test can
## then assert — by exact value — that the provider sent the
## `X-Api-Key` header and the JSON body shape HeyGen expects. The
## mock returns a small ffmpeg-generated MP4 as the "render result";
## the test then verifies the provider's downloaded file matches the
## mock's file byte-for-byte, and that a second invocation hits the
## on-disk cache and skips all HTTP.
##
## ## Live test (compile-time-gated via `-d:heygenLive`)
##
##   nim c -d:heygenLive -r --threads:on --hints:off \
##       --path:src --path:../GuiAssert/src tests/theygen.nim
##
## Requires `HEYGEN_API_KEY` to be set. Per project policy, the live
## suite never silently skips: a missing key is a test failure.

import std/[asynchttpserver, asyncdispatch, httpcore, json,
            net, options, os, osproc, streams, strformat, strutils,
            tables, times, unittest]

import gui_assert/talking_head
import gui_assert_heygen

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

proc thisRepoRoot(): string =
  ## `currentSourcePath` -> .../GuiAssert-HeyGen/tests/theygen.nim
  currentSourcePath().parentDir().parentDir()

# ---------------------------------------------------------------------------
# Fixture synthesis (also used by the mock server's result MP4).
# ---------------------------------------------------------------------------

proc runSh(args: openArray[string]): tuple[code: int, output: string] =
  let bin = findExe(args[0])
  doAssert bin.len > 0, "binary not on PATH: " & args[0]
  var rest: seq[string] = @[]
  for i in 1 ..< args.len: rest.add args[i]
  let p = startProcess(
    command = bin, args = rest, options = {poStdErrToStdOut}
  )
  let raw = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  result = (code: code, output: raw)

proc bundledNarration(): string =
  let p = thisRepoRoot() / "tests" / "fixtures" / "narration.wav"
  doAssert fileExists(p), "missing narration fixture: " & p
  p

proc ensureMockMp4(): string =
  ## Produce a small testsrc MP4 (~3 s, ~30 KB) that the mock server
  ## serves as the `video_url` payload. Synthesised once per test run
  ## under /tmp to keep the repo clean.
  let target = "/tmp/theygen-mock-result.mp4"
  if fileExists(target) and getFileSize(target) > 5_000:
    return target
  let ffBin =
    block:
      let env = getEnv("FFMPEG_BIN")
      if env.len > 0 and fileExists(env): env
      else: findExe("ffmpeg")
  doAssert ffBin.len > 0, "ffmpeg missing on PATH; needed by the mock server"
  if fileExists(target): removeFile(target)
  let r = runSh([ffBin, "-hide_banner", "-loglevel", "error", "-y",
                 "-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=25",
                 "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                 "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "64k", "-shortest", target])
  doAssert r.code == 0, "ffmpeg mock MP4 synthesis failed: " & r.output
  result = target

# ---------------------------------------------------------------------------
# Pure tests
# ---------------------------------------------------------------------------

suite "heygen auth header":

  test "produces an X-Api-Key header carrying the raw key":
    let h = heygenAuthHeader("foo")
    check h.hasKey("X-Api-Key")
    check h["X-Api-Key"] == "foo"

  test "pins Content-Type: application/json alongside":
    let h = heygenAuthHeader("DUMMY_KEY")
    check h["X-Api-Key"] == "DUMMY_KEY"
    check h["Content-Type"] == "application/json"

  test "does not include any Authorization header":
    # HeyGen uses a single X-Api-Key header — NOT HTTP Basic auth like
    # the sibling D-ID plugin. Regression guard: callers / proxies
    # that sniff Authorization must not see one here.
    let h = heygenAuthHeader("any-key")
    check (not h.hasKey("Authorization"))

suite "heygen generate body":

  test "builds the documented v2 JSON shape":
    let body = buildGenerateBody("Hello, this is HeyGen.",
                                 "Daisy-inskirt-20220818",
                                 "1bd001e7e50f421d891986aad5158bc8")
    check body.kind == JObject
    let videoInputs = body["video_inputs"]
    check videoInputs.kind == JArray
    check videoInputs.len == 1
    let entry = videoInputs[0]
    check entry["character"]["type"].getStr == "avatar"
    check entry["character"]["avatar_id"].getStr == "Daisy-inskirt-20220818"
    check entry["character"]["avatar_style"].getStr == "normal"
    check entry["voice"]["type"].getStr == "text"
    check entry["voice"]["input_text"].getStr == "Hello, this is HeyGen."
    check entry["voice"]["voice_id"].getStr ==
      "1bd001e7e50f421d891986aad5158bc8"
    check body["dimension"]["width"].getInt == DefaultWidth
    check body["dimension"]["height"].getInt == DefaultHeight

  test "honours explicit width/height":
    let body = buildGenerateBody("hello", "Daisy-1", "voice-1", 1920, 1080)
    check body["dimension"]["width"].getInt == 1920
    check body["dimension"]["height"].getInt == 1080
    check body["video_inputs"][0]["character"]["avatar_id"].getStr == "Daisy-1"
    check body["video_inputs"][0]["voice"]["voice_id"].getStr == "voice-1"
    check body["video_inputs"][0]["voice"]["input_text"].getStr == "hello"

suite "heygen opts resolution":

  test "resolveApiKey prefers providerSettings over env":
    putEnv(ApiKeyEnvVar, "ENV_KEY")
    let opts = TalkingHeadOpts(
      providerSettings: %*{"api_key": "OPTS_KEY"}
    )
    check resolveApiKey(opts) == "OPTS_KEY"
    delEnv(ApiKeyEnvVar)

  test "resolveApiKey falls back to env when providerSettings empty":
    putEnv(ApiKeyEnvVar, "ENV_ONLY")
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveApiKey(opts) == "ENV_ONLY"
    delEnv(ApiKeyEnvVar)

  test "resolveApiKey returns empty when neither set":
    delEnv(ApiKeyEnvVar)
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveApiKey(opts) == ""

  test "resolveApiBase strips trailing slashes":
    let opts = TalkingHeadOpts(
      providerSettings: %*{"api_base": "http://x.test:9000///"}
    )
    check resolveApiBase(opts) == "http://x.test:9000"

  test "resolveApiBase defaults to the public HeyGen endpoint":
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveApiBase(opts) == DefaultHeyGenApiBase
    check DefaultHeyGenApiBase == "https://api.heygen.com"

  test "resolveInputText reads providerSettings.input_text":
    let opts = TalkingHeadOpts(
      providerSettings: %*{"input_text": "Hello world."}
    )
    check resolveInputText(opts) == "Hello world."

  test "resolveInputText returns empty when missing":
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveInputText(opts) == ""

  test "resolveAvatarId / resolveVoiceId default to documented IDs":
    let opts = TalkingHeadOpts(providerSettings: newJObject())
    check resolveAvatarId(opts) == DefaultAvatarId
    check resolveVoiceId(opts) == DefaultVoiceId
    check DefaultAvatarId == "Daisy-inskirt-20220818"
    check DefaultVoiceId == "1bd001e7e50f421d891986aad5158bc8"

  test "resolveAvatarId / resolveVoiceId read providerSettings overrides":
    let opts = TalkingHeadOpts(
      providerSettings: %*{
        "avatar_id": "Custom-Avatar-1",
        "voice_id": "voice-xyz"
      }
    )
    check resolveAvatarId(opts) == "Custom-Avatar-1"
    check resolveVoiceId(opts) == "voice-xyz"

  test "resolveWidth / resolveHeight accept int or string forms":
    let optsInt = TalkingHeadOpts(
      providerSettings: %*{"width": 1920, "height": 1080}
    )
    check resolveWidth(optsInt) == 1920
    check resolveHeight(optsInt) == 1080
    let optsStr = TalkingHeadOpts(
      providerSettings: %*{"width": "640", "height": "360"}
    )
    check resolveWidth(optsStr) == 640
    check resolveHeight(optsStr) == 360

suite "heygen provider value":

  test "heygenProvider builds a provider with the canonical name":
    let p = heygenProvider()
    check p.name == ProviderName
    check p.name == "heygen"
    check (not p.isAvailable.isNil)
    check (not p.generate.isNil)

  test "registerHeyGen exposes the plugin via the registry":
    let r = newRegistry()
    check (not hasProvider(r, "heygen"))
    registerHeyGen(r)
    check hasProvider(r, "heygen")
    let got = getProvider(r, "heygen")
    check got.name == "heygen"
    # Built-in stock_avatar must remain registered.
    check hasProvider(r, "stock_avatar")

suite "heygen isAvailable":

  test "returns false when HEYGEN_API_KEY is unset":
    delEnv(ApiKeyEnvVar)
    check (not heygenIsAvailable())

  test "returns true when HEYGEN_API_KEY is set":
    putEnv(ApiKeyEnvVar, "anything-nonempty")
    check heygenIsAvailable()
    delEnv(ApiKeyEnvVar)

suite "heygen cache key":

  setup:
    let cacheTmp = getTempDir() / "theygen_cachekey"
    if dirExists(cacheTmp): removeDir(cacheTmp)
    createDir(cacheTmp)
    let nar1 = cacheTmp / "n1.wav"
    let nar2 = cacheTmp / "n2.wav"
    writeFile(nar1, "RIFF-A")
    writeFile(nar2, "RIFF-B")

  test "same inputs (same salt) produce the same key":
    let salt = heygenCacheSalt("auto", "hello", DefaultAvatarId,
                              DefaultVoiceId, 1280, 720)
    let k1 = cacheKeyFor(nar1, nar1, ProviderName, salt)
    let k2 = cacheKeyFor(nar1, nar1, ProviderName, salt)
    check k1 == k2
    check k1.len == 16

  test "different narration WAV -> different key":
    let salt = heygenCacheSalt("auto", "hello", DefaultAvatarId,
                              DefaultVoiceId, 1280, 720)
    let k1 = cacheKeyFor(nar1, nar1, ProviderName, salt)
    let k2 = cacheKeyFor(nar2, nar2, ProviderName, salt)
    check k1 != k2

  test "different input_text -> different cache-salt -> different key":
    let saltA = heygenCacheSalt("auto", "Hello.", DefaultAvatarId,
                               DefaultVoiceId, 1280, 720)
    let saltB = heygenCacheSalt("auto", "Goodbye.", DefaultAvatarId,
                               DefaultVoiceId, 1280, 720)
    check saltA != saltB
    let k1 = cacheKeyFor(nar1, nar1, ProviderName, saltA)
    let k2 = cacheKeyFor(nar1, nar1, ProviderName, saltB)
    check k1 != k2

  test "different avatar_id -> different cache-salt -> different key":
    let saltA = heygenCacheSalt("auto", "hello", "Avatar-A",
                               DefaultVoiceId, 1280, 720)
    let saltB = heygenCacheSalt("auto", "hello", "Avatar-B",
                               DefaultVoiceId, 1280, 720)
    check saltA != saltB
    let k1 = cacheKeyFor(nar1, nar1, ProviderName, saltA)
    let k2 = cacheKeyFor(nar1, nar1, ProviderName, saltB)
    check k1 != k2

  test "different voice_id -> different cache-salt -> different key":
    let saltA = heygenCacheSalt("auto", "hello", DefaultAvatarId,
                               "Voice-A", 1280, 720)
    let saltB = heygenCacheSalt("auto", "hello", DefaultAvatarId,
                               "Voice-B", 1280, 720)
    check saltA != saltB
    let k1 = cacheKeyFor(nar1, nar1, ProviderName, saltA)
    let k2 = cacheKeyFor(nar1, nar1, ProviderName, saltB)
    check k1 != k2

  test "different dimensions -> different cache-salt -> different key":
    let saltA = heygenCacheSalt("auto", "hello", DefaultAvatarId,
                               DefaultVoiceId, 1280, 720)
    let saltB = heygenCacheSalt("auto", "hello", DefaultAvatarId,
                               DefaultVoiceId, 1920, 1080)
    check saltA != saltB
    let k1 = cacheKeyFor(nar1, nar1, ProviderName, saltA)
    let k2 = cacheKeyFor(nar1, nar1, ProviderName, saltB)
    check k1 != k2

suite "heygen generate input validation":

  test "missing API key raises TalkingHeadError at generate time":
    delEnv(ApiKeyEnvVar)
    let p = heygenProvider()
    let tmp = getTempDir() / "theygen_no_key"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let nar = tmp / "n.wav"
    writeFile(nar, "RIFF")
    let outMp4 = tmp / "out.mp4"
    let opts = TalkingHeadOpts(
      cacheDir: some(tmp / "cache"),
      providerSettings: %*{"input_text": "hi"},
    )
    expect TalkingHeadError:
      p.generate(nar, outMp4, opts)

  test "missing input_text raises TalkingHeadError at generate time":
    putEnv(ApiKeyEnvVar, "DUMMY")
    try:
      let p = heygenProvider()
      let tmp = getTempDir() / "theygen_no_input_text"
      if dirExists(tmp): removeDir(tmp)
      createDir(tmp)
      let nar = tmp / "n.wav"
      writeFile(nar, "RIFF")
      let outMp4 = tmp / "out.mp4"
      let opts = TalkingHeadOpts(
        cacheDir: some(tmp / "cache"),
        providerSettings: newJObject(),
      )
      expect TalkingHeadError:
        p.generate(nar, outMp4, opts)
    finally:
      delEnv(ApiKeyEnvVar)

  test "missing narration WAV raises TalkingHeadError":
    putEnv(ApiKeyEnvVar, "DUMMY")
    try:
      let p = heygenProvider()
      let tmp = getTempDir() / "theygen_no_wav"
      if dirExists(tmp): removeDir(tmp)
      createDir(tmp)
      let outMp4 = tmp / "out.mp4"
      let opts = TalkingHeadOpts(
        cacheDir: some(tmp / "cache"),
        providerSettings: %*{"input_text": "hi"},
      )
      expect TalkingHeadError:
        p.generate(tmp / "does-not-exist.wav", outMp4, opts)
    finally:
      delEnv(ApiKeyEnvVar)

# ---------------------------------------------------------------------------
# Mock-server integration test (no network).
# ---------------------------------------------------------------------------

type
  RecordedRequest = object
    httpMethod: string
    path: string
    query: string
    apiKeyHeader: string
    contentType: string
    body: string

# Shared global state for the mock server. asynchttpserver's request
# handler is a `proc(req): Future[void]`, which can't easily close
# over per-test locals when we're also pinning -d:taintMode. Globals
# in test code are the path of least resistance.
var mockRequests: seq[RecordedRequest]
var mockResultMp4Path: string
var mockPollCount: int
var mockPollsBeforeDone: int
var mockServerPort: int

proc firstHeader(h: HttpHeaders, name: string): string =
  if h.hasKey(name):
    let vals = h.table[name.toLowerAscii]
    if vals.len > 0: return vals[0]
  return ""

proc mockHandler(req: Request): Future[void] {.async, gcsafe.} =
  {.cast(gcsafe).}:
    var rec = RecordedRequest(
      httpMethod: $req.reqMethod,
      path: req.url.path,
      query: req.url.query,
      apiKeyHeader: firstHeader(req.headers, "x-api-key"),
      contentType: firstHeader(req.headers, "content-type"),
      body: req.body,
    )
    mockRequests.add rec

    let m = req.reqMethod
    let p = req.url.path
    let portStr = $mockServerPort

    if m == HttpPost and p == "/v2/video/generate":
      let payload = %*{
        "data": {"video_id": "vid_TEST"},
        "code": 100,
        "message": "Success"
      }
      await req.respond(Http200, $payload,
                        newHttpHeaders({"Content-Type": "application/json"}))
      return

    if m == HttpGet and p == "/v1/video_status.get":
      mockPollCount.inc
      if mockPollCount <= mockPollsBeforeDone:
        let payload = %*{
          "data": {"status": "processing"},
          "code": 100,
          "message": "Success"
        }
        await req.respond(Http200, $payload,
                          newHttpHeaders({"Content-Type": "application/json"}))
      else:
        let payload = %*{
          "data": {
            "status": "completed",
            "video_url": "http://localhost:" & portStr & "/result.mp4"
          },
          "code": 100,
          "message": "Success"
        }
        await req.respond(Http200, $payload,
                          newHttpHeaders({"Content-Type": "application/json"}))
      return

    if m == HttpGet and p == "/result.mp4":
      let bytes = readFile(mockResultMp4Path)
      await req.respond(Http200, bytes,
                        newHttpHeaders({"Content-Type": "video/mp4"}))
      return

    await req.respond(Http404, "mock: no route for " & $m & " " & p,
                      newHttpHeaders({"Content-Type": "text/plain"}))

proc pickFreePort(): int =
  ## Bind to port 0 to let the OS allocate a free port, then close
  ## the socket and reuse the number. There's a tiny race window
  ## before the asynchttpserver claims the port, but it's good enough
  ## for a single-test-run mock and avoids hardcoding ports that
  ## might collide on CI.
  let s = newSocket()
  s.bindAddr(Port(0))
  let (_, port) = s.getLocalAddr
  s.close()
  result = int(port)

var mockServerThread: Thread[int]
var mockServerStopFlag: bool

proc mockServerThreadProc(port: int) {.thread.} =
  {.cast(gcsafe).}:
    let server = newAsyncHttpServer()
    asyncCheck server.serve(Port(port), mockHandler, address = "127.0.0.1")
    while not mockServerStopFlag:
      # Drive the asyncdispatch loop on this dedicated thread so the
      # main thread can issue blocking httpclient calls.
      poll(50)
    server.close()

proc startMockServer(): tuple[port: int, stop: proc() {.gcsafe.}] =
  let port = pickFreePort()
  mockServerPort = port
  mockRequests = @[]
  mockPollCount = 0
  mockServerStopFlag = false
  createThread(mockServerThread, mockServerThreadProc, port)
  # Give the server thread a moment to bind + start serving before we
  # let the caller fire requests at it.
  sleep(150)
  let stop = proc() {.gcsafe.} =
    mockServerStopFlag = true
    joinThread(mockServerThread)
  result = (port: port, stop: stop)

suite "heygen mock-server integration":

  test "creates + polls + downloads through a local mock and caches the result":
    let narration = bundledNarration()
    let resultMp4 = ensureMockMp4()
    mockResultMp4Path = resultMp4
    mockPollsBeforeDone = 2  # /v1/video_status.get returns processing twice

    let (port, stop) = startMockServer()
    defer: stop()

    let portStr = $port
    echo &"  mock server listening on http://localhost:{portStr}"

    # Provider with millisecond polling so the test runs fast.
    let provider = heygenProviderWithPolling(maxPollSecs = 30.0,
                                              pollIntervalMs = 50)

    let tmp = getTempDir() / "theygen_mock"
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    let outMp4 = tmp / "heygen-mock.mp4"
    let opts = TalkingHeadOpts(
      device: "auto",
      cacheDir: some(tmp / "cache"),
      providerSettings: %*{
        "api_base": "http://localhost:" & portStr,
        "api_key": "DUMMY_KEY",
        "input_text": "Hello from GuiAssert HeyGen mock test.",
        "avatar_id": "Daisy-inskirt-20220818",
        "voice_id": "1bd001e7e50f421d891986aad5158bc8",
        "width": 1280,
        "height": 720,
      },
    )

    let started = epochTime()
    provider.generate(narration, outMp4, opts)
    let dt = epochTime() - started
    echo &"  full mock round-trip took {dt*1000:.1f} ms"

    # ----- Recorded-request trace -----
    echo "  recorded requests (", $mockRequests.len, "):"
    for i, r in mockRequests:
      let bodyPreview =
        if r.body.len <= 240: r.body
        else: r.body[0 ..< 240] & " ...(+" & $(r.body.len - 240) & " bytes)"
      echo &"    [{i}] {r.httpMethod} {r.path} ?{r.query}"
      echo &"        X-Api-Key: {r.apiKeyHeader}"
      echo &"        Content-Type: {r.contentType}"
      echo &"        body[{r.body.len}]: {bodyPreview}"

    # ----- Assertion checks -----
    # With mockPollsBeforeDone=2 the trace is:
    #   [0] POST /v2/video/generate
    #   [1] GET  /v1/video_status.get?video_id=vid_TEST  (status=processing)
    #   [2] GET  /v1/video_status.get?video_id=vid_TEST  (status=processing)
    #   [3] GET  /v1/video_status.get?video_id=vid_TEST  (status=completed)
    #   [4] GET  /result.mp4
    check mockRequests.len == 5

    check mockRequests[0].httpMethod == "POST"
    check mockRequests[0].path == "/v2/video/generate"
    check mockRequests[1].httpMethod == "GET"
    check mockRequests[1].path == "/v1/video_status.get"
    check mockRequests[1].query == "video_id=vid_TEST"
    check mockRequests[2].httpMethod == "GET"
    check mockRequests[2].path == "/v1/video_status.get"
    check mockRequests[2].query == "video_id=vid_TEST"
    check mockRequests[3].httpMethod == "GET"
    check mockRequests[3].path == "/v1/video_status.get"
    check mockRequests[3].query == "video_id=vid_TEST"
    check mockRequests[4].httpMethod == "GET"
    check mockRequests[4].path == "/result.mp4"

    # ----- X-Api-Key header exact-string check on every API request -----
    # The /result.mp4 download is served from the CDN and the plugin
    # intentionally does NOT send the auth header for it. Validate
    # that distinction here.
    for i in 0..3:
      check mockRequests[i].apiKeyHeader == "DUMMY_KEY"
    check mockRequests[4].apiKeyHeader == ""

    # ----- POST /v2/video/generate JSON body shape -----
    check mockRequests[0].contentType == "application/json"
    let createBody = parseJson(mockRequests[0].body)
    check createBody.kind == JObject
    let videoInputs = createBody["video_inputs"]
    check videoInputs.kind == JArray
    check videoInputs.len == 1
    let entry = videoInputs[0]
    check entry["character"]["type"].getStr == "avatar"
    check entry["character"]["avatar_id"].getStr ==
      "Daisy-inskirt-20220818"
    check entry["character"]["avatar_style"].getStr == "normal"
    check entry["voice"]["type"].getStr == "text"
    check entry["voice"]["input_text"].getStr ==
      "Hello from GuiAssert HeyGen mock test."
    check entry["voice"]["voice_id"].getStr ==
      "1bd001e7e50f421d891986aad5158bc8"
    check createBody["dimension"]["width"].getInt == 1280
    check createBody["dimension"]["height"].getInt == 720

    # ----- Poll GETs have empty body -----
    for i in 1..3:
      check mockRequests[i].body.len == 0

    # ----- Polling cadence respected: 3 polls happened (2 processing + 1 done) -----
    check mockPollCount == 3
    # And the wall-clock should be at least 2 * intervalMs (50 ms) =
    # 100 ms, evidencing that the polling loop did NOT short-circuit.
    check dt >= 0.100

    # ----- Download produced a byte-identical MP4 -----
    check fileExists(outMp4)
    let downloaded = readFile(outMp4)
    let golden = readFile(resultMp4)
    check downloaded.len == golden.len
    check downloaded == golden
    echo &"  downloaded MP4 = {downloaded.len} bytes; matches mock-served golden"

    # ----- Cache hit on the second invocation skips all HTTP -----
    let beforeCount = mockRequests.len
    let outMp4_2 = tmp / "heygen-mock-2.mp4"
    let secondStart = epochTime()
    provider.generate(narration, outMp4_2, opts)
    let secondDt = epochTime() - secondStart
    echo &"  cache-hit second call took {secondDt*1000:.1f} ms"
    check mockRequests.len == beforeCount  # no new HTTP traffic
    check fileExists(outMp4_2)
    check getFileSize(outMp4_2) == golden.len
    check readFile(outMp4_2) == golden

    # ----- Cache miss when input_text changes -----
    let outMp4_3 = tmp / "heygen-mock-3.mp4"
    var optsDifferent = opts
    optsDifferent.providerSettings = %*{
      "api_base": "http://localhost:" & portStr,
      "api_key": "DUMMY_KEY",
      "input_text": "A completely different script.",
      "avatar_id": "Daisy-inskirt-20220818",
      "voice_id": "1bd001e7e50f421d891986aad5158bc8",
      "width": 1280,
      "height": 720,
    }
    mockPollCount = 0  # reset so the third invocation polls again
    provider.generate(narration, outMp4_3, optsDifferent)
    # New input_text -> different cache key -> 5 fresh requests
    # (POST + 3 status polls + result download).
    check mockRequests.len == beforeCount + 5
    check fileExists(outMp4_3)
    # The mock always returns the same MP4, but the cache entry is
    # NEW: a separate file in the cache dir with a different name.
    let createBody2 = parseJson(mockRequests[beforeCount].body)
    check createBody2["video_inputs"][0]["voice"]["input_text"].getStr ==
      "A completely different script."

# ---------------------------------------------------------------------------
# Live test — compile-time-gated. Real HeyGen API.
# ---------------------------------------------------------------------------
when defined(heygenLive):

  proc ffprobeJson(path: string): JsonNode =
    let ffprobe =
      block:
        let env = getEnv("FFPROBE_BIN")
        if env.len > 0 and fileExists(env): env
        else: findExe("ffprobe")
    doAssert ffprobe.len > 0 and fileExists(ffprobe),
      "ffprobe not on PATH; install ffmpeg to run the live HeyGen test."
    let p = startProcess(
      command = ffprobe,
      args = @["-hide_banner", "-v", "error", "-print_format", "json",
               "-show_streams", "-show_format", path],
      options = {poStdErrToStdOut}
    )
    let raw = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    doAssert code == 0, "ffprobe failed (" & $code & "): " & raw
    parseJson(raw)

  proc ensureLiveNarration(): string =
    let envOverride = getEnv("GUI_ASSERT_HEYGEN_TEST_WAV")
    if envOverride.len > 0:
      doAssert fileExists(envOverride),
        "GUI_ASSERT_HEYGEN_TEST_WAV points at a non-existent path: " &
        envOverride
      return envOverride
    let bundled = thisRepoRoot() / "tests" / "fixtures" / "narration.wav"
    doAssert fileExists(bundled),
      "no narration fixture at " & bundled &
      " (set GUI_ASSERT_HEYGEN_TEST_WAV to override)"
    result = bundled

  suite "heygen live render against api.heygen.com":

    test "renders a real talking-head MP4 via the HeyGen API":
      doAssert getEnv(ApiKeyEnvVar).len > 0,
        "HEYGEN_API_KEY is not set. Live HeyGen tests require a real " &
        "API key from https://app.heygen.com (pay-as-you-go since Feb " &
        "2026; no free API tier). Export HEYGEN_API_KEY=<your key> " &
        "and re-run with -d:heygenLive."

      let narration = ensureLiveNarration()

      let tmp = getTempDir() / "theygen_live"
      if dirExists(tmp): removeDir(tmp)
      createDir(tmp)

      let r = newRegistry()
      registerHeyGen(r)

      let outMp4 = tmp / "live.mp4"
      let opts = TalkingHeadOpts(
        device: "auto",
        cacheDir: some(tmp / "cache"),
        providerSettings: %*{
          "input_text": "Hello GuiAssert HeyGen",
          "avatar_id": DefaultAvatarId,
          "voice_id": DefaultVoiceId,
        },
        extraArgs: @[],
      )

      let started = epochTime()
      generateTalkingHead(r, "heygen", narration, outMp4, opts)
      let dt = epochTime() - started
      echo &"  live HeyGen render took {dt:.1f}s"

      doAssert fileExists(outMp4), "no MP4 at " & outMp4
      let sz = getFileSize(outMp4)
      echo &"  output: {sz} bytes"
      check sz > 50_000

      let probe = ffprobeJson(outMp4)
      var hasVideo = false
      var hasAudio = false
      for s in probe{"streams"}.items:
        let kind = s{"codec_type"}.getStr()
        if kind == "video": hasVideo = true
        elif kind == "audio": hasAudio = true
      check hasVideo
      check hasAudio

      let videoDur = parseFloat(probe{"format", "duration"}.getStr())
      echo &"  talking-head dur: {videoDur:.3f}s"
      check videoDur > 1.0

      # Cache hit — second call must be near-instant.
      let secondStart = epochTime()
      let outMp4_2 = tmp / "live2.mp4"
      generateTalkingHead(r, "heygen", narration, outMp4_2, opts)
      let secondDt = epochTime() - secondStart
      echo &"  second call (cache hit) took {secondDt:.3f}s"
      check secondDt < 5.0
      check fileExists(outMp4_2)
      check getFileSize(outMp4_2) == getFileSize(outMp4)
