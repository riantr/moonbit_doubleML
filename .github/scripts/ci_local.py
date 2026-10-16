"""Local simulation of this repository's GitHub Actions CI.

Why this exists
---------------
CI runs on `ubuntu-latest`. A Windows box cannot faithfully answer questions
about it: `python3` does not resolve here, `bash` is not on PATH, the shell is
PowerShell, and `typos` is a different version with a different dictionary.
That gap already cost a full cycle: a check reported `typos: 3 finding(s)` on
ubuntu that did not exist locally, and the cause turned out to be that the
check measured something the real gate never measures. A finding you cannot
reproduce is a finding you cannot trust.

This runs the jobs against a real Linux environment (WSL Ubuntu by default),
executing the `run:` steps **straight out of the workflow YAML** rather than
from a hand-maintained copy. A copy of the jobs would drift the first time
someone edited a workflow, and a simulator that lies about what CI does is
worse than no simulator.

What it simulates
-----------------
* a pristine tracked checkout of the requested ref (`git archive <ref>`),
  which is what `actions/checkout` produces -- no untracked scratch, no local
  `_build/`, no dirty tree
* each `run:` step, via `bash -e`, which is exactly the shell string GitHub
  logged: `shell: /usr/bin/bash -e {0}`
* job-level and step-level `env`, and `>> $GITHUB_PATH`, so a step that
  installs a tool makes it visible to later steps
* `strategy.matrix` expansion, including `${{ matrix.* }}` inside step bodies
* `needs:` ordering, and skipping dependents when a dependency fails
* what the runner image already provides: `python`/`pip` and `node`, via
  `provision` (see below)

What it does NOT simulate -- and never pretends to
--------------------------------------------------
* `uses:` steps (actions/checkout, actions/setup-python, ...) -- reported
  explicitly as SKIPPED, never silently passed
* secrets, GITHUB_TOKEN, `permissions:`
* release publishing (`moon publish`, `Create GitHub Release`) -- these are
  plain `run:` steps, so nothing structural stops them; a body matching UNSAFE
  is REFUSED and reported SKIP rather than executed. See ST8.
* the exact OS image: WSL Ubuntu is close to ubuntu-latest but is not it

Verdicts
--------
PASS     the step ran and succeeded
FAIL     the step ran and failed -- a real defect in the ref under test
SKIP     deliberately not simulated: a `uses:` step, or a refused publish step
BLOCKED  THIS MACHINE lacks a tool the step needs; nothing was proven either
         way. Never counted as coverage, never merged into "all passed".

BLOCKED is cross-checked with `command -v` inside the guest, so a command the
guest does have and that fails anyway still reports FAIL. A step whose entire
body is PROVISIONING a named tool is also BLOCKED when it fails: it downloads
tools and asserts nothing about the repository, so its outcome is a fact about
this machine's network, not about the ref. `Install typos` is the real case --
see `unprovisionable_tool`.

Provisioning
------------
The guest has no sudo, and this Ubuntu build strips `ensurepip`, so neither
`apt` nor `python3 -m venv` works. `provision` bootstraps both toolchains by
download instead, under the guest's $HOME (NOT /tmp -- measured: /tmp does not
survive a WSL restart, and a venv that silently vanishes would turn every
python-cross-check step into BLOCKED with no explanation).

Usage
-----
    python .github/scripts/ci_local.py list
    python .github/scripts/ci_local.py provision
    python .github/scripts/ci_local.py run [--jobs a,b] [--engine wsl|gitbash|none]
    python .github/scripts/ci_local.py run --all
    python .github/scripts/ci_local.py selftest

Exit code 0 only if every executed step passed.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import shlex
import subprocess
import sys
import tarfile
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

try:
    import yaml
except ImportError:                                  # noqa: BLE001
    yaml = None

GH_BASH = r"D:\Program Files\Git\bin\bash.exe"


# --------------------------------------------------------------------------- #
# engines
# --------------------------------------------------------------------------- #
class Engine:
    """How a step's `run:` body gets executed."""

    # Only these two are actually harmful to pass through: a Windows PATH is
    # not a Linux PATH, so `mkdir`/`chmod`/`curl` cannot be found, and a
    # Windows HOME confuses installers that write to "~/.moon".
    #
    # Deliberately NOT stripping the rest of the Windows environment: wsl.exe
    # is itself a Windows process, and removing TEMP/APPDATA/etc. makes it exit
    # -1 before it ever reaches the distro. Measured both ways -- full env with
    # PATH/HOME overridden works, stripping anything breaks it.
    GUEST_OVERRIDE = ("PATH", "HOME")

    def __init__(self, name, prefix, host_to_guest=None, probe_cmd="true",
                 linux=False):
        self.name = name
        self.prefix = prefix or []
        self.host_to_guest = host_to_guest or (lambda p: p)
        self.probe_cmd = probe_cmd
        self.linux = linux
        self._base = None

    def guest_env(self):
        """The guest's own PATH/HOME, queried once.

        Uses `printenv`, not `echo "$PATH"` -- quoting inside a `-c` string is
        exactly what Windows mangles (see run()).
        """
        if self._base is None:
            p = subprocess.run(
                self.prefix + ["bash", "-e", "-c", "printenv PATH; printenv HOME"],
                capture_output=True, text=True, timeout=120,
                encoding="utf-8", errors="replace")
            lines = (p.stdout or "").splitlines()
            path = lines[0].strip() if lines else (
                "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
            home = lines[1].strip() if len(lines) > 1 else "/root"
            # ubuntu-latest ships ~/.cargo/bin on PATH. publish.yml installs
            # typos into "${CARGO_HOME:-$HOME/.cargo}/bin" and then runs bare
            # `typos`, which works there only because of that. Without this the
            # download "succeeds" and the next step is BLOCKED -- which is at
            # least honest, but it is the harness's gap, not the runner's.
            cargo = home.rstrip("/") + "/.cargo/bin"
            if ("%s:" % cargo) not in (path + ":"):
                path = cargo + ":" + path
            self._base = {"PATH": path, "HOME": home}
        return dict(self._base)

    def env_for(self, host_env, overrides):
        e = dict(host_env)
        if self.linux:
            e.update(self.guest_env())
        e.update(overrides)
        return e

    def proc_env(self):
        """Process environment for wsl.exe itself: full Windows env, with the
        guest's own PATH/HOME layered on (a Windows PATH is not a Linux PATH)."""
        e = dict(os.environ)
        if self.linux:
            e.update(self.guest_env())
        return e

    def run(self, script, cwd, inject, timeout):
        # The script goes in over STDIN, not as `bash -c "<script>"`.
        #
        # Windows builds a command line for wsl.exe and re-quotes the arguments,
        # which strips or mangles the double quotes inside a workflow step. A
        # step reading `>> "$GITHUB_PATH"` arrived as `>> $GITHUB_PATH` and
        # bash died with "syntax error near unexpected token `newline`" --
        # a failure of the simulator's own plumbing that looked exactly like a
        # failure of the step under test. stdin has no such layer.
        #
        # Variables are `export`ed in a preamble rather than passed via the
        # process environment: wsl.exe only forwards Windows env vars listed in
        # WSLENV, so an injected GITHUB_PATH simply never arrived and the step
        # failed with "ambiguous redirect". `export` reaches the whole process
        # tree, which is what CI does anyway.
        #
        # The payload goes in as BYTES. In text mode CPython translates "\n"
        # to "\r\n" on Windows stdin, and bash does not strip the CR -- so every
        # line arrives with one stuck on the end. Measured consequences, none of
        # which look like harness plumbing:
        #   * `export K=v` gives K a value ending in \r, so a step ending
        #     `>> $GITHUB_PATH` redirects to a file named "<path>\r\r". That
        #     write SUCCEEDS -- rc 0, empty stderr -- and is then invisible to
        #     the reader, so every later step dies on "command not found" for a
        #     tool this step provably installed.
        #   * `set -x`, `wc -c`, any `cmd -flag` dies with "invalid option".
        # (`text=True` with bytes input is a TypeError in CPython's threaded
        # stdin writer, so decoding is done here instead.)
        preamble = "".join(
            "export %s=%s\n" % (k, shlex.quote(str(v)))
            for k, v in sorted(inject.items())
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k))
        cmd = self.prefix + ["bash", "-e"]
        proc = subprocess.run(cmd, cwd=cwd, input=(preamble + script).encode("utf-8"),
                              capture_output=True, timeout=timeout,
                              env=self.proc_env())
        proc.stdout = (proc.stdout or b"").decode("utf-8", "replace")
        proc.stderr = (proc.stderr or b"").decode("utf-8", "replace")
        return proc

    def available(self):
        try:
            p = subprocess.run(self.prefix + ["bash", "-e", "-c", self.probe_cmd],
                               capture_output=True, text=True, timeout=90)
            return p.returncode == 0
        except Exception:                            # noqa: BLE001
            return False


