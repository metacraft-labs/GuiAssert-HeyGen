# GuiAssert-HeyGen

HeyGen talking-head plugin for [GuiAssert]. Implements GuiAssert's
`TalkingHeadProvider` contract by speaking the commercial
[HeyGen v2 REST API](https://docs.heygen.com/reference/create-an-avatar-video-v2)
— no Python, no model weights, no GPU toolchain. Pure-Nim HTTP client.

HeyGen is a commercial talking-head / avatar-video service. Compared
with the local-ML siblings (`GuiAssert-Wav2Lip`, `GuiAssert-MuseTalk`,
`GuiAssert-SadTalker`) and the sibling commercial plugin
(`GuiAssert-Did`), it trades a recurring per-minute fee for zero
install cost and zero local compute.

[GuiAssert]: ../GuiAssert/

## Layout

```
GuiAssert-HeyGen/
├── flake.nix                            nim + ffmpeg-full + openssl + cacert devShell (no Python)
├── gui_assert_heygen.nimble             nimble package
├── src/
│   └── gui_assert_heygen.nim            plugin implementation (TalkingHeadProvider)
└── tests/
    ├── fixtures/
    │   ├── README.md                    fixture provenance
    │   └── narration.wav                ~3.5 s test WAV (cache-key ingredient only)
    └── theygen.nim                      pure + mock-server tests + `-d:heygenLive` gated live test
```

## Cost of setup

| Resource     | Approx.                                                |
| ------------ | ------------------------------------------------------ |
| Disk         | None beyond Nim build artefacts                        |
| Network      | Per-render JSON + MP4 download, modest                 |
| Time         | First call ~30 s – minutes (renders are slow)          |
| Dollars      | **$1 – $4 per minute** of generated video, pay-as-you-go.<br/>No free API tier since February 2026 — the legacy free tier was retired.<br/>API plans cap concurrent generations at 10. |
| API key      | Yes — `HEYGEN_API_KEY` env var                         |

Pricing is set by HeyGen; see [their pricing page](https://www.heygen.com/pricing)
for current numbers. Costs accrue per minute of *generated* video,
not per API call, so the cache hit-rate matters — see
[Caching](#caching) below.

## Setup

```sh
nix develop
export HEYGEN_API_KEY="..."   # from https://app.heygen.com → Settings → API
```

No install script. No model weights. The `nix develop` shell
provisions Nim, ffmpeg (for fixture synthesis + ffprobe validation),
OpenSSL, and a CA bundle so TLS to `api.heygen.com` works without
user setup.

## Important deviation from the generic contract

GuiAssert's `TalkingHeadProvider.generate` contract is
`generate(narrationWav, outputMp4, opts)` — i.e. the audio is provided
as a *pre-rendered WAV*. HeyGen v2's `video/generate` endpoint does
NOT accept uploaded audio in its default mode: it takes an
`input_text` string plus a `voice_id` and synthesises the voiceover
itself. This plugin therefore:

- IGNORES the `narrationWav` parameter for the actual API call.
- REQUIRES `opts.providerSettings["input_text"]` to be set to the
  string HeyGen should speak. `generate` raises `TalkingHeadError`
  if missing or empty.

The `narrationWav` is still incorporated into the on-disk cache key,
so consumers can carry per-session uniqueness in the WAV (e.g. by
passing a unique audio file per render call). The cache key also
folds in `input_text`, `avatar_id`, `voice_id`, and the requested
dimensions, so two different scripts on the same WAV do not
collide.

A future variant could speak HeyGen's `audio_url` mode (uploading
the WAV via `/v1/upload.url` first, then referencing it) to honour
the WAV verbatim. The current plugin keeps the simpler `text` voice
mode.

## Wiring into a runner

```nim
import gui_assert/talking_head
import gui_assert_heygen

let reg = newRegistry()         # registry pre-populated with `stock_avatar`
registerHeyGen(reg)             # now `heygen` is also registered

var opts = TalkingHeadOpts(
  avatarImagePath: none(string),    # unused by HeyGen (avatar is server-side)
  device: "auto",
  cacheDir: some("/tmp/heygen-cache"),
  providerSettings: %*{
    "input_text": "Hello from GuiAssert HeyGen.",
    "avatar_id": "Daisy-inskirt-20220818",      # public stock avatar
    "voice_id": "1bd001e7e50f421d891986aad5158bc8",
    # api_key falls back to $HEYGEN_API_KEY
  },
)
generateTalkingHead(reg, "heygen", narrationWav, outputMp4, opts)
```

### Configuration

All knobs live under `TalkingHeadOpts.providerSettings` (a `JsonNode`),
with environment-variable fallbacks where applicable:

| Setting | YAML key | Env fallback | Default | Purpose |
| --- | --- | --- | --- | --- |
| `api_key` | `api_key` | `HEYGEN_API_KEY` | _(none)_ | HeyGen API key. |
| `api_base` | `api_base` | _(none)_ | `https://api.heygen.com` | API endpoint. Override to point at a mock or staging server. |
| `input_text` | `input_text` | _(none)_ | _(none)_ | **REQUIRED.** Script for HeyGen to speak. |
| `avatar_id` | `avatar_id` | _(none)_ | `Daisy-inskirt-20220818` | HeyGen avatar identifier (public stock or custom). |
| `voice_id` | `voice_id` | _(none)_ | `1bd001e7e50f421d891986aad5158bc8` | HeyGen voice identifier. |
| `width` | `width` | _(none)_ | `1280` | Output width in pixels. |
| `height` | `height` | _(none)_ | `720` | Output height in pixels. |

The provider name is `"heygen"`.

## API flow

The provider performs three sequential interactions per render (plus
poll round-trips):

1. `POST /v2/video/generate` — JSON body of the form documented in
   HeyGen's quick-start:
   ```json
   {
     "video_inputs": [{
       "character": {
         "type": "avatar",
         "avatar_id": "Daisy-inskirt-20220818",
         "avatar_style": "normal"
       },
       "voice": {
         "type": "text",
         "input_text": "Hello, this is HeyGen.",
         "voice_id": "1bd001e7e50f421d891986aad5158bc8"
       }
     }],
     "dimension": {"width": 1280, "height": 720}
   }
   ```
   The response is wrapped in `{"data": {"video_id": "..."}, "code":
   100, "message": "Success"}`. The plugin unwraps the `data` envelope
   and reads `video_id`.
2. `GET /v1/video_status.get?video_id=...` — polled every 5 s
   (10-minute timeout) until `data.status == "completed"`.
3. `GET <data.video_url>` — downloads the MP4 to disk. The CDN URL
   does not require the `X-Api-Key` header.

Authentication uses the HeyGen-specific single header
`X-Api-Key: <HEYGEN_API_KEY>`. (Notably *not* HTTP Basic auth like
the sibling D-ID plugin.)

## Caching

The plugin reuses GuiAssert's generic on-disk cache
(`applyCache` + `cacheKeyFor`). Because HeyGen's "avatar" is purely
server-side (an `avatar_id` string, not a local file) and its
"narration" is purely server-side too (an `input_text` string,
synthesised remotely), the cache key folds the HeyGen-specific knobs
(`input_text`, `avatar_id`, `voice_id`, `width`, `height`) into the
device slot via a SHA-1 prefix. Identical inputs short-circuit the
API calls entirely on the second invocation. This is doubly important
here because every cache hit avoids spending real money.

The mock-server test validates the cache-hit path: a second
`generate` call against the same inputs issues zero HTTP requests.

## Tests

```sh
# Pure unit tests + mock-server integration test — no network.
nim c -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/theygen.nim

# Live end-to-end against api.heygen.com — requires HEYGEN_API_KEY.
nim c -d:heygenLive -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/theygen.nim
```

The `--threads:on` flag is required because the mock-server test
spawns a thread that drives `asyncdispatch.poll()` while the main
thread issues blocking `std/httpclient` calls.

The mock-server suite spins up a `std/asynchttpserver` on a random
localhost port, records every request the provider issues (method,
path, headers, body), and asserts:

- Every API request carries the `X-Api-Key` header set to the test
  key (`DUMMY_KEY`).
- `POST /v2/video/generate` carries exactly the JSON shape HeyGen
  documents (`video_inputs[0].character.avatar_id`,
  `video_inputs[0].voice.input_text`, `dimension.width/height`).
- Polling cadence is respected (the provider does not short-circuit
  while status is `processing`).
- The downloaded MP4 is byte-identical to the mock's golden file.
- A second call hits the on-disk cache and issues zero HTTP traffic.

The live test fails the run if `HEYGEN_API_KEY` is missing — per
project policy, there are no graceful skips. CI that does not want
to spend real HeyGen credit simply compiles without `-d:heygenLive`.

## License

MIT — see `LICENSE`. HeyGen itself is a commercial service governed
by its own [terms of service](https://www.heygen.com/policy/terms-of-service);
the plugin only speaks the public REST API.
