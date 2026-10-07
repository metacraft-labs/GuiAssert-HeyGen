# GuiAssert-HeyGen
#
# `just test`              - run the pure + mock-server tests (no network).
# `just test-live`         - run the gated live test (-d:heygenLive). Requires HEYGEN_API_KEY.
# `just lint`              - placeholder; required by the workspace pre-commit hook.

default: test

# Pure unit tests + mock-server integration test for the plugin. Compiles
# against the sibling GuiAssert checkout via --path:../GuiAssert/src.
# `--threads:on` is required by the mock-server test: it spawns a thread
# that drives the asyncdispatch loop so the main thread can block in
# httpclient calls.
test:
    nim c -r --hints:off --path:src tests/tnimcache_is_worktree_local.nim
    nim c -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/theygen.nim

# End-to-end live test against the real HeyGen API. Requires HEYGEN_API_KEY
# to be set in the environment; the test compiles but fails loudly if
# it is missing (no graceful skips per project policy).
test-live:
    nim c -d:heygenLive -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/theygen.nim

# Required by the workspace's pre-commit hook (`just lint`). Add real
# linters here as they come online (e.g. `nim check`).
lint:
    @echo "[lint] no linters configured yet for GuiAssert-HeyGen."
