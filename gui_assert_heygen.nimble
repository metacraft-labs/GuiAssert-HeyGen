version       = "0.1.0"
author        = "Metacraft Labs"
description   = "HeyGen talking-head plugin for GuiAssert"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"
# Consumed as a relative path: callers pass `--path:../GuiAssert/src` when
# compiling. We do not list `requires "gui_assert"` here because nimble
# cannot resolve sibling-path dependencies through the public registry;
# the workspace layout described in metacraft/CLAUDE.md is the source of
# truth.

task test, "Run plugin tests":
  exec "nim c -r --threads:on --hints:off --path:src --path:../GuiAssert/src tests/theygen.nim"