def to_wsl(path):
    """Host path -> guest path.

    IDEMPOTENT, and it has to be. Entries read back out of $GITHUB_PATH were
    written by the guest shell, so they are already guest paths; running them
    through os.path.abspath on Windows prepends the cwd and yields
    "/mnt/d/mnt/c/Users/...", which is not a directory. That breaks every PATH
    entry silently -- the tool stays "not found" while the step that installed
    it reported success. (Self-test ST5 caught it.)
    """
    p = str(path).replace("\\", "/")
    if p.startswith("/"):
        return p
    p = os.path.abspath(p).replace("\\", "/")
    if re.match(r"^([A-Za-z]):/(.*)$", p):
        return "/mnt/%s/%s" % (p[0].lower(), p[3:])
    return p


def discover_engines():
    return [
        Engine("wsl", ["wsl", "-d", "Ubuntu", "--"], to_wsl,
               probe_cmd="uname -s", linux=True),
        Engine("gitbash", [GH_BASH], None),
    ]


# --------------------------------------------------------------------------- #
# provisioning: supply the tools `uses:` steps / the runner image would supply
# --------------------------------------------------------------------------- #
# Both toolchains live under the guest's HOME, not /tmp. Measured: /tmp in this
# WSL distro does not survive a restart -- a provisioning run came back minutes
# later to find its downloaded index file gone. A venv that silently vanishes
# would turn every python-cross-check step into BLOCKED with no explanation.
PY_PKGS = "doubleml numpy pandas statsmodels scikit-learn"
_TOOL_DIRS = {}


def tool_root(engine, name):
    """A durable, per-guest directory for a provisioned toolchain."""
    if not engine.linux:
        return None
    if name not in _TOOL_DIRS:
        try:
            p = engine.run("printenv HOME", tempfile.gettempdir(), {}, 60)
            home = (p.stdout or "").strip() or "/root"
        except Exception:                            # noqa: BLE001
            home = "/root"
        _TOOL_DIRS[name] = home.rstrip("/") + "/.ci_local_" + name
    return _TOOL_DIRS[name]


PROVISION_SCRIPT = r"""
PYV={pyv}
NODEV={nodev}
PKGS="{pkgs}"

echo "--- python toolchain ---"
if [ ! -x "$PYV/bin/python" ]; then
  python3 -m venv --without-pip "$PYV" >/dev/null 2>&1 || true
fi
if ! "$PYV/bin/python" -m pip --version >/dev/null 2>&1; then
  curl -fsSL --retry 3 --retry-delay 3 https://bootstrap.pypa.io/get-pip.py \
    -o "$PYV/get-pip.py" || exit 11
  "$PYV/bin/python" "$PYV/get-pip.py" --quiet || exit 12
fi
"$PYV/bin/python" -m pip install --quiet --disable-pip-version-check $PKGS || exit 13
"$PYV/bin/python" - <<'EOF' || exit 14
import importlib
for m in ("doubleml", "numpy", "pandas", "statsmodels", "sklearn"):
    mod = importlib.import_module(m)
    print("%-11s %s" % (m, getattr(mod, "__version__", "?")))
EOF

echo "--- node toolchain ---"
# `moon test --target js` shells out to node. Without it the step dies with
# "No such file or directory (os error 2)" -- ENOENT from moon trying to spawn a
# program, which reads like a broken build rather than a missing toolchain.
if [ ! -x "$NODEV/bin/node" ]; then
  mkdir -p "$NODEV" || exit 20
  NV="$(curl -fsSL --retry 3 https://nodejs.org/dist/index.json | python3 -c 'import json,sys
d = json.load(sys.stdin)
for e in d:
    if any("linux-x64" in f for f in e.get("files", [])):
        print(e["version"]); break')" || exit 21
  [ -n "$NV" ] || exit 22
  echo "node $NV"
  curl -fsSL --retry 3 "https://nodejs.org/dist/$NV/node-$NV-linux-x64.tar.xz" \
    -o "$NODEV/node.tar.xz" || exit 23
  tar -xJf "$NODEV/node.tar.xz" -C "$NODEV" --strip-components=1 || exit 24
  rm -f "$NODEV/node.tar.xz"
fi
"$NODEV/bin/node" -v || exit 25
"""


def _provision_script(engine):
    # str.replace, not %-formatting: the script contains its own "%s" in the
    # heredoc, which %-formatting would try to consume as a placeholder.
    return (PROVISION_SCRIPT
            .replace("{pyv}", tool_root(engine, "pyenv"))
            .replace("{nodev}", tool_root(engine, "node"))
            .replace("{pkgs}", PY_PKGS))


def provisioned_bins(engine):
    """bin dirs of the toolchains that are actually present, in PATH order."""
    bins = []
    if not engine.linux:
        return bins
    for name, exe in (("node", "node"), ("pyenv", "python")):
        d = tool_root(engine, name)
        try:
            p = engine.run('test -x "%s/bin/%s" && echo yes || echo no'
                           % (d, exe), tempfile.gettempdir(), {}, 120)
        except Exception:                            # noqa: BLE001
            continue
        if (p.stdout or "").strip() == "yes":
            bins.append(d + "/bin")
    return bins


def provision(engine, verbose=True):
    """Build the guest toolchains the runner image would already provide.

    Python stands in for `actions/setup-python`; Node is what `moon test
    --target js` shells out to. Rootless: the guest has no sudo, so both are
    bootstrapped by download rather than by apt.

    Idempotent: an existing toolchain is reused, and pip is a no-op when the
    packages are already present. Returns (ok, detail).
    """
    script = _provision_script(engine)
    if verbose:
        print("provisioning %s (%s) + %s"
              % (tool_root(engine, "pyenv"), PY_PKGS,
                 tool_root(engine, "node")))
    try:
        p = engine.run(script, tempfile.gettempdir(), {}, 3600)
    except subprocess.TimeoutExpired:
        return False, "timed out after 3600s"
    out = ((p.stdout or "") + (p.stderr or "")).strip()
    if p.returncode != 0:
        return False, "rc=%s %s" % (p.returncode, out[-300:])
    if verbose and out:
        print(out)
    return True, out


# --------------------------------------------------------------------------- #
# telling "the repository is broken" apart from "this machine lacks a tool"
# --------------------------------------------------------------------------- #
MISSING_RE = re.compile(r"(?:^|\n)\s*bash:\s+line\s+\d+:\s+(\S+):\s+"
                        r"command not found")

