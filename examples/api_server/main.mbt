// api_server: minimal HTTP service wrapping moonbit_doubleML estimators,
// built directly on `moonbitlang/async`. No third-party HTTP framework —
// routing, JSON body parsing, and response serialisation are all
// hand-rolled below.
//
// Endpoints
//   GET  /healthz                -> {"status":"ok"}
//   GET  /ping                   -> "pong"
//   GET  /version                -> {"library": "...", "service": "..."}
//   POST /fit/plr  (JSON body)   -> DoubleMLPLR  coefficient + 95% CI
//   POST /fit/irm  (JSON body)   -> DoubleMLIRM  coefficient + 95% CI
//
// Request body shape (same for /fit/plr and /fit/irm):
//   {
//     "x":      [[..], [..], ...],   // n x p covariates
//     "y":      [..],                // n outcome
//     "d":      [..],                // n treatment
//     "n_folds": 2,                  // optional, default 2
//     "n_rep":   1,                  // optional, default 1
//     "seed":    3141                // optional, default 3141
//   }
//
// Response body shape:
//   {
//     "estimator": "plr" | "irm",
//     "coef":      <number>,
//     "se":        <number>,
//     "ci_lo":     <number>,
//     "ci_hi":     <number>,
//     "n_obs":     <int>,
//     "n_features":<int>
//   }
//
// Run on native:
//   $ moon run --target native examples/api_server
// Run on wasm (moonrun):
//   $ moon build --target wasm --release examples/api_server
//   $ moonrun _build/wasm/release/build/example/api_server/api_server.wasm
// The build directory is `example/api_server`, not `examples/api_server`:
// the package is named `example/api_server`, so the workspace build root
// keeps the package directory name as-is.  The listen port is hard-coded
// to `4000` (`DEFAULT_PORT`) and the service takes no arguments.  See
// `examples/api_server/README.md` for the full recipe.

// ============================================================
// Error type
// ============================================================

///|
suberror ApiError {
  Message(String)
} derive(Debug)

// ============================================================
// JSON helpers
// ============================================================

///|
fn json_to_doubles(node : Json, label : String) -> Array[Double] raise ApiError {
  match node {
    Json::Array(xs) => {
      let out : Array[Double] = Array::make(xs.length(), 0.0)
      for i = 0; i < xs.length(); i = i + 1 {
        match xs[i] {
          Json::Number(n, ..) => out[i] = n
          Json::Array([Json::Number(n, ..)]) => out[i] = n
          _ =>
            raise ApiError::Message(
              "field '\{label}': expected number at index \{i}, got " +
              xs[i].stringify(),
            )
        }
      }
      out
    }
    _ =>
      raise ApiError::Message(
        "field '\{label}': expected array, got " + node.stringify(),
      )
  }
}

///|
fn json_to_matrix(
  node : Json,
  label : String,
) -> (Array[Double], Int32, Int32) raise ApiError {
  match node {
    Json::Array(rows) => {
      if rows.length() == 0 {
        raise ApiError::Message("field '\{label}': empty matrix (zero rows)")
      }
      let p = match rows[0] {
        Json::Array(row) => row.length()
        _ =>
          raise ApiError::Message(
            "field '\{label}': expected row 0 to be an array, got " +
            rows[0].stringify(),
          )
      }
      if p == 0 {
        raise ApiError::Message("field '\{label}': row 0 has zero columns")
      }
      let n = rows.length()
      let out : Array[Double] = Array::make(n * p, 0.0)
      for i = 0; i < n; i = i + 1 {
        match rows[i] {
          Json::Array(row) =>
            if row.length() != p {
              raise ApiError::Message(
                "field '\{label}': row \{i} has \{row.length()} columns, expected \{p}",
              )
            } else {
              for j = 0; j < p; j = j + 1 {
                match row[j] {
                  Json::Number(v, ..) => out[i * p + j] = v
                  _ =>
                    raise ApiError::Message(
                      "field '\{label}': non-numeric entry at (\{i},\{j})",
                    )
                }
              }
            }
          _ =>
            raise ApiError::Message(
              "field '\{label}': expected row \{i} to be an array, got " +
              rows[i].stringify(),
            )
        }
      }
      (out, n, p)
    }
    _ =>
      raise ApiError::Message(
        "field '\{label}': expected array of rows, got " + node.stringify(),
      )
  }
}

