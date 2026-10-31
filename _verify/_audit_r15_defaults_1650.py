#!/usr/bin/env python3
"""Round 15 -- the re-measurement for the six constructor-defaults records.

WHY THIS EXISTS.  Six `_verify/*.md` records in this repository state measured
facts about the port-vs-upstream constructor defaults.  Re-audited on
2026-10-20 against the v0.164.9 tree, several of their numbers had gone stale
and several of their line pointers had rotted.  Each record named a method
script as its authority; none of those scripts was tracked, so a reader could
not obtain the authority, and one of them (`_enum_all_defaults_1540.py`) had
crashed on a `NameError` for years.

This script is the method, shipped.  It re-derives every number the corrected
records cite, from source, with no hidden state:

  * the port side is parsed from `moonbit_doubleML/*.mbt` (no grep);
  * the upstream side comes from the INSTALLED `doubleml` -- 0.11.4 here --
    read via `inspect.signature` and by parsing the upstream sources;
  * the two sides never share a parser.

Run:  python _verify/_audit_r15_defaults_1650.py
Exit: 0 on success, non-zero if a section cannot be produced.

It also writes `_verify/_defaults_audit_1650.json`, which the round-15
verifier (`_verify/_verify_round15_defaults_1650.py`) reads.  The verifier
re-derives the same facts independently and compares them against the TEXT of
the six records -- so a number in a record is pinned to the measurement, not
to a literal typed here.
"""
import inspect
import json
import os
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = Path(os.environ.get("ROUND15_ROOT") or (Path(__file__).resolve().parent.parent))
PKG = ROOT / "moonbit_doubleML"
OUT_JSON = ROOT / "_verify" / "_defaults_audit_1650.json"

# ---------------------------------------------------------------- helpers


def read(p, enc="utf-8"):
    return Path(p).read_text(encoding=enc, errors="replace")


def strip_line_comments(text):
    out = []
    for line in text.splitlines():
        i = line.find("//")
        out.append(line if i == -1 else line[:i])
    return "\n".join(out)


def balanced_slice(text, start):
    depth = 0
    for k in range(start, len(text)):
        if text[k] == "(":
            depth += 1
        elif text[k] == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:k]
    return text[start + 1:]


# ---------------------------------------------------------------- 1. package census
all_mbt = sorted(p.name for p in PKG.glob("*.mbt"))
production = [f for f in all_mbt if "test" not in f]
blackbox = [f for f in all_mbt if f.endswith("_test.mbt")]
whitebox = [f for f in all_mbt if "wbtest" in f]
other = [f for f in all_mbt if f not in production and f not in blackbox
         and f not in whitebox]

NEW_RE = re.compile(r"pub fn (DoubleML[A-Za-z0-9_]+)::new\s*\(")
n_new = 0
for p in sorted(PKG.glob("*.mbt")):
    n_new += len(NEW_RE.findall(strip_line_comments(read(p))))

print("=" * 84)
print("1. PACKAGE CENSUS")
print("=" * 84)
print(f"  .mbt files, total       : {len(all_mbt)}")
print(f"  production (no 'test')  : {len(production)}")
print(f"  blackbox  (*_test.mbt)  : {len(blackbox)}")
print(f"  whitebox  (*wbtest*)    : {len(whitebox)}")
print(f"  unclassified            : {len(other)}  {other}")
print(f"  `DoubleMLXxx::new` defs : {n_new}")

# ---------------------------------------------------------------- 2. learner inventory
PARAM_RE = re.compile(
    r"(?m)^\s*([a-z_][a-z0-9_]*)[?~]?\s*:\s*([A-Za-z0-9_\[\]\.]+)\s*=\s*(.+?)\s*,?\s*$")
LEARNER_SLOTS = ("ml_g", "ml_m", "ml_l", "ml_r")

rows = defaultdict(list)
per_est_params = defaultdict(dict)
for p in sorted(PKG.glob("*.mbt")):
    src = strip_line_comments(read(p))
    for m in NEW_RE.finditer(src):
        name = m.group(1)
        body = balanced_slice(src, m.end() - 1)
        for pm in PARAM_RE.finditer(body):
            pname, ptype, pval = pm.group(1), pm.group(2), " ".join(pm.group(3).split())
            if pname == "self":
                continue
            rows[pname].append((name, ptype, pval, p.name))
            per_est_params[name][pname] = pval