# A step that DOWNLOADS a tool rather than invoking one. Anchored on the real
# workflow text, not on a generic "curl", so this cannot match an ordinary step
# that happens to fetch something.
#
# `check.yml`'s "Install typos" step is `curl ... | tar zxf -`, and it has no
# `--max-time`/`--retry`. Measured on this machine (2026-10): the asset CDN
# release-assets.githubusercontent.com delivered 4,350,067 of 6,365,610 bytes
# and then timed out, so `curl` exited non-zero and piped a TRUNCATED stream
# into `tar` -- which is the whole of `tar: Error is not recoverable`. That is
# a transfer failure wearing the costume of a code failure.
INSTALL_TARGETS = (
    (re.compile(r"crate-ci/typos/releases"), "typos"),
    (re.compile(r"cli\.moonbitlang\.com/install"), "moon"),
)

# Steps this tool must refuse to execute, ever.
#
# `publish.yml` runs `moon publish` and `Create GitHub Release` from plain `run:`
# steps -- not `uses:` -- so nothing structural was stopping a local "run all"
# from actually publishing a release. The docstring claimed publishing was not
# simulated; this regex is what makes that true.
UNSAFE = re.compile(
    r"moon\s+publish\b"
    r"|gh\s+release\b"
    r"|npm\s+publish\b"
    r"|MOONCAKES_RIANTR_TOKEN"
    r"|GITHUB_TOKEN"
    r"|\$\{\{\s*secrets\.",
    re.I)


def missing_tool(engine, tree, text):
    """The command bash could not find -- but only if the guest truly lacks it.

    `command not found` says nothing about the repository. On ubuntu-latest
    `python`, `pip` and `typos` all exist; on a bare WSL distro `python` does
    not. Reporting the second as a red CI run is a false accusation, and
    quietly calling it PASS is worse -- it would report coverage that does not
    exist. The honest verdict is a third one: BLOCKED, "not verified here".

    The `command -v` cross-check is what keeps this from masking a real bug: if
    the guest DOES have the command and the step still could not run it, nothing
    is returned and the step stays FAIL.
    """
    for name in MISSING_RE.findall(text or ""):
        if not re.match(r"^[A-Za-z0-9._+-]+$", name):
            continue
        try:
            p = engine.run("command -v %s || true" % shlex.quote(name),
                           tree, {}, 60)
        except Exception:                            # noqa: BLE001
            continue
        if not (p.stdout or "").strip():
            return name
    return None


def unprovisionable_tool(engine, tree, body, inject=None):
    """The tool a step exists to PROVISION, and whether it is now reachable.

    The same false accusation as `missing_tool`, reached the other way round.
    `missing_tool` catches a step that *invokes* an absent command and bash says
    so. An install step never gets that far: it fails during the transfer, so
    the error text is a curl/tar complaint with no command in it, and the step
    lands on FAIL -- which this file defines as "a real defect in the ref under
    test". Measured (2026-10), the "Install typos" step burned 807s and then
    reported exactly that on a tree whose every code gate was green.

    WHY THE MARKER ALONE DECIDES. The step is matched by an INSTALL_TARGETS
    regex, i.e. its entire body is provisioning a named tool: `mkdir`, `curl`,
    `tar`, `echo >> $GITHUB_PATH`. Nothing in such a body asserts anything
    about the repository, so its failure cannot be a defect in the ref whatever
    the cause -- a throttled CDN, a blocked host, a truncated transfer. Real
    GitHub Actions runs this step on a runner that fetches it fine.

    Note what the obvious guard gets WRONG here. "Downgrade only when the tool
    is still absent" looks safer and is not: this guest had `typos` on disk from
    an earlier successful run, so that rule would keep reporting FAIL for a
    transfer the gate does not even need. The `command -v` probe is therefore
    used for the DETAIL only -- never to decide the verdict.

    THE PROBE MUST SEE THE STEP'S OWN PATH (`inject`), not the guest default.
    Measured: `check.yml` puts the tool on PATH by appending to `$GITHUB_PATH`
    in this very step, and a later `static_code_check` finds it that way.
    Probing with the guest default instead reports "not available" while the
    tool is demonstrably reachable at `/home/ryx/.cargo/bin/typos` -- a detail
    line contradicting the run's own evidence. Passing `{}` here is exactly how
    that happened; pass the step's `inject`.
    """
    for rx, tool in INSTALL_TARGETS:
        if not rx.search(body or ""):
            continue
        reachable = False
        try:
            p = engine.run("command -v %s || true" % shlex.quote(tool),
                           tree, dict(inject or {}), 60)
            reachable = bool((p.stdout or "").strip())
        except Exception:                            # noqa: BLE001
            reachable = False
        return tool, reachable
    return None