///|
fn json_to_int(node : Json, label : String) -> Int32 raise ApiError {
  match node {
    Json::Number(n, ..) => n.to_int()
    _ =>
      raise ApiError::Message(
        "field '\{label}': expected integer, got " + node.stringify(),
      )
  }
}

///|
fn json_opt_int(
  obj : Json,
  key : String,
  default : Int32,
) -> Int32 raise ApiError {
  match obj {
    Json::Object(map) =>
      match map.get(key) {
        Some(Json::Null) | None => default
        Some(v) => json_to_int(v, key)
      }
    _ => raise ApiError::Message("expected top-level JSON object")
  }
}

///|
fn parse_fit_request(
  body : Json,
) -> (
  Array[Double],
  Int32,
  Int32,
  Array[Double],
  Array[Double],
  Int32,
  Int32,
  Int32,
) raise ApiError {
  match body {
    Json::Object(obj) => {
      let x_node = match obj.get("x") {
        Some(v) => v
        None => raise ApiError::Message("missing required field 'x'")
      }
      let (x_data, n, p) = json_to_matrix(x_node, "x")
      let y_node = match obj.get("y") {
        Some(v) => v
        None => raise ApiError::Message("missing required field 'y'")
      }
      let y = json_to_doubles(y_node, "y")
      if y.length() != n {
        raise ApiError::Message("field 'y': length \{y.length()} != n_obs \{n}")
      }
      let d_node = match obj.get("d") {
        Some(v) => v
        None => raise ApiError::Message("missing required field 'd'")
      }
      let d = json_to_doubles(d_node, "d")
      if d.length() != n {
        raise ApiError::Message("field 'd': length \{d.length()} != n_obs \{n}")
      }
      let n_folds = json_opt_int(body, "n_folds", 2)
      let n_rep = json_opt_int(body, "n_rep", 1)
      let seed = json_opt_int(body, "seed", 3141)
      require_crossfit_params(n, n_folds, n_rep)
      (x_data, n, p, y, d, n_folds, n_rep, seed)
    }
    _ => raise ApiError::Message("expected top-level JSON object")
  }
}

// ============================================================
// Response types — derive ToJson so we never hit the
// `Json::Object(Map::of([]))` readonly inference trap.
// ============================================================

///|
struct Empty {} derive(ToJson)

///|
struct HealthResponse {
  status : String
} derive(ToJson)

///|
struct VersionResponse {
  library : String
  service : String
  estimators : Array[String]
} derive(ToJson)

///|
struct ErrorResponse {
  error : String
} derive(ToJson)

///|
struct FitResponse {
  estimator : String
  coef : Double
  se : Double
  ci_lo : Double
  ci_hi : Double
  n_obs : Int32
  n_features : Int32
} derive(ToJson)

///|
async fn write_json(
  conn : @http.ServerConnection,
  code : Int32,
  reason : String,
  body : Json,
) -> Unit {
  let bytes = @utf8.encode(body.stringify())
  let headers : Map[@http.CaseInsensitiveString, String] = Map::from_array([])
  headers.set("Content-Type", "application/json; charset=utf-8")
  headers.set("Content-Length", bytes.length().to_string())
  conn.send_response(code, reason, extra_headers=headers)
  conn.write(bytes)
  conn.end_response()
}

///|
async fn write_text(
  conn : @http.ServerConnection,
  code : Int32,
  reason : String,
  content_type : String,
  body : String,
) -> Unit {
  let bytes = @utf8.encode(body)
  let headers : Map[@http.CaseInsensitiveString, String] = Map::from_array([])
  headers.set("Content-Type", content_type)
  headers.set("Content-Length", bytes.length().to_string())
  conn.send_response(code, reason, extra_headers=headers)
  conn.write(bytes)
  conn.end_response()
}

///|
async fn write_400(conn : @http.ServerConnection, msg : String) -> Unit {
  write_json(conn, 400, "Bad Request", ToJson::to_json({ error: msg, }))
}

///|
async fn write_404(conn : @http.ServerConnection) -> Unit {
  write_json(
    conn,
    404,
    "Not Found",
    ToJson::to_json({ error: "route not found", }),
  )
}

///|
async fn write_405(conn : @http.ServerConnection) -> Unit {
  write_json(
    conn,
    405,
    "Method Not Allowed",
    ToJson::to_json({ error: "method not allowed", }),
  )
}

