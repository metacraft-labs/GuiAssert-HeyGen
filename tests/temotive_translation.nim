## Pure tests for HeyGen emotive translation + dry-run helpers.
##
## The mock-server discovery test lives in `theygen.nim`'s mock-
## server suite; this file focuses on the pure projection helpers
## that consume a `CommonEmotiveConfig` and emit JSON sub-trees the
## generate path consumes.

import std/[json, options, strutils, unittest]
import gui_assert/talking_head, gui_assert/emotive
import gui_assert_heygen

suite "HeyGen emotiveToProviderSettings":

  test "fully populated config projects every supported key":
    var c = initEmotive()
    c.voiceSpeed = some(1.1)
    c.voicePitch = some(-2.0)
    c.emotion = some(eExcited)
    c.background = some(bmGreenScreen)
    c.backgroundColor = some("#22ff22")
    let j = emotiveToProviderSettings(c)
    check j["voice_speed"].getFloat == 1.1
    check j["voice_pitch"].getFloat == -2.0
    check j["emotion"].getStr == "Excited"
    check j["background"].getStr == "green_screen"
    check j["background_color"].getStr == "#22ff22"

  test "missing emotive fields produce an empty projection":
    let c = initEmotive()
    let j = emotiveToProviderSettings(c)
    check j.kind == JObject
    check j.len == 0

  test "caller-set keys in the base object win":
    var c = initEmotive()
    c.emotion = some(eExcited)
    c.voiceSpeed = some(1.2)
    let base = %*{"emotion": "Friendly"}
    let j = emotiveToProviderSettings(c, base)
    check j["emotion"].getStr == "Friendly"
    check j["voice_speed"].getFloat == 1.2

  test "unsupported emotion falls back to Neutral via mapEmotion":
    var c = initEmotive()
    c.emotion = some(eThoughtful)
    let j = emotiveToProviderSettings(c)
    check j["emotion"].getStr == "Neutral"

suite "HeyGen applyBackgroundToBody":

  test "green_screen sets video_inputs[0].background to a color":
    let body = buildGenerateBody("hello", "av_1", "v_1")
    var c = initEmotive()
    c.background = some(bmGreenScreen)
    applyBackgroundToBody(body, c)
    check body["video_inputs"][0]["background"]["type"].getStr == "color"
    check body["video_inputs"][0]["background"]["value"].getStr == "#00ff00"

  test "solid_color uses the explicit backgroundColor":
    let body = buildGenerateBody("hello", "av_1", "v_1")
    var c = initEmotive()
    c.background = some(bmSolidColor)
    c.backgroundColor = some("#112233")
    applyBackgroundToBody(body, c)
    check body["video_inputs"][0]["background"]["value"].getStr == "#112233"

  test "as_is leaves the body unchanged":
    let body = buildGenerateBody("hello", "av_1", "v_1")
    let before = $body
    var c = initEmotive()
    c.background = some(bmAsIs)
    applyBackgroundToBody(body, c)
    check $body == before

suite "HeyGen capabilities":

  test "self-describes supported knobs":
    check HeyGenCapabilities.supportsTextInput
    check HeyGenCapabilities.supportsGreenScreen
    check HeyGenCapabilities.supportsVoiceTuning
    check not HeyGenCapabilities.supportsAudioInput
    check not HeyGenCapabilities.supportsHeadMotion

  test "supportedEmotions includes Neutral + Excited":
    check "Neutral" in HeyGenCapabilities.supportedEmotions
    check "Excited" in HeyGenCapabilities.supportedEmotions