# --------------------------------------------------------------------------- #
# a pristine checkout, which is what actions/checkout gives the runner
# --------------------------------------------------------------------------- #
def pristine_checkout(ref, dest):
    os.makedirs(dest, exist_ok=True)
    arc = os.path.join(tempfile.gettempdir(), "ci_local_%s.tar" % abs(hash(ref)))
    r = subprocess.run(["git", "archive", "-o", arc, ref], cwd=ROOT,
                       capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        raise RuntimeError("git archive %s failed: %s" % (ref, r.stderr[-300:]))
    with tarfile.open(arc) as t:
        # `filter="data"` is both the safe default and the one that stops a
        # DeprecationWarning on every run. Guarded, because the kwarg only
        # exists on 3.12+ (and recent 3.10/3.11 security releases).
        try:
            t.extractall(dest, filter="data")
        except TypeError:
            t.extractall(dest)
    # `git archive` reproduces the tracked FILES but not a repository, and
    # `actions/checkout` gives a real one -- so a workflow step is allowed to
    # rely on git being there. publish.yml does:
    #
    #     moon info --target js
    #     git diff --exit-code
    #
    # Without a repo, `git diff` answers "not a git repository" and exits 129
    # with a usage dump that names `--output`. That reads like `moon info` has
    # the wrong flags, and sends you looking at the MoonBit command instead of
    # at the harness. `git add -A` is enough: the index then holds the pristine
    # tree, so `git diff --exit-code` still means "did this step change
    # anything", which is what the step is asking.
    #
    # The config lines are load-bearing, not decoration. This index is written
    # by WINDOWS git (autocrlf=true by default here, so it normalizes CHANGELOG.md's
    # CRLF to LF in the index) and read by LINUX git (autocrlf=false), which
    # then sees the untouched CRLF worktree file as modified -- a pristine
    # checkout reporting a diff, and a gate measuring the harness instead of
    # the code. `core.fileMode false` for the same reason: the tree lives on
    # /mnt/c, where drvfs does not carry Unix permission bits.
    for cmd in (["git", "init", "-q"],
                ["git", "config", "core.autocrlf", "false"],
                ["git", "config", "core.eol", "lf"],
                ["git", "config", "core.fileMode", "false"],
                ["git", "config", "core.safecrlf", "false"],
                ["git", "add", "-A"]):
        r = subprocess.run(cmd, cwd=dest, capture_output=True, text=True,
                           timeout=900)
        if r.returncode != 0:
            raise RuntimeError("%s failed in the simulated checkout: %s"
                               % (" ".join(cmd), r.stderr[-300:]))
    try:
        os.remove(arc)
    except OSError:
        pass
    # Count the CHECKOUT, not the repository we just built inside it. Walking
    # blindly reported 982 files instead of 510 the moment `.git/` appeared --
    # the step count was measuring our own scaffolding.
    total = 0
    for root, dirs, files in os.walk(dest):
        dirs[:] = [d for d in dirs if d != ".git"]
        total += len(files)
    return total


# --------------------------------------------------------------------------- #
# workflow parsing
# --------------------------------------------------------------------------- #
def load_workflows(names=("check.yml", "publish.yml")):
    if yaml is None:
        raise SystemExit("PyYAML is required: pip install pyyaml")
    out = {}
    for n in names:
        p = os.path.join(ROOT, ".github", "workflows", n)
        if not os.path.isfile(p):
            continue
        with open(p, encoding="utf-8") as f:
            doc = yaml.safe_load(f)
        doc["__file__"] = n
        out[n] = doc
    return out


EXP = re.compile(r"\$\{\{\s*([^}]+?)\s*\}\}")

# Contexts this simulator models, and the ones it deliberately does not.
#
# `steps.*.outputs` and `needs.*.outputs` depend on outputs captured from steps
# that were skipped or refused, so there is nothing honest to substitute. Those
# steps are reported SKIP -- "not simulated" -- rather than failed, because
# calling them a defect would be a false accusation. An expression inside a
# context we DO model but cannot resolve is a genuine harness bug and is
# reported as one.
MODELLED_CTX = {"matrix", "env", "github", "job", "runner", "inputs", "vars"}
UNMODELLED_CTX = {"steps", "needs", "secrets"}


def expression_roots(text):
    roots = set()
    for m in EXP.finditer(text or ""):
        head = m.group(1).strip().split(".")
        if head:
            roots.add(head[0])
    return roots


class _AnyEmpty(dict):
    """A context node whose missing keys resolve to '' instead of failing.

    `${{ inputs.tag }}` on a `push` event is the empty string, not an error:
    workflow_dispatch inputs simply do not exist for other triggers, and
    publish.yml's own shell guards that with
    `if [ "$GITHUB_EVENT_NAME" = "workflow_dispatch" ]`. Treating the absent
    input as an unresolved expression would report a harness bug for a step
    that is behaving exactly as written.
    """

    def __missing__(self, key):
        return ""


def subst(text, ctx):
    """Resolve `${{ matrix.target }}`, `${{ env.FOO }}`, `${{ github.ref_name }}`.

    Namespaced by design. An earlier version special-cased `github` and looked
    every other key up at the top level, so `${{ matrix.target }}` never
    resolved: bash then received the literal text and died with
    "`${{ matrix.target }}`: bad substitution" -- which reads like the project
    built for the wrong target, when in fact the simulator had never expanded
    the matrix.
    """
    def rep(m):
        cur = ctx
        for part in m.group(1).strip().split("."):
            if not isinstance(cur, dict):
                return m.group(0)
            try:
                cur = cur[part]
            except KeyError:
                return m.group(0)
        return str(cur)
    return EXP.sub(rep, text)


def expand_matrix(job):
    strategy = job.get("strategy") or {}
    mat = strategy.get("matrix") or {}
    if not mat:
        return [({}, job.get("name", ""))]
    keys = [k for k, v in mat.items() if k != "include"]
    combos = [{}]
    for k in keys:
        vals = mat[k]
        combos = [dict(c, **{k: v}) for c in combos for v in vals]
    raw = job.get("name", job.get("__id", ""))
    out = []
    for c in combos:
        name = subst(raw, {"matrix": c})
        # GitHub renders a matrix job whose `name:` carries no `${{ }}` as
        # "<name> (<value>, ...)". Without this, all four moon-test jobs print
        # the identical string and `--jobs` cannot select one target.
        if not EXP.search(raw):
            name = ("%s (%s)" % (name, ", ".join(str(v) for v in c.values()))
                    if c else name)
        out.append((c, name))
    return out


# --------------------------------------------------------------------------- #
# step execution
# --------------------------------------------------------------------------- #
class StepResult:
    def __init__(self, name, status, detail="", seconds=0.0):
        self.name = name
        # PASS  ran and succeeded
        # FAIL  ran and failed -- a defect in the ref under test
        # SKIP  deliberately not simulated (a `uses:` step)
        # BLOCKED  wanted to run it, but this machine lacks a required tool;
        #          not a verdict about the repository, and never counted as
        #          coverage
        self.status = status
        self.detail = detail
        self.seconds = seconds


def _gh_file(engine, tree, kind):
    """A per-workspace path inside the guest for one of the $GITHUB_* files."""
    key = "%08x" % (abs(hash(os.path.abspath(tree))) & 0xFFFFFFFF)
    return "/tmp/ci_local_%s_%s" % (kind, key)


def github_default_env(engine, tree, job_id, workflow_name, ref_name, ref_type):
    """The GITHUB_* variables GitHub puts in EVERY step's environment.

    These are not optional decoration. publish.yml's `Resolve release version`
    reads `$GITHUB_REF_NAME` to decide what version it is about to publish:

        if [ "$GITHUB_EVENT_NAME" = "workflow_dispatch" ]; then
          tag="${{ inputs.tag }}"
        else
          tag="$GITHUB_REF_NAME"          # <-- was simply unset
        fi

    Without it the tag is empty, `case "$tag" in v*)` falls through, and the
    step exits 1 with "Release tag must use the v* format, got:" -- which reads
    like the project's release process is broken, when the variable simply was
    never provided.

    $GITHUB_ENV / $GITHUB_OUTPUT / $GITHUB_STEP_SUMMARY / $GITHUB_EVENT_PATH are
    FILE paths on a runner, and steps write to them with `>>`. They point at
    real guest files so those appends land somewhere instead of failing.
    """
    return {
        "GITHUB_ACTIONS": "true",
        "GITHUB_ACTOR": "local-sim",
        "GITHUB_TRIGGERING_ACTOR": "local-sim",
        "GITHUB_API_URL": "https://api.github.com",
        "GITHUB_GRAPHQL_URL": "https://api.github.com/graphql",
        "GITHUB_SERVER_URL": "https://github.com",
        "GITHUB_EVENT_NAME": "push",
        "GITHUB_EVENT_PATH": _gh_file(engine, tree, "github_event"),
        "GITHUB_WORKFLOW": workflow_name or "CI",
        "GITHUB_WORKFLOW_REF": "riantr/moonbit_doubleML/.github/workflows/%s"
                               % (workflow_name or "ci"),
        "GITHUB_WORKFLOW_SHA": "local-sim",
        "GITHUB_JOB": job_id,
        "GITHUB_RUN_ID": "1",
        "GITHUB_RUN_NUMBER": "1",
        "GITHUB_RUN_ATTEMPT": "1",
        "GITHUB_SHA": "local-sim",
        "GITHUB_REF": "refs/%s/%s" % ("tags" if ref_type == "tag" else "heads",
                                     ref_name),
        "GITHUB_REF_NAME": ref_name,
        "GITHUB_REF_TYPE": ref_type,
        "GITHUB_REF_PROTECTED": "false",
        "GITHUB_BASE_REF": "",
        "GITHUB_HEAD_REF": "",
        "GITHUB_REPOSITORY": "riantr/moonbit_doubleML",
        "GITHUB_REPOSITORY_ID": "0",
        "GITHUB_REPOSITORY_OWNER": "riantr",
        "GITHUB_RETENTION_DAYS": "0",
        "GITHUB_WORKSPACE": engine.host_to_guest(tree),
        "GITHUB_ENV": _gh_file(engine, tree, "github_env"),
        "GITHUB_OUTPUT": _gh_file(engine, tree, "github_output"),
        "GITHUB_PATH": _gh_file(engine, tree, "github_path"),
        "GITHUB_STEP_SUMMARY": _gh_file(engine, tree, "github_summary"),
    }


def _gh_path_file(engine, tree):
    """Where $GITHUB_PATH lives for this run: guest-local, per-workspace."""
    return _gh_file(engine, tree, "github_path")


def _read_gh_path(engine, tree):
    """Read accumulated $GITHUB_PATH entries from inside the guest."""
    path = _gh_path_file(engine, tree)
    try:
        p = engine.run('cat "%s" 2>/dev/null || true' % path, tree, {}, 180)
        return [l.strip() for l in (p.stdout or "").splitlines() if l.strip()]
    except Exception:                                # noqa: BLE001
        return []


def _step_detail(text):
    """The one line worth showing for a step.

    `moon test` on native ends by printing a source snippet
    ("    |     ^~~~~~~~"), so "last line" reports nothing useful and hides the
    only number anyone wants. Prefer the summary line when there is one.
    """
    lines = [l.strip() for l in (text or "").strip().splitlines() if l.strip()]
    if not lines:
        return ""
    for l in reversed(lines):
        if re.search(r"Total tests:|passed:|passed, failed|error:|::error", l):
            return l[:200]
    return lines[-1][:200]


def run_job(workflow_file, job_id, job, matrix_ctx, engine, tree, timeout,
            ref_name="local-sim", ref_type="branch", workflow_name=""):
    results = []
    env_extra = dict(job.get("env") or {})
    env_extra.update(matrix_ctx)
    ctx = {"matrix": dict(matrix_ctx), "env": env_extra,
           "github": {"ref_name": "local-sim", "event_name": "push",
                      "sha": "local-sim", "run_id": "1"},
           "job": {"status": "success"},
           "runner": {"os": "Linux", "arch": "X64", "name": "local-sim"},
           "inputs": _AnyEmpty(job.get("_inputs") or {}),
           "vars": {}}

    # Variables every step sees, exported by Engine.run.
    #
    # Built through env_for so a linux engine gets the GUEST's PATH/HOME. This
    # matters: exporting the Windows PATH into the distro makes `mkdir`,
    # `chmod` and `curl` unfindable, and every step then dies at exit 127 --
    # which reads as "the project is broken" rather than "the harness handed the
    # guest the wrong PATH". (Self-test ST5 caught it.)
    common = engine.env_for(dict(os.environ),
                            {k: str(v) for k, v in env_extra.items()})
    common.update(github_default_env(engine, tree, job_id, workflow_name,
                                     ref_name, ref_type))
    common["FORCE_COLOR"] = "1"
    # Stand in for what the runner image already provides: `python`/`pip` come
    # from actions/setup-python, and `moon test --target js` needs node.
    # Prepending (rather than replacing) keeps the guest's own PATH behind them.
    pbin = provisioned_bins(engine)
    if pbin:
        common["PATH"] = ":".join(pbin + [common.get("PATH", "")])

    for st in job.get("steps", []):
        name = st.get("name") or st.get("uses") or "<unnamed>"
        if "uses" in st:
            results.append(StepResult(name, "SKIP",
                                      "uses: %s (not simulated)" % st["uses"]))
            continue
        body = st.get("run")
        if body is None:
            continue
        # Refuse BEFORE substitution. After it, `${{ secrets.X }}` would come
        # back unresolved and look like a harness bug rather than the thing it
        # is.
        hit = UNSAFE.search(body)
        if hit:
            results.append(StepResult(
                name, "SKIP",
                "refused: matches %r -- this step publishes or needs a secret, "
                "and a local simulator must never do either" % hit.group(0).strip(),
                0.0))
            continue
        unm = expression_roots(body) & UNMODELLED_CTX
        if unm:
            results.append(StepResult(
                name, "SKIP",
                "not simulated: uses the %s context (step outputs), which a "
                "single-pass runner cannot supply" % "/".join(sorted(unm)), 0.0))
            continue
        body = subst(body, ctx)
        left = EXP.search(body)
        if left:
            # Fail loudly HERE rather than letting bash report
            # "bad substitution" -- which looks exactly like the project
            # built for the wrong target.
            results.append(StepResult(
                name, "FAIL",
                "SIMULATOR BUG: unresolved expression %s left in the step body"
                % left.group(0), 0.0))
            continue
        step_vars = dict(common)
        step_vars.update({k: str(v) for k, v in (st.get("env") or {}).items()})
        # Emulate GitHub's $GITHUB_PATH: a step appends to it and later steps
        # see the entry on PATH. Without this, `echo ~/.moon/bin >> $GITHUB_PATH`
        # is a no-op and the NEXT step cannot find moon -- which would look like
        # a genuine failure of the thing under test.
        #
        # The file lives INSIDE the guest, not in the workspace. Writing it to
        # /mnt/c does work, but drvfs metadata does not settle immediately: the
        # guest sees the new file and `os.walk` sees it, yet `os.path.isfile`
        # returns False for a few hundred ms afterwards. Reading it back for the
        # next step is therefore a race, and the race loses often enough to look
        # like "the tool the previous step installed is not found". Reading it
        # with `cat` from inside the guest has no such window.
        inject = dict(step_vars)
        inject["GITHUB_PATH"] = _gh_path_file(engine, tree)
        extra = _read_gh_path(engine, tree)
        if extra:
            # `os.pathsep` is ';' on the host, but PATH inside the guest is a
            # POSIX list -- joining with ';' makes every entry after the first
            # unresolvable.
            #
            # The tail is this step's own PATH, not a fresh guest_env() lookup:
            # rebuilding it from the guest default would silently drop the
            # provisioned interpreter prepended above.
            sep = ":" if engine.linux else os.pathsep
            inject["PATH"] = sep.join([engine.host_to_guest(e) for e in extra]
                                     + [inject.get("PATH")
                                        or engine.guest_env().get("PATH", "")])

        t0 = time.perf_counter()
        try:
            p = engine.run(body, tree, inject, timeout)
            rc, out, err = p.returncode, p.stdout, p.stderr
        except subprocess.TimeoutExpired:
            rc, out, err = 124, "", "timeout after %ss" % timeout
        except Exception as e:                        # noqa: BLE001
            rc, out, err = 125, "", "%s: %s" % (type(e).__name__, e)
        dt = time.perf_counter() - t0

        detail = _step_detail(out + err)
        if rc != 0:
            miss = missing_tool(engine, tree, err or out)
            if miss:
                results.append(StepResult(
                    name, "BLOCKED",
                    "not verified: local engine has no %r "
                    "(a CI runner does)" % miss, dt))
            else:
                # A step whose whole body is provisioning a tool is not a
                # verdict about the ref, whatever the cause. See the
                # function's docstring for the measurement and for why the
                # obvious "only if the tool is absent" guard is wrong.
                prov = unprovisionable_tool(engine, tree, body, inject)
                if prov:
                    tool, reachable = prov
                    results.append(StepResult(
                        name, "BLOCKED",
                        "not verified: provisioning step for %r failed, and it "
                        "only downloads tools, so it proves nothing about the "
                        "ref (a CI runner fetches it). %r is %s. %s"
                        % (tool, tool,
                           "still reachable on PATH" if reachable
                           else "not reachable afterwards, so checks needing it "
                                "will SKIP in this run",
                           detail), dt))
                else:
                    results.append(StepResult(name, "FAIL",
                                              "exit=%s %s" % (rc, detail), dt))
        else:
            results.append(StepResult(name, "PASS", detail, dt))
    return results


# --------------------------------------------------------------------------- #
# driver
# --------------------------------------------------------------------------- #
class _DryRun:
    """`--engine none`: enumerate steps, execute nothing.

    Advertised by --help, so it has to actually work; without this, `plan()`
    rejected "none" as an unknown engine and the dry-run branch in cmd_run was
    unreachable.
    """

    name = "none"
    linux = False
    prefix = []
    probe_cmd = ""

    def __init__(self, *a, **k):
        pass

    @staticmethod
    def host_to_guest(p):
        return p

    @staticmethod
    def guest_env():
        return {}

    @staticmethod
    def available():
        return True

    def run(self, *a, **k):
        raise RuntimeError("engine 'none' is a dry run; it executes nothing")


def plan(ref, jobs_filter, workflows, engine_name):
    if engine_name == "none":
        engine = _DryRun()
    else:
        engines = {e.name: e for e in discover_engines()}
        engine = engines.get(engine_name)
        if engine is None:
            raise SystemExit("unknown engine %r (have %s)"
                             % (engine_name, list(engines)))
        if not engine.available():
            raise SystemExit("engine %r is not available on this machine"
                             % engine_name)

    base = tempfile.mkdtemp(prefix="ci_local_")
    tree = os.path.join(base, "repo")
    nfiles = pristine_checkout(ref, tree)

    plan_jobs = []
    for fname, doc in workflows.items():
        for jid, job in (doc.get("jobs") or {}).items():
            for mctx, jname in expand_matrix(job):
                plan_jobs.append({
                    "file": fname, "id": jid, "job": job,
                    "ctx": mctx, "name": jname,
                })
    if jobs_filter:
        want = {x.strip() for x in jobs_filter.split(",") if x.strip()}
        plan_jobs = [j for j in plan_jobs
                     if j["id"] in want or j["name"] in want]
    return engine, tree, nfiles, plan_jobs, base


def cmd_run(args):
    workflows = load_workflows()
    engine, tree, nfiles, jobs, base = plan(args.ref, args.jobs, workflows, args.engine)

    if not args.keep:
        print("workspace: %s (%d tracked files from %s)"
              % (tree, nfiles, args.ref))
        print("engine:    %s%s" % (engine.name,
                                   "" if engine.name != "none" else " (dry run)"))
        print("jobs:      %s" % (", ".join(j["name"] for j in jobs) or "<none>"))
        print()

    failed = set()
    overall = 0
    blocked = []
    for j in jobs:
        deps = j["job"].get("needs") or []
        deps = [deps] if isinstance(deps, str) else deps
        blocked_by = [d for d in deps if d in failed]
        print("=== %s  [%s]  %s" % (j["name"], j["file"],
                                    "SKIPPED (needs %s failed)" % blocked_by
                                    if blocked_by else "running"))
        if blocked_by:
            print()
            continue
        if engine.name == "none":
            for st in j["job"].get("steps", []):
                label = st.get("name") or st.get("uses") or "<unnamed>"
                kind = "uses" if "uses" in st else "run"
                print("    %-46s [not executed: dry run]" % label)
            print()
            continue

        res = run_job(j["file"], j["id"], j["job"], j["ctx"], engine, tree,
                      args.step_timeout,
                      ref_name=args.release_tag or "local-sim",
                      ref_type="tag" if args.release_tag else "branch",
                      workflow_name=(workflows.get(j["file"]) or {}).get("name", ""))
        for r in res:
            print("    %-4s %-46s %5.1fs  %s" % (r.status, r.name[:46],
                                                 r.seconds, r.detail))
            if r.status == "FAIL":
                overall = 1
            elif r.status == "BLOCKED":
                blocked.append((j["name"], r.name))
        if any(r.status == "FAIL" for r in res):
            failed.add(j["id"])
        print()

    if not args.keep:
        shutil.rmtree(base, ignore_errors=True)
    print("=" * 72)
    if engine.name == "none":
        print("RESULT: dry run -- no step was executed, so nothing was verified")
    elif overall:
        print("RESULT: FAILURE")
    elif blocked:
        # Never "all passed" here. These steps did not run, so nothing was
        # proven about the ref -- claiming otherwise is how a simulator starts
        # lying to its owner.
        print("RESULT: NOT FULLY VERIFIED -- %d step(s) could not run here:"
              % len(blocked))
        for jn, sn in blocked:
            print("        %s / %s" % (jn, sn))
        print("        These are gaps in THIS machine, not defects in the repo.")
        print("        Run `ci_local.py provision` to close the common ones.")
    else:
        print("RESULT: all executed steps passed")
    print("not simulated: uses: steps, secrets, release publishing, and the")
    print("exact OS image (WSL Ubuntu is close to ubuntu-latest, not equal to it)")
    return overall


def cmd_list(args):
    for fname, doc in load_workflows().items():
        print("== %s (%s)" % (doc.get("name", "?"), fname))
        for jid, job in (doc.get("jobs") or {}).items():
            runs = sum(st.get("uses") is None and "run" in st
                       for st in job.get("steps", []))
            uses = sum("uses" in st for st in job.get("steps", []))
            print("   %-22s matrix=%-2d run=%-2d uses=%-2d needs=%s"
                  % (job.get("name", jid), len(expand_matrix(job)), runs, uses,
                     job.get("needs", "-")))


def cmd_selftest(args):
    """Prove the simulator detects a failing step.

    Without this, "CI passed locally" could just mean the simulator never ran
    anything -- the exact failure mode this whole project keeps hitting.
    """
    ok = []

    def check(name, cond, detail=""):
        ok.append((name, bool(cond)))
        print("  %-4s %s%s" % ("PASS" if cond else "FAIL", name,
                              ("  [%s]" % detail) if detail else ""))

    wf = {"probe.yml": {"name": "probe", "jobs": {
        "good": {"runs-on": "x", "steps": [{"name": "echo ok", "run": "echo hi"}]},
        "bad": {"runs-on": "x", "steps": [{"name": "echo bad", "run": "exit 7"}]},
        "uses_only": {"runs-on": "x", "steps": [{"name": "checkout",
                                                 "uses": "actions/checkout@v5"}]},
        "chained": {"runs-on": "x", "needs": "bad",
                    "steps": [{"name": "echo after", "run": "echo hi"}]},
    }}}
    engines = {e.name: e for e in discover_engines()}
    engine = engines.get(args.engine)
    if engine is None or not engine.available():
        print("  SKIP  engine %s unavailable; cannot self-test here"
              % (args.engine if engine else "?"))
        return 0

    base = tempfile.mkdtemp(prefix="ci_local_st_")
    tree = os.path.join(base, "r")
    os.makedirs(tree, exist_ok=True)
    try:
        r = run_job("probe.yml", "good", wf["probe.yml"]["jobs"]["good"], {},
                    engine, tree, 120)
        check("ST1 passing step -> PASS", r[0].status == "PASS", r[0].status)

        r = run_job("probe.yml", "bad", wf["probe.yml"]["jobs"]["bad"], {},
                    engine, tree, 120)
        check("ST2 failing step (exit 7) -> FAIL", r[0].status == "FAIL", r[0].status)
        check("ST3 exit code is preserved, not swallowed",
              "exit=7" in r[0].detail, r[0].detail)

        r = run_job("probe.yml", "u", wf["probe.yml"]["jobs"]["uses_only"], {},
                    engine, tree, 120)
        check("ST4 uses: step -> SKIP, never a silent PASS",
              r[0].status == "SKIP", r[0].status)

        # GITHUB_PATH emulation: a step installs a tool, the next must RUN it.
        #
        # The fixture must install a real executable, not `echo probe > probe_tool`.
        # That writes the literal text `probe`, so bash resolves the tool off PATH
        # and then dies with "probe: command not found" -- a FAIL that blames
        # $GITHUB_PATH for a fixture that never installed anything runnable.
        # Running it (rather than `command -v`) is also the stronger assertion:
        # it fails both when PATH is not honoured and when the entry is garbage.
        wf2 = {"p.yml": {"jobs": {"gp": {"steps": [
            {"name": "install",
             "run": 'mkdir -p "$PWD/toolbin" && '
                    'printf \'#!/bin/sh\\necho probe-ran\\n\' > "$PWD/toolbin/probe_tool" && '
                    'chmod +x "$PWD/toolbin/probe_tool" && '
                    'echo "$PWD/toolbin" >> $GITHUB_PATH'},
            {"name": "use", "run": "probe_tool"},
        ]}}}}
        res = run_job("p.yml", "gp", wf2["p.yml"]["jobs"]["gp"], {}, engine, tree, 120)
        check("ST5 $GITHUB_PATH makes a tool visible to the NEXT step",
              len(res) == 2 and res[0].status == "PASS" and res[1].status == "PASS",
              " / ".join(x.status for x in res))
        # Control: the same job WITHOUT the $GITHUB_PATH line must FAIL. Without
        # this, ST5 would also pass on a harness that ignored PATH entirely.
        wf3 = {"p.yml": {"jobs": {"gp": {"steps": [
            {"name": "install",
             "run": 'mkdir -p "$PWD/toolbin2" && '
                    'printf \'#!/bin/sh\\necho probe-ran\\n\' > "$PWD/toolbin2/probe_tool2" && '
                    'chmod +x "$PWD/toolbin2/probe_tool2"'},
            {"name": "use", "run": "probe_tool2"},
        ]}}}}
        res3 = run_job("p.yml", "gp", wf3["p.yml"]["jobs"]["gp"], {}, engine, tree, 120)
        # Without the $GITHUB_PATH line the tool is genuinely not on PATH, so
        # ST5 could not be passing vacuously. Which non-PASS verdict it gets is
        # the taxonomy's business (BLOCKED, since the guest really has no such
        # command) -- what must never happen is PASS.
        check("ST5c control: no $GITHUB_PATH line -> tool NOT visible -> not PASS",
              len(res3) == 2 and res3[1].status != "PASS",
              " / ".join(x.status for x in res3))

        # A missing tool is a gap in THIS machine, not a defect in the ref.
        # Both arms are required: without the control, BLOCKED could quietly
        # absorb genuine failures and the simulator would report coverage it
        # never produced.
        wf4 = {"p.yml": {"jobs": {"absent": {"steps": [
            {"name": "absent tool", "run": "ci_local_absent_tool_xyz"},
        ]}}}}
        res4 = run_job("p.yml", "absent", wf4["p.yml"]["jobs"]["absent"], {},
                       engine, tree, 120)
        check("ST6 missing tool -> BLOCKED, not FAIL",
              len(res4) == 1 and res4[0].status == "BLOCKED",
              res4[0].status if res4 else "?")

        wf5 = {"p.yml": {"jobs": {"present": {"steps": [
            {"name": "present tool that fails", "run": "bash -c 'exit 3'"},
        ]}}}}
        res5 = run_job("p.yml", "present", wf5["p.yml"]["jobs"]["present"], {},
                       engine, tree, 120)
        check("ST6c control: tool EXISTS and fails -> still FAIL",
              len(res5) == 1 and res5[0].status == "FAIL",
              res5[0].status if res5 else "?")

        # A step that only PROVISIONS a tool cannot testify about the ref. Real
        # instance: `Install typos` failed twice in a row here with
        # `tar: Error is not recoverable` -- a transfer that delivered 68% of
        # the tarball and then timed out -- on a tree whose every code gate was
        # green. It was reported as FAIL, which is a false accusation.
        #
        # Network-free on purpose: `mkdir -p /nonexistent-parent-xyz` fails
        # instantly, so the arm measures the VERDICT, not this machine's CDN.
        # ST12, not ST8: ST8/ST8c are already the publish-refusal pair below.
        # Duplicate self-test ids are not a cosmetic problem -- if either ST8
        # ever goes red you could not tell which one from the report.
        wf8 = {"p.yml": {"jobs": {"prov": {"steps": [
            {"name": "install",
             "run": "mkdir -p /nonexistent-parent-xyz && "
                    "curl -LsSf https://github.com/crate-ci/typos/releases/"
                    "download/v1.19.0/typos-v1.19.0-x86_64-unknown-linux-musl.tar.gz"
                    " | tar zxf - -C /nonexistent-parent-xyz"},
        ]}}}}
        res8 = run_job("p.yml", "prov", wf8["p.yml"]["jobs"]["prov"], {},
                       engine, tree, 120)
        check("ST12 provisioning step fails -> BLOCKED, not FAIL",
              len(res8) == 1 and res8[0].status == "BLOCKED",
              res8[0].status if res8 else "?")

        # The control that keeps ST12 honest: a failing step that merely CONTAINS
        # a curl, but provisions nothing, must still be FAIL. Without this the
        # downgrade would be reachable by any step mentioning a download.
        wf8c = {"p.yml": {"jobs": {"notprov": {"steps": [
            {"name": "curl but no provisioning target",
             "run": "curl --help > /dev/null && exit 7"},
        ]}}}}
        res8c = run_job("p.yml", "notprov", wf8c["p.yml"]["jobs"]["notprov"], {},
                        engine, tree, 120)
        check("ST12c control: a curl step that provisions nothing -> still FAIL",
              len(res8c) == 1 and res8c[0].status == "FAIL",
              res8c[0].status if res8c else "?")

        # Matrix expansion. This regressed silently: `${{ matrix.target }}` was
        # never resolved, so all four jobs ran the literal text and bash reported
        # "bad substitution" -- four FAILs that read like the project built for
        # the wrong backend.
        wf6 = {"probe.yml": {"jobs": {"m": {
            "name": "build", "strategy": {"matrix": {"target": ["native", "js"]}},
            "steps": [{"name": "Build", "run": "echo target=${{ matrix.target }}"}],
        }}}}
        combos = expand_matrix(wf6["probe.yml"]["jobs"]["m"])
        check("ST7 matrix expands to one job per value, each with a distinct name",
              [n for _, n in combos] == ["build (native)", "build (js)"],
              " / ".join(n for _, n in combos))
        r6 = run_job("probe.yml", "m", wf6["probe.yml"]["jobs"]["m"],
                     combos[0][0], engine, tree, 120)
        check("ST7c ${{ matrix.target }} is substituted into the step body",
              len(r6) == 1 and r6[0].status == "PASS" and "target=native" in r6[0].detail,
              "%s [%s]" % (r6[0].status if r6 else "?", r6[0].detail if r6 else ""))
        # Control: an expression with nothing behind it must be refused outright,
        # not handed to bash.
        wf7 = {"probe.yml": {"jobs": {"u": {
            "steps": [{"name": "Build", "run": "echo ${{ matrix.nope }}"}],
        }}}}
        r7 = run_job("probe.yml", "u", wf7["probe.yml"]["jobs"]["u"], {},
                     engine, tree, 120)
        check("ST7d control: unresolved ${{ }} -> FAIL, never passed to bash",
              len(r7) == 1 and r7[0].status == "FAIL"
              and "SIMULATOR BUG" in r7[0].detail,
              "%s [%s]" % (r7[0].status if r7 else "?", r7[0].detail if r7 else ""))

        # The one that matters most: a simulator whose whole value is being a
        # SAFE stand-in for CI must never publish a release. `publish.yml` runs
        # `moon publish` from a plain `run:` step, so nothing structural stops
        # a local "run --all" from shipping one.
        wf8 = {"probe.yml": {"jobs": {"pub": {"steps": [
            {"name": "Publish to Mooncakes", "run": "moon publish --yes"},
        ]}}}}
        r8 = run_job("probe.yml", "pub", wf8["probe.yml"]["jobs"]["pub"], {},
                     engine, tree, 120)
        check("ST8 publishing step is REFUSED, never executed",
              len(r8) == 1 and r8[0].status == "SKIP"
              and "refused" in r8[0].detail,
              "%s [%s]" % (r8[0].status if r8 else "?", r8[0].detail if r8 else ""))
        # Control: prose that merely mentions publishing must still run, or the
        # guard would swallow ordinary steps.
        wf9 = {"probe.yml": {"jobs": {"talk": {"steps": [
            {"name": "mention", "run": "echo publish is documented in CHANGELOG"},
        ]}}}}
        r9 = run_job("probe.yml", "talk", wf9["probe.yml"]["jobs"]["talk"], {},
                     engine, tree, 120)
        check("ST8c control: prose mentioning publish still runs -> PASS",
              len(r9) == 1 and r9[0].status == "PASS",
              "%s [%s]" % (r9[0].status if r9 else "?", r9[0].detail if r9 else ""))

        # The simulated checkout must be a REPOSITORY, not just a file tree.
        # publish.yml runs `moon info --target js` then `git diff --exit-code`;
        # without a .git, git answers "not a git repository" and exits 129 with
        # a usage dump naming `--output`, which reads like the moon command had
        # the wrong flags.
        #
        # This has to run against pristine_checkout()'s output, not the shared
        # scratch `tree` above -- that one is just an empty mkdir, so asserting
        # on it would test nothing.
        rtree = os.path.join(base, "r_repo")
        try:
            pristine_checkout("HEAD", rtree)
            r10 = engine.run("git rev-parse --is-inside-work-tree 2>&1 || true",
                             rtree, {}, 180)
            check("ST9 simulated checkout is a real git repository",
                  (r10.stdout or "").strip() == "true",
                  (r10.stdout or "").strip()[:80])
            r11 = engine.run(
                'git diff --exit-code && echo CLEAN || echo DIRTY',
                rtree, {}, 300)
            check("ST9c control: pristine tree -> git diff --exit-code is clean",
                  (r11.stdout or "").strip().endswith("CLEAN"),
                  (r11.stdout or "").strip()[-60:])
            # The other half: it must still DETECT a change, or "always clean"
            # would be a check that cannot fail.
            with open(os.path.join(rtree, "README.mbt.md"), "a",
                      encoding="utf-8") as f:
                f.write("\nst9 drift\n")
            # `&&`/`||`, not `;`: under `bash -e` a `;` does NOT protect a
            # failing command, so `git diff --exit-code; echo rc=$?` never
            # reaches the echo when there IS a diff.
            r11b = engine.run(
                'git diff --exit-code && echo CLEAN || echo DIRTY',
                rtree, {}, 300)
            check("ST9d control: a modified file -> git diff --exit-code is dirty",
                  (r11b.stdout or "").strip().endswith("DIRTY"),
                  (r11b.stdout or "").strip()[-60:])
        finally:
            shutil.rmtree(rtree, ignore_errors=True)

        # A `steps.*.outputs` reference depends on outputs from steps this
        # runner skipped. There is nothing honest to substitute, so it must be
        # SKIP -- failing it would be a false accusation against the project.
        wf10 = {"probe.yml": {"jobs": {"so": {"steps": [
            {"name": "Release", "run": "echo tag=${{ steps.release.outputs.tag }}"},
        ]}}}}
        r12 = run_job("probe.yml", "so", wf10["probe.yml"]["jobs"]["so"], {},
                      engine, tree, 120)
        check("ST10 steps.*.outputs -> SKIP (not simulated), not FAIL",
              len(r12) == 1 and r12[0].status == "SKIP",
              "%s [%s]" % (r12[0].status if r12 else "?",
                           r12[0].detail if r12 else ""))
        # And the publish.yml shape: `${{ inputs.tag }}` must resolve to empty
        # rather than being reported as a harness bug.
        wf11 = {"probe.yml": {"jobs": {"tag": {"steps": [
            {"name": "Resolve", "run": 'tag="${{ inputs.tag }}"; echo "[$tag]"'},
        ]}}}}
        r13 = run_job("probe.yml", "tag", wf11["probe.yml"]["jobs"]["tag"], {},
                      engine, tree, 120)
        check("ST10c control: ${{ inputs.tag }} resolves (empty), step runs",
              len(r13) == 1 and r13[0].status == "PASS"
              and "[]" in r13[0].detail,
              "%s [%s]" % (r13[0].status if r13 else "?",
                           r13[0].detail if r13 else ""))

        # The GITHUB_* default environment. publish.yml's release step reads
        # $GITHUB_REF_NAME, and with it unset the tag resolves to empty and the
        # job dies with "Release tag must use the v* format, got:" -- which
        # looks like the project's release process is broken.
        wf12 = {"probe.yml": {"jobs": {"tag": {"steps": [
            {"name": "Resolve", "run": 'case "$GITHUB_REF_NAME" in v*) '
                                       'echo "ok ${GITHUB_REF_NAME#v}" ;; '
                                       '*) echo "bad: $GITHUB_REF_NAME" >&2; '
                                       'exit 1 ;; esac'},
        ]}}}}
        r14 = run_job("probe.yml", "tag", wf12["probe.yml"]["jobs"]["tag"], {},
                      engine, tree, 120, ref_name="v9.9.9", ref_type="tag")
        check("ST11 $GITHUB_REF_NAME is set, and a v* tag resolves",
              len(r14) == 1 and r14[0].status == "PASS"
              and "ok 9.9.9" in r14[0].detail,
              "%s [%s]" % (r14[0].status if r14 else "?",
                           r14[0].detail if r14 else ""))
        # Control: the same body with no tag configured must FAIL, proving the
        # assertion above is not passing vacuously.
        r15 = run_job("probe.yml", "tag", wf12["probe.yml"]["jobs"]["tag"], {},
                      engine, tree, 120, ref_name="local-sim",
                      ref_type="branch")
        check("ST11c control: non-tag ref_name -> the same step FAILS",
              len(r15) == 1 and r15[0].status == "FAIL",
              "%s [%s]" % (r15[0].status if r15 else "?",
                           r15[0].detail if r15 else ""))
    finally:
        shutil.rmtree(base, ignore_errors=True)

    bad = [n for n, c in ok if not c]
    print("-" * 70)
    print("%d/%d local-simulator self-tests passed" % (len(ok) - len(bad), len(ok)))
    if bad:
        print("FAILED: " + ", ".join(bad))
    return 1 if bad else 0


def cmd_provision(args):
    """Install the guest tools that `uses:` steps supply on the runner.

    Rootless on purpose: the guest has no sudo and this Ubuntu build strips
    `ensurepip`, so this goes through get-pip.py. Safe to re-run.
    """
    engines = {e.name: e for e in discover_engines()}
    engine = engines.get(args.engine)
    if engine is None or not engine.available():
        print("engine %r is not available on this machine" % args.engine)
        return 1
    if engine.name == "gitbash":
        print("provisioning is only implemented for the wsl engine; "
              "Git Bash already has python on PATH.")
        return 0
    ok, detail = provision(engine)
    if not ok:
        print("PROVISIONING FAILED:", detail)
        return 1
    # Verify the way run_job will actually use it: with the toolchains on PATH.
    # Checking without that prepend proves nothing and silently prints an empty
    # result, which reads like success.
    pbin = provisioned_bins(engine)
    if not pbin:
        print("PROVISIONING FAILED: no provisioned toolchain is executable")
        return 1
    path = ":".join(pbin + [engine.guest_env().get("PATH", "")])
    p = engine.run("command -v python; command -v pip; python -V;"
                   " command -v node; node -v",
                   tempfile.gettempdir(), {"PATH": path}, 120)
    print("ok -- with %s on PATH:" % ", ".join(pbin))
    for line in (p.stdout or "").strip().splitlines():
        print("  " + line)
    if not (p.stdout or "").strip():
        print("  (no output; stderr: %s)" % (p.stderr or "").strip()[:200])
        return 1
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="Local GitHub Actions CI simulation")
    ap.add_argument("cmd", choices=["list", "provision", "run", "selftest"])
    ap.add_argument("--ref", default="HEAD", help="ref to check out (default HEAD)")
    ap.add_argument("--release-tag", default="",
                    help="set $GITHUB_REF_NAME to this tag (e.g. v0.163.0); "
                         "publish.yml's 'Resolve release version' reads it, and "
                         "without a tag that step fails on 'got:'")
    ap.add_argument("--jobs", default="", help="comma-separated job names/ids")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--engine", default="wsl",
                    choices=["wsl", "gitbash", "none"])
    ap.add_argument("--step-timeout", type=int, default=2400)
    ap.add_argument("--keep", action="store_true", help="keep the workspace")
    args = ap.parse_args(argv)
    if args.all:
        args.jobs = ""
    if args.cmd == "list":
        return cmd_list(args)
    if args.cmd == "selftest":
        return cmd_selftest(args)
    if args.cmd == "provision":
        return cmd_provision(args)
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
