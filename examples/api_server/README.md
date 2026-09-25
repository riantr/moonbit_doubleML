# examples/api_server

Minimal HTTP service wrapping
[`riantr/moonbit_doubleML`](https://mooncakes.io/riantr/moonbit_doubleML).
Built directly on
[`moonbitlang/async`](https://mooncakes.io/moonbitlang/async) — no
third-party web framework is pulled in. Per the repo-wide dependency
rule (see `skills/moonbit_doubleML.md`), only official
`moonbitlang/*` packages are allowed; this example follows that
constraint.

## Endpoints

| Method | Path         | Purpose                                 |
|--------|--------------|-----------------------------------------|
| `GET`  | `/healthz`   | liveness probe, returns `{"status":"ok"}` |
| `GET`  | `/ping`      | round-trip text probe, returns `pong`   |
| `GET`  | `/version`   | library + service version metadata      |
| `POST` | `/fit/plr`   | fit `DoubleMLPLR` to a JSON request     |
| `POST` | `/fit/irm`   | fit `DoubleMLIRM` to a JSON request     |

Anything else → `404 {"error":"route not found"}`.
Any non-GET/POST method → `405 {"error":"method not allowed"}`.

## Request shape (POST `/fit/{plr,irm}`)

```json
{
  "x":      [[..], [..], ...],   // n x p covariates
  "y":      [..],                // n outcome
  "d":      [..],                // n treatment
  "n_folds": 2,                  // optional, default 2
  "n_rep":   1,                  // optional, default 1
  "seed":    3141                // optional, default 3141
}
```

## Response shape (POST `/fit/{plr,irm}`)

```json
{
  "estimator": "plr",
  "coef":      <number>,
  "se":        <number>,
  "ci_lo":     <number>,
  "ci_hi":     <number>,
  "n_obs":     <int>,
  "n_features":<int>
}
```

`estimator` is `"plr"` for `/fit/plr` and `"irm"` for `/fit/irm`.
`ci_lo` / `ci_hi` are the 95% normal-CI bounds (`coef ± 1.96 * se`).

## Build + run

### Native

```console
$ cd /path/to/moonbit_doubleML
$ moon build --target native examples/api_server
$ ./_build/native/debug/build/api_server/api_server.exe
api_server: listening on http://127.0.0.1:4000
  GET  /healthz       liveness probe
  GET  /ping          round-trip
  GET  /version       library + service versions
  POST /fit/plr       DoubleMLPLR (partially linear regression)
  POST /fit/irm       DoubleMLIRM (interactive regression)
```

### WASM (moonrun)

```console
$ moon build --target wasm --release examples/api_server
$ "$USERPROFILE/.moon/bin/moonrun.exe" \
    _build/wasm/release/build/api_server/api_server.wasm \
    --port 4000
```

The same `.wasm` binary also runs under `moonrun.exe`; the default
listen port is hard-coded to `4000` (`DEFAULT_PORT` in `main.mbt`).
Override by editing the constant or wiring in a CLI arg parser once
`moonbitlang/x` becomes importable as a non-meta sub-package.

## Smoke-test recipe (PowerShell)

```powershell
$exe = "_build/native/debug/build/api_server/api_server.exe"
$proc = Start-Process -FilePath $exe -PassThru -NoNewWindow

# GET probes
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:4000/healthz | Select-Object StatusCode, Content
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:4000/ping    | Select-Object StatusCode, Content
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:4000/version | Select-Object StatusCode, Content

# POST PLR on a perfect DGP (y = 2*d, no noise) -> coef == 2.0
$body = '{"x":[[1.0,0.5],[2.0,1.5]],"y":[2.0,4.0],"d":[1.0,2.0],"n_folds":2,"seed":3141}'
Invoke-WebRequest -UseBasicParsing -Method POST -ContentType "application/json" -Body $body `
    http://127.0.0.1:4000/fit/plr | Select-Object StatusCode, Content

# POST IRM requires binary d ∈ {0, 1}
$body = '{"x":[[1.0,0.5],[2.0,1.5],[3.0,2.5],[4.0,3.5]],"y":[1.5,3.5,1.5,3.5],"d":[0.0,1.0,0.0,1.0],"n_folds":2,"seed":3141}'
Invoke-WebRequest -UseBasicParsing -Method POST -ContentType "application/json" -Body $body `
    http://127.0.0.1:4000/fit/irm | Select-Object StatusCode, Content

# 400 on malformed JSON
Invoke-WebRequest -UseBasicParsing -Method POST -ContentType "application/json" -Body "garbage" `
    http://127.0.0.1:4000/fit/plr | Select-Object StatusCode, Content

Stop-Process -Id $proc.Id -Force
```

## Known limitations

- `main_test.mbt` is currently empty. `moonbitlang/async`'s
  `@http.get/post` helpers raise `ReaderClosed` when reading the
  response body on Windows, which blocks an `assert_eq`-style
  integration test inside the test driver. Endpoint correctness
  is verified via the PowerShell smoke recipe above (and the
  matching curl recipe in the root `README.mbt.md`).
- The body cap is 16 MiB. Larger uploads are rejected with
  `400 {"error":"request body exceeds 16 MiB limit"}`.
- Only GET and POST are accepted. PUT/PATCH/DELETE/HEAD/CONNECT/
  OPTIONS/TRACE → `405`.
- No path parameters, no query strings, no routing beyond
  exact-match. New routes are added to the `routes` constant in
  `main.mbt`.
- `Content-Type` is always `application/json; charset=utf-8` for
  JSON responses and `text/plain; charset=utf-8` for `/ping`.
  No negotiation.

## Source layout

```
examples/api_server/
  moon.mod          <- name="example/api_server", deps only on official + own
  moon.pkg          <- imports riantr/moonbit_doubleML, moonbitlang/async*
  main.mbt          <- router + JSON parser + handler + entry point
  README.md         <- this file
  .archived/        <- previously-archived crescent-based main.mbt (kept for reference)
```
