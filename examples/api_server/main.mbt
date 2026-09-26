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
//   $ moon build --target wasm examples/api_server
//   $ moonrun _build/wasm/release/build/examples/api_server/api_server.wasm --port 4000

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
) -> (Array[Double], Int, Int) raise ApiError {
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
fn json_to_int(node : Json, label : String) -> Int raise ApiError {
  match node {
    Json::Number(n, ..) => n.to_int()
    _ =>
      raise ApiError::Message(
        "field '\{label}': expected integer, got " + node.stringify(),
      )
  }
}

///|
fn json_opt_int(obj : Json, key : String, default : Int) -> Int raise ApiError {
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
) -> (Array[Double], Int, Int, Array[Double], Array[Double], Int, Int, Int) raise ApiError {
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
  n_obs : Int
  n_features : Int
} derive(ToJson)

///|
async fn write_json(
  conn : @http.ServerConnection,
  code : Int,
  reason : String,
  body : Json,
) -> Unit {
  let bytes = @utf8.encode(body.stringify())
  let headers : Map[String, String] = Map::from_array([])
  headers.set("Content-Type", "application/json; charset=utf-8")
  headers.set("Content-Length", bytes.length().to_string())
  conn.send_response(code, reason, extra_headers=headers)
  conn.write(bytes)
  conn.end_response()
}

///|
async fn write_text(
  conn : @http.ServerConnection,
  code : Int,
  reason : String,
  content_type : String,
  body : String,
) -> Unit {
  let bytes = @utf8.encode(body)
  let headers : Map[String, String] = Map::from_array([])
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
  ToJson::to_json({
    library: "riantr/moonbit_doubleML@0.52.0",
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
fn handler_fit_irm(body : Json) -> Json raise ApiError {
  let (x_data, n, p, y, d, n_folds, n_rep, seed) = parse_fit_request(body)
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
const DEFAULT_PORT : Int = 4000

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
  server.run_forever(
    (request, body, conn) => dispatch(request, body, conn),
    allow_failure=false,
  )
}