// ============================================================
// Route handlers — each takes the request body (Json) and
/// returns the response Json. All declared `raise ApiError`
/// even if they don't actually raise, so the route-table
/// function type is uniform.
// ============================================================

///|
fn handler_healthz(_body : Json) -> Json raise ApiError {
  ToJson::to_json({ status: "ok", })
}

///|
fn handler_version(_body : Json) -> Json raise ApiError {
  // NOTE: this literal is pinned to moonbit_doubleML/moon.mod's `version` and
  // is asserted by the qa_loop `api_test` check, which GETs /version and
  // compares against the real moon.mod. It had silently drifted to 0.52.0
  // while the package was 124 releases ahead; nothing in CI or the test
  // suite could see it, because the previous assertion only checked that
  // the substring appeared at all.
  //
  // It then drifted AGAIN, to 0.162.0, on the v0.163.0 bump -- and again
  // nothing caught it, for a different reason: `api_test` is a FULL-scope
  // check and neither `check.yml` nor `publish.yml` passes `--full`, so the
  // only gate that can see this drift is one no workflow runs. Found by
  // running the full scope by hand, not by a red build.
  //
  // That is why `check.yml` now has an explicit step for the two service
  // checks: a check nobody runs is not a gate, and the cost of running these
  // two is ~16s each, against the full scope's re-running of `moon test` and
  // all 24 cross-checks.
  //
  // It drifted a THIRD time, to 0.163.0, on the 0.163.1 bump. The first pass
  // edited the root README and moon.mod and stopped; `readme-sync`
  // caught the shipped copy and `api_test` caught this literal, in the
  // same run. Both are real gates doing their job -- a version bump touches
  // every place the version lives, and `_verify/_bump_1636.py` is that list.
  ToJson::to_json({
    library: "riantr/moonbit_doubleML@0.164.53",
    service: "example/api_server@0.1.0",
    estimators: ["plr", "irm"],
  })
}

///|
fn handler_fit_plr(body : Json) -> Json raise ApiError {
  let (x_data, n, p, y, d, n_folds, n_rep, seed) = parse_fit_request(body)
  let x_mat = @moonbit_doubleML.Matrix::from_array(x_data, n, p)
  let data = @moonbit_doubleML.DoubleMLData::new(x_mat, y, d)
  let fitted = @moonbit_doubleML.DoubleMLPLR::new(data, n_folds~, n_rep~, seed~).fit()
  let (lo, hi) = fitted.confint()
  ToJson::to_json({
    estimator: "plr",
    coef: fitted.coef(),
    se: fitted.se(),
    ci_lo: lo,
    ci_hi: hi,
    n_obs: n,
    n_features: p,
  })
}

///|
/// The library's cross-fitting preconditions, as ENFORCED rather than as
/// documented.
///
/// Every estimator constructor `require`s `n_folds >= 2`,
/// `n_folds <= n_obs` and `n_rep >= 1` (`plr.mbt:106-108`,
/// `irm.mbt:121-123`), and `kfold` itself `require`s `n_obs > 0`,
/// `n_folds > 0` and `n_folds <= n_obs` (`kfold.mbt:440-442`).  A `require`
/// in MoonBit is a PANIC, not a catchable error, so a request that violates
/// one of them takes the whole PROCESS down rather than the request: the
/// process exits and every later caller gets a refused connection.
///
/// MEASURED, not assumed: `POST /fit/irm` with one row and `n_folds = 2`
/// printed `precondition failed at kfold.mbt:442:5-442:30` followed by
/// `PanicError`; the client saw the connection reset, and `/healthz` then
/// answered "connection refused" instead of `{"status":"ok"}`.  The v0.164.38
/// validator made this WORSE in one narrow sense: it calls the library's own
/// `kfold` to reproduce the fold split, so the panic moved INTO the check
/// that was supposed to prevent it.
///
/// So the service checks the SAME conditions first and answers 400.  This
/// lives in `parse_fit_request`, which BOTH fit handlers call before they
/// touch the library, so no endpoint can reach a `require` with a value the
/// library will reject -- and a new endpoint cannot forget the check.
fn require_crossfit_params(
  n : Int32,
  n_folds : Int32,
  n_rep : Int32,
) -> Unit raise ApiError {
  if n < 1 {
    raise ApiError::Message(
      "field 'x': needs at least one row, got " + n.to_string(),
    )
  }
  if n_folds < 2 {
    raise ApiError::Message(
      "field 'n_folds': must be at least 2, got " + n_folds.to_string(),
    )
  }
  if n_folds > n {
    raise ApiError::Message(
      "field 'n_folds': must not exceed n_obs (" +
      n.to_string() +
      "), got " +
      n_folds.to_string(),
    )
  }
  if n_rep < 1 {
    raise ApiError::Message(
      "field 'n_rep': must be at least 1, got " + n_rep.to_string(),
    )
  }
}

