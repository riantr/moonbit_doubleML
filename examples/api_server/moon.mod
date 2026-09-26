name = "example/api_server"

version = "0.1.0"

import {
  "riantr/moonbit_doubleML@0.52.0",
  "moonbitlang/async@0.20.3",
}

readme = "../../README.mbt.md"

repository = "https://gitee.com/ren-yongxiang/moonbit_doubleml.git"

license = "Apache-2.0"

keywords = [ "doubleml", "example", "api", "http", "wasm" ]

description = "Minimal HTTP API server wrapping moonbit_doubleML estimators (PLR, IRM). Runs on --target native and --target wasm (moonrun). Exposes POST /fit/{plr,irm} plus /healthz, /ping, /version."

preferred_target = "wasm"
