"""Shared environment for the LPLR upstream-comparison scripts.

Two facts these scripts used to hide, and that this module makes explicit:

  * The repository root used to be a hard-coded absolute path
    (`D:\\src\\MiniMax\\...`), so a clone of the repository could not run any
    of them. It is now derived from this file's own location.

  * The scripts prepend a VENDORED upstream sdist
    (`_verify/_upstream_ps/doubleml-0.11.4`) to `sys.path`. That tree is a
    1.1 MB vendored artefact and is deliberately NOT committed -- a clone
    does not have it. When it is absent the scripts fall back to whatever
    `doubleml` is INSTALLED, which is a different upstream version and can
    therefore produce different numbers. That fallback used to be silent;
    `use_vendored_upstream()` now says out loud which upstream a run used.

`REPO` is the repository root (the parent of `_verify/`).
"""

import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERIFY = os.path.join(REPO, "_verify")
VENDORED_VERSION = "0.11.4"
VENDORED = os.path.join(VERIFY, "_upstream_ps", "doubleml-" + VENDORED_VERSION)

# The raw logs these scripts read and write.  They live in a SUBDIRECTORY
# because `_verify/*.log` is gitignored, and a log that a record CITES has to
# be openable by whoever clones the repository.
LOGDIR = os.path.join(VERIFY, "_lplr_r17_1680")
PORT_DUMP = os.path.join(LOGDIR, "_port_dump_1680.log")
FUZZ_RUN_LOG = os.path.join(LOGDIR, "_fuzz_run_1680.log")

_announced = False


def use_vendored_upstream():
    """Prepend the vendored upstream sdist if it is present, and say which
    upstream the run is about to use.  Returns the upstream's version
    string, or None when no `doubleml` is importable at all.

    These scripts import each other, so this can be reached several times in
    one process; the banner is printed once."""
    global _announced
    used_vendored = os.path.isdir(VENDORED)
    if used_vendored:
        sys.path.insert(0, VENDORED)
    try:
        import doubleml
    except Exception as e:  # pragma: no cover
        if not _announced:
            _announced = True
            print("upstream: NOT IMPORTABLE (%s)" % e)
            print("         the script will report SKIP rather than a measurement")
        return None
    where = getattr(doubleml, "__file__", "?")
    if not _announced:
        _announced = True
        print("upstream: doubleml %s" % getattr(doubleml, "__version__", "?"))
        print("         from %s" % where)
        if used_vendored:
            print("         via the VENDORED sdist (doubleml-%s) at %s"
                  % (VENDORED_VERSION, VENDORED))
        else:
            print("         the VENDORED sdist (doubleml-%s) is NOT present --" % VENDORED_VERSION)
            print("         this run uses the INSTALLED doubleml, which may be a")
            print("         different version from the one the record's numbers")
            print("         were measured against.")
    return getattr(doubleml, "__version__", None)