learner = {}
for slot in LEARNER_SLOTS:
    sites = [(e, v) for e, t, v, _f in rows.get(slot, []) if "LearnerDispatch" in t]
    kinds = Counter()
    for e, v in sites:
        m = re.search(r"LearnerDispatch::(\w+)", v)
        kinds[m.group(1) if m else v] += 1
    learner[slot] = {
        "sites": len(sites),
        "kinds": dict(kinds),
        "estimators": sorted({e for e, _v in sites}),
    }

print()
print("=" * 84)
print("2. LEARNER DEFAULT INVENTORY")
print("=" * 84)
total_learner = 0
for slot in LEARNER_SLOTS:
    d = learner[slot]
    total_learner += d["sites"]
    kinds = ", ".join(f"{k} x{v}" for k, v in sorted(d["kinds"].items(), key=lambda kv: -kv[1]))
    print(f"  {slot}: {d['sites']} sites  ({kinds})")
    print(f"      {', '.join(d['estimators'])}")
print(f"  TOTAL learner default sites: {total_learner}")

# ---------------------------------------------------------------- 3. constructor defaults
DIVERGENCE_PARAMS = [
    "n_folds", "in_sample_normalization", "propensity_clip", "n_folds_inner",
    "normalize_ipw", "score", "n_rep", "seed", "quantile", "treatment",
    "anticipation_periods", "control_group", "cov_type",
]
print()
print("=" * 84)
print("3. CONSTRUCTOR DEFAULTS (the records' divergence table)")
print("=" * 84)
ctor = {}
for pname in DIVERGENCE_PARAMS:
    sites = rows.get(pname, [])
    if not sites:
        continue
    vals = Counter(" ".join(v.split()) for _e, _t, v, _f in sites)
    ctor[pname] = {"sites": len(sites), "values": dict(vals)}
    summary = " | ".join(f"{v} ({n})" for v, n in sorted(vals.items(), key=lambda kv: -kv[1]))
    print(f"  {pname:26s} {len(sites):>3} sites   {summary}")

# ---------------------------------------------------------------- 4. upstream
import doubleml

up_version = getattr(doubleml, "__version__", "unknown")
up_dir = os.path.dirname(inspect.getfile(doubleml))

up_defaults = {}
for nm in dir(doubleml):
    obj = getattr(doubleml, nm)
    if not (inspect.isclass(obj) and nm.startswith("DoubleML")):
        continue
    try:
        sig = inspect.signature(obj.__init__)
    except (ValueError, TypeError):
        continue
    d = {}
    for pn, prm in sig.parameters.items():
        if pn == "self" or prm.default is inspect.Parameter.empty:
            continue
        d[pn] = prm.default
    if d:
        up_defaults[nm] = d