///|
/// The IRM score fits a separate nuisance model per treatment group, so
/// every cross-fitting fold's TRAINING set must hold at least one control
/// row (d == 0) and one treated row (d == 1).  The library refuses to fit
/// otherwise -- `irm.mbt` aborts through `require(...)` rather than write
/// zero nuisance predictions -- and a panic inside a request handler takes
/// the whole service down with it, not just the request: the process exits
/// and every later request gets a refused connection.
///
/// So the service checks the SAME condition first, with the library's OWN
/// public `kfold`, and answers 400 with a message the client can act on.
/// The folds are the ones the fit will use -- `kfold(n, n_folds, seed + r)`
/// for repetition r -- so the check cannot drift away from the library's.
///
/// `kfold` ABORTS on an impossible partition (`n_folds > n_obs`), so the
/// cross-fitting parameters are checked even earlier, in
/// `require_crossfit_params`, before this function reaches `kfold`.
fn require_irm_split(
  d : Array[Double],
  n : Int32,
  n_folds : Int32,
  n_rep : Int32,
  seed : Int32,
) -> Unit raise ApiError {
  for i = 0; i < d.length(); i = i + 1 {
    let v = d[i]
    if v != 0.0 && v != 1.0 {
      raise ApiError::Message(
        "field 'd': DoubleMLIRM's treatment must be binary (0 or 1), got " +
        v.to_string(),
      )
    }
  }
  for r = 0; r < n_rep; r = r + 1 {
    let folds = @moonbit_doubleML.kfold(n, n_folds, seed + r)
    for f in folds {
      let mut n_control = 0
      let mut n_treated = 0
      for i in f.train_indices() {
        if d[i] == 0.0 {
          n_control = n_control + 1
        } else {
          n_treated = n_treated + 1
        }
      }
      if n_control == 0 || n_treated == 0 {
        raise ApiError::Message(
          "field 'd': every cross-fitting fold's training set needs both a " +
          "control (0) and a treated (1) row; repetition " +
          r.to_string() +
          " has " +
          n_control.to_string() +
          " control and " +
          n_treated.to_string() +
          " treated rows",
        )
      }
    }
  }
}

///|
fn handler_fit_irm(body : Json) -> Json raise ApiError {
  let (x_data, n, p, y, d, n_folds, n_rep, seed) = parse_fit_request(body)
  require_irm_split(d, n, n_folds, n_rep, seed)
  let x_mat = @moonbit_doubleML.Matrix::from_array(x_data, n, p)
  let data = @moonbit_doubleML.DoubleMLData::new(x_mat, y, d)
  let fitted = @moonbit_doubleML.DoubleMLIRM::new(data, n_folds~, n_rep~, seed~).fit()
  let (lo, hi) = fitted.confint()
  ToJson::to_json({
    estimator: "irm",
    coef: fitted.coef(),
    se: fitted.se(),
    ci_lo: lo,
    ci_hi: hi,
    n_obs: n,
    n_features: p,
  })
}

// ============================================================
// Router
// ============================================================

///|
priv enum Method {
  Get
  Post
} derive(Eq)

///|
priv struct Route {
  method_ : Method
  path : String
  handler : (Json) -> Json raise ApiError
}

///|
let routes : Array[Route] = [
  { method_: Get, path: "/healthz", handler: handler_healthz, },
  { method_: Get, path: "/version", handler: handler_version, },
  { method_: Post, path: "/fit/plr", handler: handler_fit_plr, },
  { method_: Post, path: "/fit/irm", handler: handler_fit_irm, },
]

///|
fn lookup(method_ : Method, path : String) -> ((Json) -> Json raise ApiError)? {
  for r in routes {
    if r.method_ == method_ && r.path == path {
      return Some(r.handler)
    }
  }
  None
}

// ============================================================
// Request → response dispatch
// ============================================================

