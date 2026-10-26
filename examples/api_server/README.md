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

The route table is keyed on the **(method, path) pair**, so a path
that exists under a different method is still a 404, not a 405:
`GET /fit/plr` answers `404 {"error":"route not found"}` (there is no
GET route for it), while `PUT /healthz` answers 405 (the method is
rejected before the route lookup).

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
`ci_lo` / `ci_hi` are the 95% normal-CI bounds returned by the
library's own `confint()` — `coef ± z * se` with
`z = norm_ppf(0.975)` (≈ 1.96), not a separate computation here.

`GET /version` answers with the library and service versions plus the
estimator list:

```json
{
  "library": "riantr/moonbit_doubleML@0.164.41",
  "service": "example/api_server@0.1.0",
  "estimators": ["plr", "irm"]
}
```

## Build + run

### Native

```console
$ cd /path/to/moonbit_doubleML
$ moon build --target native examples/api_server
$ ./_build/native/debug/build/example/api_server/api_server.exe
api_server: listening on http://127.0.0.1:4000
  GET  /healthz       liveness probe
  GET  /ping          round-trip
  GET  /version       library + service versions
  POST /fit/plr       DoubleMLPLR (partially linear regression)
  POST /fit/irm       DoubleMLIRM (interactive regression)
```

The binary lands under `example/api_server/` because the package is
named `example/api_server` — the workspace build root is
`_build/<target>/<profile>/build/`, and the package directory name
is kept as-is.

### WASM (moonrun)

```console
$ moon build --target wasm --release examples/api_server
$ "$USERPROFILE/.moon/bin/moonrun.exe" \
    _build/wasm/release/build/example/api_server/api_server.wasm
```

The same `.wasm` binary also runs under `moonrun.exe`; the listen
port is hard-coded to `4000` (`DEFAULT_PORT` in `main.mbt`) and the
service ignores any argument it is given -- there is no CLI parser
yet. Override by editing the constant or wiring in one.

## Smoke-test recipe (PowerShell)

```powershell
$exe = "_build/native/debug/build/example/api_server/api_server.exe"
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

- There is **no** `main_test.mbt`: the package ships no test file.
  `moonbitlang/async`'s `@http.get/post` helpers raise `ReaderClosed`
  when reading the response body on Windows, which blocks an
  `assert_eq`-style integration test inside the test driver. The
  earlier attempts live in a local working tree under `.archived/`
  (`main_test.attempted.archived`, `main_test.crescent.archived`),
  and that directory is git-ignored: they are kept for reference
  only, are **not** part of the package, and a clone does not have
  them. Endpoint correctness is verified via the PowerShell smoke
  recipe above (and the matching curl recipe in the root
  `README.mbt.md`).
- The body cap is 16 MiB. Larger uploads are rejected with
  `400 {"error":"request body exceeds 16 MiB limit"}`.
- Only GET and POST are accepted. PUT/PATCH/DELETE/HEAD/CONNECT/
  OPTIONS/TRACE → `405`.
- No path parameters, no query strings, no routing beyond
  exact-match. New JSON routes are added to the `routes` constant in
  `main.mbt`. `/ping` is the one exception: it is answered before the
  body is read and before the router runs, so a `text/plain` route
  needs the same early return rather than an entry in `routes`.
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
  LICENSE           <- MIT, same terms as the library
  .archived/        <- local only: previously-archived crescent-based main.mbt
                      (git-ignored; not part of the package)
```