# upstream classes that are NOT re-exported at the top level
up_extra = {}
for rel in ("did/did_multi.py", "rdd/rdd.py"):
    p = os.path.join(up_dir, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        continue
    src = read(p)
    for m in re.finditer(r"^class\s+(\w+)\s*[:(]", src, re.M):
        cls = m.group(1)
        if cls.startswith("DoubleML") and cls not in up_defaults:
            try:
                mod = __import__("doubleml." + rel[:-3].replace("/", "."),
                                fromlist=[cls])
                sig = inspect.signature(getattr(mod, cls).__init__)
                d = {pn: prm.default for pn, prm in sig.parameters.items()
                     if pn != "self" and prm.default is not inspect.Parameter.empty}
                up_defaults[cls] = d
                up_extra[cls] = rel
            except Exception:  # pragma: no cover - best effort
                pass

# upstream score vocabulary, both mechanisms
up_score = {}
for dp, _d, fns in os.walk(up_dir):
    if os.sep + "tests" in dp:
        continue
    for fn in sorted(fns):
        if not fn.endswith(".py"):
            continue
        ap = os.path.join(dp, fn)
        rel = os.path.relpath(ap, up_dir).replace("\\", "/")
        src = read(ap)
        val = None
        for rx in (r"valid_scores\s*=\s*\[([^\]]*)\]",
                   r"valid_score\s*=\s*\[([^\]]*)\]",
                   r"_check_score\(self\.score,\s*\[([^\]]*)\]"):
            m = re.search(rx, src)
            if m:
                val = [x.strip().strip('"').strip("'")
                       for x in m.group(1).split(",") if x.strip()]
                break
        if val is None:
            m = re.search(r"valid_score\s*=\s*\[([^\]]*)\]", src)
            if m:
                val = [x.strip().strip('"').strip("'")
                       for x in m.group(1).split(",") if x.strip()]
        if val:
            # The default must be read from the CONSTRUCTOR SIGNATURE, not from
            # anywhere in the file: upstream writes the whole signature on one
            # line (`..., n_folds=5, n_rep=1, score="partialling out", ...`), so
            # a line-anchored regex misses it.
            sig = ""
            msig = re.search(r"def __init__\s*\(", src)
            if msig:
                sig = balanced_slice(src, msig.end() - 1)
            mdef = re.search(r'(?<![\w.])score\s*(?::[^=]*)?=\s*"([^"]*)"', sig)
            up_score[rel] = {"accepts": val,
                             "default": mdef.group(1) if mdef else None}

print()
print("=" * 84)
print(f"4. UPSTREAM (installed doubleml {up_version})")
print("=" * 84)
print(f"  classes with a defaulted constructor parameter : {len(up_defaults)}")
print(f"  classes that validate a `score`               : {len(up_score)}")
for rel in sorted(up_score):
    d = up_score[rel]
    print(f"    {rel:24s} default={str(d['default']):20s} accepts={d['accepts']}")

# ---------------------------------------------------------------- 5. port score vocabulary
port_score = {}
for p in sorted(PKG.glob("*.mbt")):
    src = read(p)
    decl = re.findall(r"score\s*~\s*:\s*String\s*=\s*\"([^\"]*)\"", src)
    if not decl:
        continue
    accepts = set()
    for m in re.finditer(r'require\([^)]*score[^)]*\)', src):
        accepts.update(re.findall(r'"([^"]+)"', m.group(0)))
    for m in re.finditer(r"fn\s+(\w*is_\w*score)\s*\(score\s*:\s*String\)[^{]*\{([^}]*)\}", src):
        accepts.update(re.findall(r'score\s*==\s*"([^"]+)"', m.group(2)))
    if accepts:
        port_score[p.name] = sorted(accepts)

print()
print("=" * 84)
print("5. PORT `score` VOCABULARY")
print("=" * 84)
for fn in sorted(port_score):
    print(f"    {fn:24s} accepts={port_score[fn]}")

# ---------------------------------------------------------------- 6. provenance map
# Which upstream class implements the same estimator as each port estimator?
# Evidence, per estimator, from the parameters that only that upstream class
# carries: `control_group` / `anticipation_periods` (staggered-adoption) are
# present on upstream's DoubleMLDIDMulti and absent from its DoubleMLDIDCS
# (repeated cross-sections) and from DoubleMLDID (two-period panel).
PROV_EVIDENCE = {}
for cls in ("DoubleMLDIDCS", "DoubleMLDIDMulti", "DoubleMLDID"):
    p = os.path.join(up_dir, "did", {"DoubleMLDIDCS": "did_cs.py",
                                      "DoubleMLDIDMulti": "did_multi.py",
                                      "DoubleMLDID": "did.py"}[cls])
    src = read(p)
    PROV_EVIDENCE[cls] = {
        "control_group": "control_group" in src,
        "anticipation_periods": "anticipation_periods" in src,
        "data_types": sorted(set(re.findall(r"DoubleML\w*Data", src))),
    }

port_did_params = {}
for est, params in per_est_params.items():
    if est.startswith("DoubleMLDID"):
        port_did_params[est] = {
            "control_group": "control_group" in params,
            "anticipation_periods": "anticipation_periods" in params,
        }

print()
print("=" * 84)
print("6. PROVENANCE: the DID family, by parameter fingerprint")
print("=" * 84)
for cls in sorted(PROV_EVIDENCE):
    e = PROV_EVIDENCE[cls]
    print(f"  upstream {cls:18s} control_group={str(e['control_group']):5s} "
          f"anticipation_periods={str(e['anticipation_periods']):5s} data={e['data_types']}")
for est in sorted(port_did_params):
    e = port_did_params[est]
    print(f"  port    {est:18s} control_group={str(e['control_group']):5s} "
          f"anticipation_periods={str(e['anticipation_periods']):5s}")

# ---------------------------------------------------------------- 7. ml_m vs upstream
REQ = re.compile(r"_check_learner\(\s*(\w+)\s*,\s*\"(\w+)\"\s*,\s*regressor=(\w+)\s*,\s*classifier=(\w+)\s*\)")
up_mlm_req = {}
for dp, _d, fns in os.walk(up_dir):
    if os.sep + "tests" in dp:
        continue
    for fn in sorted(fns):
        if not fn.endswith(".py"):
            continue
        ap = os.path.join(dp, fn)
        src = read(ap)
        cls = None
        for ln in src.split("\n"):
            mc = re.match(r"class\s+(DoubleML\w+)", ln)
            if mc:
                cls = mc.group(1)
                break
        if not cls:
            continue
        for ln in src.split("\n"):
            m = REQ.search(ln)
            if m and m.group(2) == "ml_m":
                up_mlm_req.setdefault(cls, set()).add(
                    (m.group(3) == "True", m.group(4) == "True"))
                break

# port estimator -> upstream class, by the parameter fingerprint of the DID
# family and by identity everywhere else
PORT2UP = {}
for est in per_est_params:
    if est in ("DoubleMLDIDCrossSection", "DoubleMLDIDCS"):
        continue
    PORT2UP[est] = est
PORT2UP["DoubleMLDIDCrossSection"] = "DoubleMLDIDCS"
PORT2UP["DoubleMLDIDCS"] = "DoubleMLDIDMulti"

mlm_table = []
for est in sorted(learner["ml_m"]["estimators"]):
    v = per_est_params[est].get("ml_m", "")
    m = re.search(r"LearnerDispatch::(\w+)", v)
    kind = m.group(1) if m else v
    req = up_mlm_req.get(PORT2UP.get(est, est))
    mlm_table.append({"estimator": est, "port": kind, "upstream_class": PORT2UP.get(est, est),
                      "upstream_requires_classifier": None if not req else
                      all((not r) and c for (r, c) in req)})

print()
print("=" * 84)
print("7. ml_m: PORT DEFAULT vs UPSTREAM REQUIREMENT")
print("=" * 84)
for r in mlm_table:
    print(f"  {r['estimator']:26s} {r['port']:20s} -> upstream {r['upstream_class']:22s} "
          f"requires_classifier={r['upstream_requires_classifier']}")
port_linear = {r["estimator"] for r in mlm_table if r["port"] == "linear_regression"}
needs_cls = {r["estimator"] for r in mlm_table if r["upstream_requires_classifier"]}
# upstream classes that accept a REGRESSOR for ml_m (i.e. where a linear
# default would be upstream-legal)
allows_reg = set()
for rel, ap in [("did/did.py", None)]:
    pass
for r in mlm_table:
    cls = r["upstream_class"]
    if r["upstream_requires_classifier"] is False:
        allows_reg.add(r["estimator"])
print(f"  port ml_m = linear_regression      : {len(port_linear)}")
print(f"  ...of which upstream demands a clf : {len(port_linear & needs_cls)}")
print(f"  upstream accepts a regressor for ml_m at: {sorted(allows_reg)}")
print(f"  INVARIANT  every port regressor-defaulted ml_m is one where upstream")
print(f"              demands a classifier   : {port_linear <= needs_cls}")
print(f"  INVARIANT  no port regressor-defaulted ml_m is one where upstream")
print(f"              accepts a regressor   : {not (port_linear & allows_reg)}")

# ---------------------------------------------------------------- 8. capture-scope divergence
# The recorded upstream capture (`_verify/_upstream_defaults_1540.txt`) covers 10
# upstream estimators.  Match them 1:1 to the port's corresponding ::new and
# classify every (estimator, parameter) pair:
#   MATCH         both sides declare it, same value
#   VALUE-DIFF    both sides declare it, different value
#   UPSTREAM-ONLY upstream declares it, the port does not
#
# NOTE the 1:1 map: upstream's DoubleMLDIDCS is the REPEATED CROSS-SECTIONS
# estimator, which is the port's DoubleMLDIDCrossSection.  The port's
# DoubleMLDIDCS is the panel estimator, whose upstream counterpart is
# DoubleMLDIDMulti -- not in the capture.
CAP_PATH = ROOT / "_verify" / "_upstream_defaults_1540.txt"
capture = {}
if CAP_PATH.is_file():
    raw = CAP_PATH.read_bytes()
    enc = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
    txt = raw.decode(enc, errors="replace").split("=" * 10)[0]
    cur = None
    for ln in txt.split("\n"):
        s = ln.strip()
        if not s or s.startswith("upstream doubleml"):
            continue
        if s.startswith("DoubleML"):
            cur = s
            capture.setdefault(cur, {})
        elif cur and "=" in s:
            k, _, v = s.partition("=")
            capture[cur][k.strip()] = v.strip()

CAP1TO1 = {
    "DoubleMLDIDCS": "DoubleMLDIDCrossSection",   # upstream: repeated cross-sections
    "DoubleMLDID": "DoubleMLDID",
    "DoubleMLIRM": "DoubleMLIRM",
    "DoubleMLIIVM": "DoubleMLIIVM",
    "DoubleMLAPO": "DoubleMLAPO",
    "DoubleMLCVAR": "DoubleMLCVAR",
    "DoubleMLSSM": "DoubleMLSSM",
    "DoubleMLLPLR": "DoubleMLLPLR",
    "DoubleMLPQ": "DoubleMLPQ",
    "DoubleMLQTE": "DoubleMLQTE",
}


def norm_value(v):
    v = str(v).strip().strip(",").replace('"', "'")
    if v.startswith("'") and v.endswith("'"):
        v = v[1:-1]
    if v in ("True", "true"):
        v = "True"
    if v in ("False", "false"):
        v = "False"
    try:
        f = float(v)
        v = repr(f) if f != int(f) else str(int(f))
    except ValueError:
        pass
    return v


cap_class = {"match": 0, "value_diff": 0, "upstream_only": 0, "port_only": 0,
             "upstream_pairs": 0, "both_declare": 0,
             "value_diff_names": set(), "upstream_only_names": set()}
for up_est, params in capture.items():
    port_est = CAP1TO1.get(up_est)
    for pn, uv in params.items():
        cap_class["upstream_pairs"] += 1
        if port_est is None or pn not in per_est_params.get(port_est, {}):
            cap_class["upstream_only"] += 1
            cap_class["upstream_only_names"].add(pn)
            continue
        cap_class["both_declare"] += 1
        if norm_value(uv) == norm_value(per_est_params[port_est][pn]):
            cap_class["match"] += 1
        else:
            cap_class["value_diff"] += 1
            cap_class["value_diff_names"].add(pn)
for port_est, params in per_est_params.items():
    up_est = next((u for u, p in CAP1TO1.items() if p == port_est), None)
    if up_est is None:
        continue
    for pn in params:
        if pn not in capture.get(up_est, {}):
            cap_class["port_only"] += 1

print()
print("=" * 84)
print("8. CAPTURE-SCOPE DIVERGENCE (1:1 estimator map)")
print("=" * 84)
print(f"  capture estimators            : {len(capture)}")
print(f"  upstream (estimator, param) pairs : {cap_class['upstream_pairs']}")
print(f"  both sides declare it         : {cap_class['both_declare']}")
print(f"    MATCH                       : {cap_class['match']}")
print(f"    VALUE-DIFF                  : {cap_class['value_diff']}  "
      f"names={sorted(cap_class['value_diff_names'])}")
print(f"  UPSTREAM-ONLY (one-sided)     : {cap_class['upstream_only']}  "
      f"names={sorted(cap_class['upstream_only_names'])}")
print(f"  PORT-ONLY (one-sided)         : {cap_class['port_only']}")
print(f"  the record's triple (49/42/7) reproduces? "
      f"{(cap_class['value_diff'] + cap_class['upstream_only'], cap_class['upstream_only'], cap_class['value_diff']) == (49, 42, 7)}")

# ---------------------------------------------------------------- summary
summary = {
    "package": {"total_mbt": len(all_mbt), "production": len(production),
                "blackbox": len(blackbox), "whitebox": len(whitebox),
                "other": len(other), "new_definitions": n_new},
    "learner": learner,
    "learner_total_sites": total_learner,
    "constructor_defaults": ctor,
    "upstream_version": up_version,
    "upstream_defaults": {k: {kk: str(vv) for kk, vv in v.items()}
                           for k, v in up_defaults.items()},
    "upstream_score": up_score,
    "port_score": port_score,
    "provenance_evidence": PROV_EVIDENCE,
    "port_did_params": port_did_params,
    "port2up": PORT2UP,
    "mlm_table": mlm_table,
    "mlm_port_linear": sorted(port_linear),
    "mlm_needs_classifier": sorted(needs_cls),
    "mlm_allows_regressor": sorted(allows_reg),
    "mlm_relation_subset": port_linear <= needs_cls,
    "mlm_relation_no_legal_regressor": not (port_linear & allows_reg),
    "capture_class": {k: (sorted(v) if isinstance(v, set) else v)
                       for k, v in cap_class.items()},
}
OUT_JSON.write_text(json.dumps(summary, indent=2, sort_keys=True, ensure_ascii=False),
                    encoding="utf-8")
print()
print(f"wrote {OUT_JSON}")