///|
/// Build the empty-body sentinel Json via the Empty struct's
/// derived ToJson — `Json::Object(Map::of([]))` and even
/// `Json::Null` are flagged readonly by the compiler when
/// constructed inside async fn bodies.
fn empty_body_json() -> Json {
  ToJson::to_json(Empty::{ })
}

///|
/// Read the request body into a `Json` value (empty object for GET).
/// Caps the body size at 16 MiB to keep the server robust against
/// pathological clients.
async fn read_body_json(
  body : &@io.Reader,
  method_ : Method,
) -> Json raise Error {
  if method_ == Get {
    return empty_body_json()
  }
  let cap = 16 * 1024 * 1024
  let buf : Array[Byte] = Array::make(0, b'0')
  // `body.read_some()` may raise a generic Error (e.g. on disconnect);
  // we just stop accumulating on error and let the dispatch layer
  // translate any unhandled Error into a 500.
  let mut done = false
  while !done {
    let chunk = body.read_some()
    match chunk {
      Some(bytes) =>
        if buf.length() + bytes.length() >= cap {
          raise ApiError::Message("request body exceeds 16 MiB limit")
        } else {
          for i = 0; i < bytes.length(); i = i + 1 {
            buf.push(bytes[i])
          }
        }
      None => done = true
    }
  }
  if buf.length() == 0 {
    return empty_body_json()
  }
  let bytes = Bytes::from_array(buf)
  let text = @utf8.decode(bytes) catch {
    _ => raise ApiError::Message("request body is not valid UTF-8")
  }
  @json.parse(text) catch {
    _ => raise ApiError::Message("request body is not valid JSON")
  }
}

///|
pub async fn dispatch(
  req : @http.Request,
  body : &@io.Reader,
  conn : @http.ServerConnection,
) -> Unit {
  let method_ : Method = match req.meth {
    @http.Get => Get
    @http.Post => Post
    _ => {
      write_405(conn)
      return
    }
  }
  // Special-case /ping (text response, not JSON).
  if method_ == Get && req.path == "/ping" {
    write_text(conn, 200, "OK", "text/plain; charset=utf-8", "pong")
    return
  }
  let json_body = read_body_json(body, method_) catch {
    ApiError::Message(msg) => {
      write_400(conn, msg)
      return
    }
    _ => {
      write_400(conn, "internal server error reading body")
      return
    }
  }
  match lookup(method_, req.path) {
    None => write_404(conn)
    Some(handler) =>
      try {
        let resp = handler(json_body)
        write_json(conn, 200, "OK", resp)
      } catch {
        ApiError::Message(msg) => write_400(conn, msg)
        _ => write_400(conn, "internal server error")
      }
  }
}

// ============================================================
// Entry point
// ============================================================

///|
const DEFAULT_PORT : Int32 = 4000

///|
async fn main {
  let port = DEFAULT_PORT
  let addr = @socket.Addr::parse("127.0.0.1:\{port}") catch {
    err => {
      println("api_server: failed to parse listen address: \{err}")
      return
    }
  }
  let server = @http.Server(addr, reuse_addr=true)
  println("api_server: listening on http://127.0.0.1:\{port}")
  println("  GET  /healthz       liveness probe")
  println("  GET  /ping          round-trip")
  println("  GET  /version       library + service versions")
  println("  POST /fit/plr       DoubleMLPLR (partially linear regression)")
  println("  POST /fit/irm       DoubleMLIRM (interactive regression)")
  // `allow_failure=true` is load-bearing.
  //
  // With `allow_failure=false` a connection that arrives before the listener is
  // fully up propagates out of `run_forever` and kills the process: the server
  // prints its banner, then exits 1, after which every request fails with
  // WinError 10061 (connection refused).
  //
  // Measured via the qa_loop checks, which boot the service and talk to it
  // (see `api_test` / `security_dast`):
  //   allow_failure=false -> both checks FAIL, deterministically
  //   allow_failure=true  -> both checks PASS, deterministically
  //
  // A control experiment that sleeps 25s before its FIRST request survives 10
  // sequential requests under both settings, because it never makes a
  // premature connection -- so the trigger is early/incomplete connections,
  // not request count. A client or monitor that probes before startup
  // finishes is enough.
  //
  // Application-level errors are already handled inside `dispatch`, which turns
  // ApiError into a 400; only low-level connection teardown reaches here, and
  // that must not take the listener down.
  server.run_forever(
    (request, body, conn) => dispatch(request, body, conn),
    allow_failure=true,
  )
}
