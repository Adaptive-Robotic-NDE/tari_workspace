#!/usr/bin/env bash
#
# Build and install the dataguzzler-python side of the workspace.
#
# These are ordinary Python distributions, not ROS packages, so colcon has
# nothing to do with them -- colcon owns ros_ws/src and nothing else. This
# script owns everything at the workspace root.
#
# Every package is installed system-wide, with no dependency resolution and no
# build isolation, and never as an editable install:
#
#     sudo python3 -m pip install --no-deps --no-build-isolation .
#
# A consequence worth stating plainly: editing a source file changes nothing
# until you reinstall, and there is no error to tell you so. That is intended.
# --check exists for exactly that -- every package carries a setuptools_scm
# version embedding the commit it was built from, so what is actually installed
# is answerable without guessing.
#
#   ./dgpy_install.sh --check              what is stale, install nothing
#   ./dgpy_install.sh                      install everything that is stale
#   ./dgpy_install.sh --only spatialnde2   just that one
#   ./dgpy_install.sh --from dataguzzler-python   that one and everything after
#   ./dgpy_install.sh --force              reinstall even if current
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${DGPY_PYTHON:-python3}"

# Install order is dependency order. spatialnde2 first because
# dataguzzler-python imports it; dataguzzler-python before the modules
# because every module is written against its Module metaclass.
#
# Format: <directory>|<distribution name>
PACKAGES=(
    "spatialnde2|spatialnde2"
    "dataguzzler-python|dataguzzler-python"
    "dgpython-param-manager|dgpython_param_manager"
    "dgpython-local|dgpython-local"
    "dgpython-azurekinect|dgpython-azurekinect"
    "dgpython-nidaqmx|dgpython_nidaqmx"
    "dgpython-uniwest|dgpython_uniwest"
    "dgpython-opencv-camera|dgpython_opencv_camera"
)

# Not installed by default. These are Cython extensions that do `import
# spatialnde2` at build time, so they need spatialnde2 installed first and a
# working compiler.
#
# Format: <directory>|<distribution name>|required|optional
#
# THE THIRD FIELD DECIDES WHAT A FAILED BUILD COSTS, and the two extras here
# genuinely differ:
#
#   required  Something that runs here imports it unconditionally, so a machine
#             without it has a broken capability rather than a smaller one. The
#             failure is fatal: the script exits 1, loudly, naming it.
#
#             spatialnde2-ec-functions is this. ec_acquisition.dpi imports
#             spatialnde2_ec_functions at its top and will not load without it,
#             so an eddy-current scan does not merely lose a feature, it does
#             not start. Skipping it quietly would move the failure from a
#             compiler error here to an ImportError in the middle of a scan
#             config, which is much harder to read. It is an extra rather than a
#             package only because it costs a compile and is useless on a
#             machine that does no eddy current -- but a machine that imported
#             the manifest declaring it has asked for it.
#
#   optional  Nothing that has to work imports it. The failure is a WARNING: the
#             remaining extras and everything else still install, and the script
#             exits 2 rather than 1 so that a caller can tell "the stack is
#             installed, one optional extra is not" from "the install failed".
#             tari.bash's python phase carries on for 2 and stops for 1.
#
#             spatialnde2_cpp_calibration_function is this. It provides an
#             OpenCV camera-calibration math function, and the only thing that
#             imports it is dgpython-opencv-camera's own camera.dgp demo. A
#             machine with no OpenCV development package cannot build it and has
#             no use for it; making that fatal means a bootstrap of the hardware
#             layer can never complete even though every instrument module built.
EXTRAS=(
    "dgpython-opencv-camera/spatialnde2_cpp_calibration_function|spatialnde2_cpp_calibration_function|optional"
    "spatialnde2-ec-functions|spatialnde2_ec_functions|required"
)

# Exit status when every package and every required extra installed but an
# optional extra did not. Distinct from 1 so that a failed optional extra is
# neither silent nor mistaken for a failed install.
EXIT_OPTIONAL_EXTRA_FAILED=2

# Packages whose installed copy is checked by importing it, not only by comparing
# version strings. See package_status() for why it is these two and no others.
declare -A IMPORT_PROBE=(
    [spatialnde2]=spatialnde2
    [dataguzzler-python]=dataguzzler_python
)

# ---------------------------------------------------------------------------
# Per-package build environment.
#
# The install command does not change -- same array, same flags, same `.`. What
# changes is one environment variable the build needs, passed through sudo
# explicitly because sudo runs with env_reset and drops everything else.
#
# spatialnde2-ec-functions: its setup.py calls Cython's cythonize(), and
# `from Cython.Build import cythonize` pulls in numpy.distutils, which replaces
# distutils.ccompiler.new_compiler with its own. Against a setuptools new enough
# to have rewritten its vendored distutils (Ubuntu 22.04's numpy 1.21 with
# setuptools >= 80, which is what a machine ends up with once anything has
# upgraded it) numpy's version calls the new Compiler with the old signature:
#
#     File ".../numpy/distutils/ccompiler.py", line 771, in new_compiler
#       compiler = klass(None, dry_run, force)
#     TypeError: Compiler.__init__() takes from 1 to 3 positional arguments but
#               4 were given
#
# SETUPTOOLS_USE_DISTUTILS=stdlib makes `distutils` the standard library's, whose
# CCompiler signature is the one numpy.distutils was written against, and the
# build succeeds. It is still set even though ensure_build_prereqs now holds
# setuptools below 80 (see SETUPTOOLS_CEILING there): the variable is also what
# makes these three build on the Arch host, and it costs nothing where the
# vendored distutils would have worked anyway.
# ---------------------------------------------------------------------------
#
# dgpython-azurekinect: the same fault, from the same cause. Its setup.py calls
# cythonize() for dgpython_azurekinect/kinect.pyx, so numpy.distutils gets
# imported and patches new_compiler in exactly the same way, and the build dies
# with the same TypeError at the same numpy/distutils/ccompiler.py:771. It is
# not an extra, so nothing had ever passed the variable to it.
# ---------------------------------------------------------------------------
#
# spatialnde2_cpp_calibration_function: the third case, and it hid behind the
# fact that the extra could not be built at all until its setup.py was fixed.
# It cythonizes calibration_function.pyx exactly as its sibling extra does, so
# it fails at the same numpy/distutils/ccompiler.py:771. Measured on
# 2026-09-30: `pip wheel` with the variable set succeeds and the identical
# command without it dies with the TypeError, so the key is what separates an
# optional extra that builds on Ubuntu 22.04 from one that reports itself
# unbuildable. Note that the key is the DIRECTORY as EXTRAS spells it, path and
# all -- BUILD_ENV is looked up by the first field of the entry, not by the
# distribution name.
# ---------------------------------------------------------------------------
declare -A BUILD_ENV=(
    [spatialnde2-ec-functions]="SETUPTOOLS_USE_DISTUTILS=stdlib"
    [dgpython-azurekinect]="SETUPTOOLS_USE_DISTUTILS=stdlib"
    [dgpython-opencv-camera/spatialnde2_cpp_calibration_function]="SETUPTOOLS_USE_DISTUTILS=stdlib"
)

MODE=install
SELECT=all
SELECT_ARG=""
FORCE=0
DRYRUN=0
WITH_EXTRAS=0
ALLOW_DIRTY=0

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1m%s\033[0m\n' "$*"; }
# Advisory, and it must return 0. report_foreign_install ends in a warn, and
# under `set -e` a function whose last command fails takes the whole script
# down -- which is exactly what happened on the first machine that had a
# foreign install to report: the script exited 127 with no output and no
# explanation, because warn did not exist yet.
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; return 0; }

usage() {
    sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --check              report drift for every package; install nothing
  --list               print the install order and exit
  --only NAME          operate on one package only
  --from NAME          operate on NAME and every package after it
  --force              reinstall even when the installed copy is current
  --with-extras        also build the optional Cython extras
  --allow-dirty        with --check, do not fail on DIRTY (see below)
  -n, --dry-run        print the pip commands without running them
  --python PYTHON      interpreter to install into (default: python3,
                       override with DGPY_PYTHON)
  -h, --help           this message

Exit status:
  0  everything requested succeeded; with --check, everything is current
  1  a build or install failed; with --check, something is stale or missing
     (--allow-dirty excludes DIRTY from that, for the one caller that built the
     install from the very tree being called dirty -- see the case below)
  2  every package and every REQUIRED extra installed, but an OPTIONAL extra
     did not. The stack is usable; one thing nothing depends on is missing.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)       MODE=check ;;
        --list)        MODE=list ;;
        --only)        SELECT=only; SELECT_ARG="${2:?--only needs a package name}"; shift ;;
        --from)        SELECT=from; SELECT_ARG="${2:?--from needs a package name}"; shift ;;
        --force)       FORCE=1 ;;
        --with-extras) WITH_EXTRAS=1 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        -n|--dry-run)  DRYRUN=1 ;;
        --python)      PY="${2:?--python needs an interpreter}"; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

command -v "$PY" >/dev/null 2>&1 || die "interpreter not found: $PY"

# ---------------------------------------------------------------------------
# The one form in which a package here is ever installed. Built once, after the
# options are parsed (--python changes $PY), and used both to run an install and
# to print one under --dry-run, so the two cannot describe different things.
#
#   sudo                  system-wide. An unprivileged install lands in the
#                         invoking user's ~/.local, which precedes the system
#                         directories on sys.path -- so that copy shadows the
#                         deliberately installed one and silently becomes the
#                         code that runs, for every shell and every service.
#   "$PY" -m pip          pip under the interpreter this script selected. Bare
#                         `sudo pip` resolves pip from root's PATH, which may
#                         belong to a different Python; the package would then
#                         be installed for an interpreter nobody asked about.
#   --no-deps             pip resolves nothing, so it cannot substitute a
#                         version nobody chose for one this stack was built
#                         against.
#   --no-build-isolation  the compiled parts build against the interpreter and
#                         headers actually present, rather than against a
#                         throwaway environment pip would assemble.
#
# Never editable, and never --user. An editable install makes what runs depend
# on the state of a working tree rather than on something deliberately
# installed, so a stale checkout becomes the running code with nothing to say
# so. A source edit not taking effect until reinstall is the intended
# behaviour; --check is how that drift is found.
# ---------------------------------------------------------------------------
SUDO=(sudo)
# Already root -- inside a container image build, say -- where sudo need not
# exist. What the rule requires is a system-wide install, which this already is.
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    SUDO=()
fi
PIP_INSTALL=("${SUDO[@]}" "$PY" -m pip install --no-deps --no-build-isolation)

require_privilege() {
    [[ ${#SUDO[@]} -eq 0 ]] && return 0
    command -v sudo >/dev/null 2>&1 || die "sudo not found, and this is not root.
   Installs here are system-wide; there is no per-user fallback on purpose.
   Run this as root, or on a machine where sudo is available."
    return 0
}

# ---------------------------------------------------------------------------
# Guard: this script must never install anything colcon owns.
#
# A package.xml means colcon builds it, and a pip install of the same source
# then puts a second copy on PYTHONPATH where the colcon one shadows it -- you
# edit one and run the other. That failure has occurred at two different
# levels. It is cheap to make impossible.
# ---------------------------------------------------------------------------
assert_not_a_ros_package() {
    local dir="$1"
    [[ -e "$ROOT/$dir/package.xml" ]] && die \
        "$dir has a package.xml, so colcon owns it. Refusing to pip install it.
   If it genuinely is not a ROS package, delete the package.xml. If it is,
   remove it from PACKAGES in this script and let 'colcon build' handle it."
    case "$dir" in
        ros_ws/*) die "$dir is inside ros_ws. colcon owns everything there." ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Guard: never install over another project's copy.
#
# Everything here installs system-wide, and none of these distribution names
# belongs to this repository alone -- spatialnde2 and dataguzzler-python are
# shared upstream projects, and a lab machine can perfectly well be running a
# second, unrelated experiment off its own checkout of them.
#
# That is not hypothetical. A machine was observed running spatialnde2 and
# dataguzzler-python built from /usr/local/src for another project, from
# different remotes than this repository's, with two of that project's own
# dgpython modules depending on them. Both installed versions carried a
# setuptools_scm .dYYYYMMDD suffix, meaning they were built from dirty trees --
# which package_status() classifies as STALE. So this script would have
# reinstalled over them without being asked to, and --force was not required:
# the clobber was the default behaviour.
#
# pip records the source directory of a local install in
# dist-info/direct_url.json. If it is outside this repository, the installed copy
# is somebody else's and we stop.
# ---------------------------------------------------------------------------
foreign_install_origin() {
    # Prints the origin directory if the installed dist came from a source tree
    # outside $ROOT; prints nothing at all otherwise (not installed, installed
    # from a wheel or an index, or installed from here).
    "$PY" - "$1" "$ROOT" <<'PYEOF' 2>/dev/null
import json, os, sys
from importlib.metadata import distribution, PackageNotFoundError
from urllib.parse import unquote, urlparse

name, root = sys.argv[1], os.path.realpath(sys.argv[2])
try:
    dist = distribution(name)
except PackageNotFoundError:
    sys.exit(0)
try:
    raw = dist.read_text("direct_url.json")
except Exception:
    raw = None
if not raw:
    sys.exit(0)
url = (json.loads(raw) or {}).get("url", "")
if not url.startswith("file://"):
    sys.exit(0)
path = os.path.realpath(unquote(urlparse(url).path))
if path != root and not path.startswith(root + os.sep):
    print(path)
PYEOF
}

report_foreign_install() {
    # A package already installed from a source tree that is not this repository.
    #
    # THIS IS A NOTE, NOT A GATE, and deliberately so. Converging
    # dataguzzler-python and spatialnde2 onto one version everywhere is the point
    # of this script: the copies found in the wild are earlier versions of the
    # same code, and installing over them is the intended outcome rather than
    # collateral damage. A guard that refused would block the whole purpose.
    #
    # It is still worth saying out loud which tree the previous copy came from,
    # because on a shared machine somebody else may be running against it and
    # will want to know it moved.
    #
    # Note that spatialnde2, dataguzzler-python and several dgpython modules
    # legitimately have isuthermography remotes rather than the ROS side's
    # Adaptive-Robotic-NDE. An isuthermography origin is correct and is not a
    # sign of another project's package.
    local dist="$1" origin
    origin="$(foreign_install_origin "$dist")"
    [[ -n "$origin" ]] || return 0
    warn "$dist was installed from $origin, not from $ROOT -- replacing it."
}

# ---------------------------------------------------------------------------
# Drift detection
#
# setuptools_scm writes the commit into the version: 0.1.dev8+g8334b335f, and
# appends .dYYYYMMDD when the tree was dirty at build time. So the installed
# metadata alone says which source produced it.
#
# The version is not the whole story, though. importlib.metadata resolves a
# distribution the same way an import does, so it finds whichever copy comes
# first on sys.path -- and a per-user copy comes before the system one. Asking
# only "what version" would then happily compare a leftover ~/.local install
# against the source and call it current, while the system install it hides is
# something else entirely. So the location and the kind of install are reported
# too, and either one being wrong is a finding in its own right.
# ---------------------------------------------------------------------------
# Prints three lines -- version, kind, location -- or exits 1 if not installed.
# kind is: system (where a sudo install puts it), user (a per-user tree, which
# shadows the system one), or editable (a link back to a working tree).
installed_info() {
    "$PY" - "$1" <<'PYEOF' 2>/dev/null
import json
import os
import site
import sys
from importlib.metadata import distribution, PackageNotFoundError

try:
    dist = distribution(sys.argv[1])
except PackageNotFoundError:
    sys.exit(1)

location = os.path.realpath(str(dist.locate_file("")))

# An editable install is recorded two ways depending on the installer's age:
# direct_url.json says so outright, and older wheels leave an __editable__ hook.
editable = False
try:
    direct_url = dist.read_text("direct_url.json")
    if direct_url:
        editable = bool(json.loads(direct_url).get("dir_info", {}).get("editable"))
except (json.JSONDecodeError, OSError):
    pass
if not editable:
    editable = any(f.name.startswith("__editable__") for f in (dist.files or []))

user_roots = [
    os.path.realpath(p)
    for p in (getattr(site, "USER_SITE", None),
              getattr(site, "USER_BASE", None),
              os.path.expanduser("~/.local"))
    if p and os.path.isdir(p)
]
in_user_tree = any(location.startswith(root) for root in user_roots)

print(dist.version)
print("editable" if editable else "user" if in_user_tree else "system")
print(location)
PYEOF
}

# ---------------------------------------------------------------------------
# The one case report_foreign_install SAYS it handles and could not.
#
# report_foreign_install prints "X was installed from <tree>, not from <root>
# -- replacing it", and then pip refuses to do the replacing:
#
#     error: uninstall-distutils-installed-package
#     x Cannot uninstall dgpython_nidaqmx 0.0.0
#     '-> It is a distutils installed project and thus we cannot accurately
#         determine which files belong to it which would lead to only a partial
#         uninstall.
#
# Measured on 2026-09-30: two instrument-driver modules (dgpython_nidaqmx and
# a vendor driver) failed this way on FOUR consecutive runs of the python phase and never recovered,
# because nothing about re-running changes the thing in the way. Their previous
# copies came from `python3 setup.py install` out of /usr/local/src, which
# leaves `<name>.egg-info` metadata and no RECORD, so pip cannot know which
# files to delete and -- correctly -- will not guess.
#
# pip cannot remove it, so pip is not the tool. The metadata directory is what
# makes pip refuse, and deleting it turns the install back into plain files that
# the new wheel overwrites. Narrow on purpose:
#
#   * only LEGACY metadata -- a .egg-info / .egg-link / .egg path. A .dist-info
#     is a normal pip install and pip replaces those itself.
#   * only for the distribution names in PACKAGES and EXTRAS, which is all this
#     function is ever called with.
#   * never a path dpkg owns. python3-* debs ship .egg-info directories too, and
#     an apt-managed one is not ours to delete under any circumstances.
# ---------------------------------------------------------------------------
# Prints the metadata path when the installed dist carries LEGACY metadata;
# prints nothing when it is absent or is a normal .dist-info install.
legacy_metadata_path() {
    "$PY" - "$1" <<'PYEOF' 2>/dev/null
import os
import sys
from importlib.metadata import distribution, PackageNotFoundError

try:
    dist = distribution(sys.argv[1])
except PackageNotFoundError:
    sys.exit(0)

# PathDistribution records the metadata directory it was read from. Anything
# else (a custom finder) cannot be repaired by deleting a path, so say nothing.
path = getattr(dist, "_path", None)
if path is None:
    sys.exit(0)
path = os.path.realpath(str(path))
if path.endswith((".egg-info", ".egg-link", ".egg")):
    print(path)
PYEOF
}

# One place that runs a privileged non-pip command, so the sudo-or-already-root
# decision is made once and PIP_INSTALL stays the only thing that spells out an
# install.
run_privileged() {
    if [[ ${#SUDO[@]} -eq 0 ]]; then
        "$@"
    else
        "${SUDO[@]}" "$@"
    fi
}

remove_legacy_metadata() {
    local dist="$1" path owner
    path="$(legacy_metadata_path "$dist")"
    [[ -n "$path" ]] || return 0
    if command -v dpkg >/dev/null 2>&1; then
        owner="$(dpkg -S "$path" 2>/dev/null || true)"
        if [[ -n "$owner" ]]; then
            die "$dist's installed metadata at
   $path
   belongs to the Debian package '${owner%%:*}'. That is an apt-managed copy of
   this distribution name and this script will not delete it. Remove the apt
   package first if it really is meant to be replaced by a source install."
        fi
    fi
    warn "$dist's existing install is a setup.py (egg-info) one at
   $path
   pip cannot uninstall that -- it keeps no file list -- so it refuses with
   'uninstall-distutils-installed-package' and the install can never succeed.
   Removing the metadata; the wheel below overwrites the files themselves."
    run_privileged rm -rf "$path"
    return 0
}

# Prints one of OK / STALE / DIRTY / MISSING / UNVERSIONED / EDITABLE /
# USER-SITE / LEGACY, then a detail line.
package_status() {
    local dir="$1" dist="$2" info ver kind loc head short
    # Not checked out at all. PACKAGES is the whole workspace in dependency
    # order, but the manifests are layered -- acq.repos brings spatialnde2,
    # dataguzzler-python and the two instrument-independent modules, while the
    # instrument drivers arrive only with hw.repos. On an acq-layer machine the
    # hw packages are legitimately absent, and that is not drift: there is no
    # source to be out of date with. Neither a finding nor something to install.
    if [[ ! -d "$ROOT/$dir" ]]; then
        echo "ABSENT|$dir is not checked out (a later layer's manifest brings it)"
        return
    fi
    if ! info="$(installed_info "$dist")"; then
        echo "MISSING|not installed"
        return
    fi
    ver="$(sed -n 1p <<<"$info")"
    kind="$(sed -n 2p <<<"$info")"
    loc="$(sed -n 3p <<<"$info")"
    # These two are the install rule being broken rather than ordinary drift, so
    # they are reported before the version is compared against anything: whatever
    # it says, this is not a copy that was deliberately installed system-wide.
    if [[ "$kind" == editable ]]; then
        echo "EDITABLE|$ver is an editable install at $loc"
        return
    fi
    if [[ "$kind" == user ]]; then
        echo "USER-SITE|$ver under $loc, which shadows the system install"
        return
    fi
    # Also the install rule being broken rather than drift, and reported before
    # the version comparison for the same reason: whatever version it claims,
    # a plain reinstall over it cannot work (see remove_legacy_metadata). An
    # install run repairs it; --check has to be able to say so.
    local legacy
    legacy="$(legacy_metadata_path "$dist")"
    if [[ -n "$legacy" ]]; then
        echo "LEGACY|$ver was installed by setup.py; metadata at $legacy"
        return
    fi
    if [[ ! -d "$ROOT/$dir/.git" ]]; then
        echo "UNVERSIONED|$ver (source is not a git checkout)"
        return
    fi
    head="$(git -C "$ROOT/$dir" rev-parse HEAD)"
    if [[ -n "$(git -C "$ROOT/$dir" status --porcelain)" ]]; then
        echo "DIRTY|$ver installed; working tree has uncommitted changes"
        return
    fi
    if [[ "$ver" == *".d"[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] ]]; then
        echo "STALE|$ver was built from a dirty tree"
        return
    fi
    # A release version has no local segment at all. setuptools_scm emits a bare
    # "0.2.0" when HEAD is exactly the v0.2.0 tag -- there is no distance and no
    # +g<commit> to append -- so requiring +g called a perfectly good install of
    # dgpython-azurekinect UNVERSIONED. Ask git whether that bare version IS the
    # tag on HEAD before concluding the version string tells us nothing.
    if [[ "$ver" != *"+g"* ]]; then
        local tag
        tag="$(git -C "$ROOT/$dir" describe --tags --exact-match HEAD 2>/dev/null || true)"
        if [[ -z "$tag" || "${tag#v}" != "$ver" ]]; then
            echo "UNVERSIONED|$ver carries no commit; cannot tell what it was built from"
            return
        fi
        # HEAD is that release tag, so the bare version does identify the commit
        # after all. Fall through to the import probe like any other match.
    else
        short="${ver##*+g}"
        short="${short%%.*}"
        if [[ "$head" != "$short"* ]]; then
            echo "STALE|$ver installed, HEAD is ${head:0:${#short}}"
            return
        fi
    fi
    # The version matching is not proof the install works. The two compiled
    # packages here ship C++ shared libraries next to the extension module, and
    # an install can carry exactly the right version string and still not load:
    # a wrong RPATH, a library built against a different Qt, a downstream
    # extension left over from an earlier ABI. That failure has occurred twice,
    # both times after a --check that said everything was current. So for the
    # packages where an import is unambiguous, import it.
    #
    # Only these two. Every other package here is a dataguzzler-python module
    # that may reasonably refuse to import without its instrument attached, and
    # "no hardware" must not be reported as a broken install.
    if [[ -n "${IMPORT_PROBE[$dir]:-}" ]]; then
        local err
        # From / , not from wherever the caller stood: run inside the workspace
        # and `import spatialnde2` would find the source directory instead of the
        # installed package, and answer a question nobody asked.
        if ! err="$(cd / && "$PY" -c "import ${IMPORT_PROBE[$dir]}" 2>&1)"; then
            echo "BROKEN|$ver installed, but 'import ${IMPORT_PROBE[$dir]}' fails: $(tail -1 <<<"$err")"
            return
        fi
    fi
    echo "OK|$ver"
}

# ---------------------------------------------------------------------------
# spatialnde2 is built by cmake FIRST, in its own build/ directory, and pip is
# then pointed at that directory rather than at the source root.
#
# Two reasons, both about who runs the compile and where its output lands:
#
#   * `sudo pip install .` from the source root compiles as ROOT -- setup.py runs
#     cmake itself -- and leaves root-owned build/ and spatialnde2.egg-info
#     directories in the checkout. The next unprivileged build then dies on a bare
#     "Permission denied" from deep inside a pip subprocess. Building here means
#     the compile runs as the invoking user; assert_writable_tree() below explains
#     the failure if an earlier run already left root-owned directories.
#
#   * The build directory persists, so a rebuild is incremental and there is one
#     known place to look at what was built. pip run from the source root builds
#     into build/bdist.linux-x86_64/wheel and deletes it afterwards.
#
# The install command itself is unchanged -- same array, same flags, still `.`.
#
# Note on RPATH: an installed spatialnde2 finds its six C++ libraries through
# $ORIGIN, and spatialnde2's CMakeLists.txt now sets that before it creates any
# target, so no RPATH options need to be passed here. They used to be: the
# CMakeLists set CMAKE_INSTALL_RPATH after the add_library() calls, which is too
# late for CMake to apply it, and the libraries kept an RPATH pointing into
# whatever build tree produced them. Verify with
# spatialnde2/test/installed_rpath_test.py, which fails on such an install.
# ---------------------------------------------------------------------------
JOBS="${DGPY_BUILD_JOBS:-8}"

# -j8 rather than $(nproc) deliberately: spatialnde2's own setup.py hardcodes 8,
# and a full C++/SWIG link of this library at -j16 has been measured to exhaust
# 28 GB. Override with DGPY_BUILD_JOBS on a bigger machine.

# spatialnde2 disables its SWIG directors below SWIG 4.1.0, which costs the
# ability to subclass measurement_clock/measurement_time in Python -- needed to
# drive a timed_transaction_manager from a piece of hardware's own clock. Ubuntu
# 22.04 ships 4.0.2, so the container image installs a newer SWIG alongside it at
# /usr/local/bin/swig.
#
# CMake's FindSWIG prefers the version-suffixed names (it looks for swig4.0 before
# plain swig), so /usr/bin/swig4.0 wins however PATH is ordered and the newer one
# has to be named explicitly. So: find the newest swig among the obvious places
# and pass it. On a machine with only one swig this simply names that one, and
# cmake warns for itself if it is too old for directors.
SNDE_CMAKE_OPTS=()
SNDE_SWIG=""
SNDE_SWIG_VERSION=""

swig_version_of() { "$1" -version 2>/dev/null | sed -n 's/^SWIG Version //p'; }

# True when $1 is a strictly newer version string than $2.
version_gt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

select_swig() {
    local cand ver
    for cand in "${SWIG_EXECUTABLE:-}" /usr/local/bin/swig "$(command -v swig || true)" \
                /usr/bin/swig4.1 /usr/bin/swig4.0; do
        [[ -n "$cand" && -x "$cand" ]] || continue
        ver="$(swig_version_of "$cand")"
        [[ -n "$ver" ]] || continue
        if [[ -z "$SNDE_SWIG_VERSION" ]] || version_gt "$ver" "$SNDE_SWIG_VERSION"; then
            SNDE_SWIG="$cand"
            SNDE_SWIG_VERSION="$ver"
        fi
    done
    [[ -n "$SNDE_SWIG" ]] || return 0
    SNDE_CMAKE_OPTS+=( "-DSWIG_EXECUTABLE=$SNDE_SWIG" )
}
select_swig

# Prints the directory pip should be run from for this package: its own cmake
# build directory where there is one, otherwise the source root.
pip_source_dir() {
    case "$1" in
        spatialnde2) echo "$ROOT/spatialnde2/build" ;;
        *)           echo "$ROOT/$1" ;;
    esac
}

needs_cmake_prebuild() { [[ "$1" == spatialnde2 ]]; }

# A build directory or egg-info left behind root-owned -- by an earlier `sudo pip
# install .` run from a source root, which compiles as root -- cannot be written
# by an unprivileged build, and the error you get is a bare "Permission denied"
# on a path deep inside a pip subprocess. Say what it actually is.
#
# Only for the packages built by cmake below, because those are the only ones
# built as the invoking user. EVERY other package here is built by pip under
# sudo, so root-owned build/ and *.egg-info in its checkout is the normal state
# after any install -- refusing on that would refuse every second run.
assert_writable_tree() {
    local dir="$1" owned
    owned="$(find "$ROOT/$dir" -maxdepth 2 \( -name build -o -name '*.egg-info' \) \
                  ! -user "$(id -un)" -print -quit 2>/dev/null || true)"
    [[ -z "$owned" ]] && return 0
    die "$owned is not owned by $(id -un).
   An earlier 'sudo pip install .' run from the source root compiled as root and
   left its build directory behind. The build below runs as you and cannot write
   there. Remove it and run again:

       sudo rm -rf $ROOT/$dir/build $ROOT/$dir/*.egg-info"
}

cmake_prebuild() {
    local dir="$1" bld
    bld="$(pip_source_dir "$dir")"
    info "    cmake build in $bld  (-j$JOBS)"
    if [[ -n "$SNDE_SWIG" ]]; then
        info "    SWIG $SNDE_SWIG_VERSION at $SNDE_SWIG"
        version_gt 4.1.0 "$SNDE_SWIG_VERSION" && \
            warn "SWIG $SNDE_SWIG_VERSION is older than 4.1.0: spatialnde2's Python
   directors will be disabled, so measurement_clock and measurement_time cannot be
   subclassed from Python. Install a newer SWIG (pip install 'swig>=4.1,<4.6')."
    fi
    mkdir -p "$bld"
    ( cd "$bld" && cmake "${SNDE_CMAKE_OPTS[@]}" .. && make -j"$JOBS" )
}

# SETUPTOOLS_USE_DISTUTILS=stdlib is the cure for one fault and the cause of
# another, and which one you get depends entirely on the interpreter.
#
# It tells setuptools to use the STANDARD LIBRARY's distutils instead of its own
# vendored copy. On Python 3.11 and earlier that is what makes a cythonizing
# setup.py build at all (see the BUILD_ENV comment above). But distutils was
# REMOVED from the standard library in Python 3.12, so on a newer interpreter
# there is nothing for the variable to select and setuptools cannot even load its
# own build backend:
#
#     pip._vendor.pyproject_hooks._impl.BackendUnavailable:
#         Cannot import 'setuptools.build_meta'
#
# Measured on an Arch host (Python 3.14.7): with the variable set,
# `pip wheel` on spatialnde2-ec-functions and on
# spatialnde2_cpp_calibration_function both fail that way before a compiler runs;
# without it, both build. So the splice is decided by asking the interpreter that
# will do the build, not by hardcoding either answer. Anything else makes the
# script work on only one of the two kinds of machine it is run on.
interpreter_has_stdlib_distutils() {
    "$PY" - <<'PYEOF' >/dev/null 2>&1
import sys
sys.exit(0 if sys.version_info < (3, 12) else 1)
PYEOF
}

INTERPRETER_HAS_STDLIB_DISTUTILS=0
interpreter_has_stdlib_distutils && INTERPRETER_HAS_STDLIB_DISTUTILS=1

# ---------------------------------------------------------------------------
# `sudo pip install .` makes git run as root over somebody else's checkout.
#
# Every package here is versioned by setuptools_scm, which shells out to git.
# The install is under sudo by policy, so that git is root -- and on a shared
# machine the workspace can live in an unprivileged account's home, which root
# does not own either. git's CVE-2022-24765 guard then refuses:
#
#     fatal: detected dubious ownership in repository at
#            '/home/labuser/tari/dgpython-opencv-camera'
#     git introspection failed: fatal: detected dubious ownership ...
#     error: subprocess-exited-with-error / metadata-generation-failed
#
# which took out two packages in one observed run -- the only hard failure in
# that phase -- and reads as a build error rather than an ownership one.
#
# The reflex fix is `sudo git config --global --add safe.directory "*"`, which
# is permanent, machine-wide, applies to root, and declares every repository on
# the box trusted in order to get past one bootstrap. GIT_CONFIG_COUNT/KEY/VALUE is the same setting for ONE directory
# and ONE command: nothing is written to any config file, and it is gone when
# pip exits. sudo's env_reset drops it unless it is passed explicitly, which is
# exactly what the `env` splice below already does for the build variables.
#
# Both the source root and the directory pip is run from are listed, because
# for spatialnde2 those differ (pip runs from its cmake build directory) and
# setuptools_scm walks up from wherever it starts.
# ---------------------------------------------------------------------------
git_safe_env_for() {
    local dir="$1" n=0 d seen=""
    for d in "$ROOT/$dir" "$(pip_source_dir "$dir")" "$ROOT"; do
        # pip_source_dir is the source root for everything except spatialnde2,
        # so without this most packages would list the same path twice.
        case "$seen" in *"|$d|"*) continue ;; esac
        seen="$seen|$d|"
        printf 'GIT_CONFIG_KEY_%d=safe.directory\n' "$n"
        printf 'GIT_CONFIG_VALUE_%d=%s\n' "$n" "$d"
        n=$(( n + 1 ))
    done
    printf 'GIT_CONFIG_COUNT=%d\n' "$n"
}

# The environment assignments that apply to this package ON THIS INTERPRETER.
build_env_for() {
    local dir="$1" assignment out=()
    for assignment in ${BUILD_ENV[$dir]:-}; do
        if [[ "$assignment" == SETUPTOOLS_USE_DISTUTILS=stdlib \
              && $INTERPRETER_HAS_STDLIB_DISTUTILS -eq 0 ]]; then
            continue
        fi
        out+=("$assignment")
    done
    # Unconditional, for every package: see git_safe_env_for above. It is only
    # ever needed when the install is privileged, and SUDO is empty when this
    # script is already root -- but a root-owned workspace read by root is the
    # same refusal, so it goes on either way.
    while IFS= read -r assignment; do
        out+=("$assignment")
    done < <(git_safe_env_for "$dir")
    printf '%s\n' "${out[@]:-}"
}

# The install command for one package: PIP_INSTALL, with an `env` assignment
# spliced in after the sudo prefix when that package's build needs one. The pip
# part is taken from PIP_INSTALL rather than written out again, so there is still
# exactly one place that says how a package is installed.
pip_command_for() {
    local dir="$1"
    local -a env_args=()
    mapfile -t env_args < <(build_env_for "$dir")
    # mapfile on empty input still yields one empty element.
    [[ ${#env_args[@]} -eq 1 && -z "${env_args[0]}" ]] && env_args=()
    if [[ ${#env_args[@]} -eq 0 ]]; then
        printf '%s\0' "${PIP_INSTALL[@]}"
        return
    fi
    printf '%s\0' "${SUDO[@]}" env "${env_args[@]}" \
                  "${PIP_INSTALL[@]:${#SUDO[@]}}"
}

install_one() {
    local dir="$1" dist="$2" srcdir
    local -a cmd=()
    assert_not_a_ros_package "$dir"
    [[ -d "$ROOT/$dir" ]] || die "$dir is missing. Run tari.bash --phase sources first."
    srcdir="$(pip_source_dir "$dir")"
    mapfile -d '' -t cmd < <(pip_command_for "$dir")
    info "==> $dist  ($dir)"
    # The printed command and the executed one are built by the same function, so
    # a dry run cannot describe an install that differs from the real one. pip is
    # run from inside a directory rather than given a path to it, which is what
    # setuptools_scm needs to find the git metadata for the version.
    if [[ $DRYRUN -eq 1 ]]; then
        if needs_cmake_prebuild "$dir"; then
            printf '    build: cmake %s .. && make -j%s   [in %s]\n' \
                   "${SNDE_CMAKE_OPTS[*]}" "$JOBS" "$srcdir"
        fi
        printf '    ( cd %s && %s . )\n' "$srcdir" "${cmd[*]}"
        return 0
    fi
    if needs_cmake_prebuild "$dir"; then
        assert_writable_tree "$dir"
        cmake_prebuild "$dir" || return 1
    fi
    # After the build, before the install: pip's refusal to replace a setup.py
    # install is the last thing standing between a successfully built wheel and
    # an installed one, and clearing it is pointless if the build failed.
    remove_legacy_metadata "$dist"
    ( cd "$srcdir" && "${cmd[@]}" . )
}

# ---------------------------------------------------------------------------
# Populates the global INDICES. Deliberately NOT written to stdout and read
# back through a process substitution: that runs in a subshell, where `die`
# exits the subshell only and the caller carries on with an empty selection.
INDICES=()
select_packages() {
    local i entry dir found=0
    INDICES=()
    for i in "${!PACKAGES[@]}"; do
        entry="${PACKAGES[$i]}"; dir="${entry%%|*}"
        case "$SELECT" in
            all)  INDICES+=("$i") ;;
            only) [[ "$dir" == "$SELECT_ARG" ]] && { INDICES+=("$i"); found=1; } ;;
            from) if [[ $found -eq 1 || "$dir" == "$SELECT_ARG" ]]; then found=1; INDICES+=("$i"); fi ;;
        esac
    done
    if [[ "$SELECT" != all && $found -eq 0 ]]; then
        die "no such package: $SELECT_ARG (try --list)"
    fi
}

if [[ "$MODE" == list ]]; then
    info "Install order:"
    for entry in "${PACKAGES[@]}"; do printf '  %-26s -> %s\n' "${entry%%|*}" "${entry##*|}"; done
    info "Extras (--with-extras):"
    for entry in "${EXTRAS[@]}"; do
        IFS='|' read -r dir dist need <<<"$entry"
        printf '  %-26s -> %-38s %s\n' "$dir" "$dist" "$need"
    done
    exit 0
fi

select_packages

# Every guard runs before anything is built or installed, so an invalid
# request costs nothing and a refusal is not buried under pip output.
for i in "${INDICES[@]}"; do
    entry="${PACKAGES[$i]}"
    assert_not_a_ros_package "${entry%%|*}"
done

if [[ "$MODE" == check ]]; then
    rc=0
    misplaced=0
    legacy_seen=0
    dirty_seen=0
    printf '%-26s %-12s %s\n' "PACKAGE" "STATE" "DETAIL"
    for i in "${INDICES[@]}"; do
        entry="${PACKAGES[$i]}"; dir="${entry%%|*}"; dist="${entry##*|}"
        result="$(package_status "$dir" "$dist")"
        state="${result%%|*}"; detail="${result#*|}"
        case "$state" in
            OK)                  colour="\033[32m" ;;
            # Absent source is a statement about which layer this machine has,
            # not a fault, so it must not fail --check: tari.bash's verify phase
            # runs this, and an acq-layer machine would otherwise never verify.
            ABSENT)              colour="\033[90m" ;;
            # DIRTY says the source has uncommitted changes, so no installed
            # copy can be KNOWN to match it. That uncertainty is real on a
            # developer's machine and is the point of the state. It does not
            # apply to an image build, which copies a tree in and installs from
            # exactly that tree moments later -- there the installed copy is
            # known to match, uncommitted changes and all, and failing on it
            # would mean no image could ever be built while anyone had
            # uncommitted work in any of nine packages. Same reasoning as ABSENT
            # above: report it, do not fail on it, and only when asked.
            DIRTY)               colour="\033[33m"
                                 [[ $ALLOW_DIRTY -eq 1 ]] || rc=1
                                 dirty_seen=1 ;;
            EDITABLE|USER-SITE)  colour="\033[31m"; rc=1; misplaced=1 ;;
            LEGACY)              colour="\033[31m"; rc=1; legacy_seen=1 ;;
            *)                   colour="\033[31m"; rc=1 ;;
        esac
        printf "%-26s ${colour}%-12s\033[0m %s\n" "$dir" "$state" "$detail"
    done
    echo
    if [[ $rc -eq 0 && $dirty_seen -eq 1 ]]; then
        info "Every package is installed system-wide and built from the tree here."
        echo "DIRTY above means that tree has uncommitted changes; --allow-dirty"
        echo "says that is expected, because this install was built from it."
    elif [[ $rc -eq 0 ]]; then
        info "Every installed package matches its checked-out commit."
    else
        echo "Reinstall the packages above with:  ./dgpy_install.sh"
        echo "DIRTY means the source has uncommitted changes, so no installed copy"
        echo "can be known to match it -- reinstall to run what you are editing."
    fi
    if [[ $misplaced -eq 1 ]]; then
        echo
        echo "EDITABLE or USER-SITE means the install itself is wrong, not merely out"
        echo "of date: every package here is installed system-wide, never with -e and"
        echo "never into a per-user tree. Remove the offending copy first --"
        echo
        echo "    $PY -m pip uninstall <name>"
        echo
        echo "-- and then reinstall. A per-user copy precedes the system one on"
        echo "sys.path, so reinstalling without removing it would not change what runs."
    fi
    if [[ $legacy_seen -eq 1 ]]; then
        echo
        echo "LEGACY means the installed copy came from 'python3 setup.py install', which"
        echo "leaves no file list -- so pip refuses to replace it with"
        echo "'uninstall-distutils-installed-package' however many times you re-run. An"
        echo "install run removes that metadata first and then installs normally; nothing"
        echo "has to be done by hand."
    fi
    exit $rc
fi

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
# setuptools is needed in a WINDOW, not from a floor upwards, and the upper end
# of it is not a style preference. Measured on a clean jammy bootstrap
# (2026-09-30): this function used to ask for `-U "setuptools>=64"`,
# which resolved to 84.0.0 and wrote it into /usr/local/lib/python3.10/
# dist-packages, ahead of apt's 59.6.0 on sys.path. Everything below broke in
# the same run, and pip warned about it inside the very command that caused it:
#
#     colcon-core 0.21.3 requires setuptools<80,>=30.3.0, but you have
#     setuptools 84.0.0 which is incompatible
#
#   * `import pkg_resources` stopped working, which is `from pkg_resources
#     import load_entry_point` in /usr/bin/vcs (so no `vcs import`), and
#     `import pkg_resources` in /usr/lib/python3/dist-packages/pbr/git.py --
#     reached through a setuptools entry point, so EVERY package here failed
#     metadata generation with "ModuleNotFoundError: No module named
#     'pkg_resources'" and the python phase ended
#         error: failed: spatialnde2 dataguzzler-python dgpython_param_manager
#                dgpython-local spatialnde2_ec_functions
#
#   * `setup.py develop --uninstall` was removed, and that is what colcon runs
#     for an ament_python package under --symlink-install. The whole Python half
#     of ros_ws then fails with
#         error: option --uninstall not recognized
#     -- tari_bringup, tari_cv, tari_keyence_sim, msg_sync, april_registration,
#     dgpython_ros2_mtcserver, tari_yolo_utils -- and aborts everything
#     downstream of them.
#
# 79.x satisfies everything this repository actually needs from a modern
# setuptools: the [project] table honoured with a setup.py present (>= 61), and
# setuptools_scm 8's build backend (>= 64). So the ceiling costs nothing.
#
# This is not "downgrading another project's setuptools to build ours": apt's
# colcon on this distro declares setuptools<80 itself, so a machine above the
# ceiling is broken for every ROS package on it, not only for this repository.
# The repair is still announced out loud rather than done silently.
SETUPTOOLS_FLOOR=64
SETUPTOOLS_CEILING=80          # exclusive
SETUPTOOLS_SCM_FLOOR=8

ensure_build_prereqs() {
    # Ubuntu 22.04 ships setuptools 59.6 and setuptools_scm 6.4.2. 59.6 ignores
    # pyproject.toml's [project] table whenever a setup.py is present, and 6.4.2
    # predates the version_file option that spatialnde2's generated pyproject
    # uses. Both produce confusing failures a long way downstream of the cause.
    #
    # Only act when the versions are actually outside the window. On a distro
    # that marks its Python externally managed (PEP 668 -- Arch, Ubuntu 23.04+)
    # an unconditional install fails, and it would fail for no reason on the
    # many systems that are already fine.
    #
    # The probe runs with the same privileges as the install that follows, so it
    # reports the environment that will actually do the building. Root does not
    # see the invoking user's ~/.local, so an unprivileged probe can find a new
    # enough setuptools_scm that the build will never load.
    #
    # pkg_resources is probed by IMPORTING it, not by reading a version. The
    # breakage above is a missing module, and a machine can carry an in-window
    # setuptools whose pkg_resources files are gone from disk anyway (dpkg still
    # reports python3-pkg-resources installed; tari.bash's prereqs phase
    # restores it). A version comparison cannot see that at all.
    local probe_rc=0
    "${SUDO[@]}" "$PY" - "$SETUPTOOLS_FLOOR" "$SETUPTOOLS_CEILING" \
                        "$SETUPTOOLS_SCM_FLOOR" <<'PYEOF' || probe_rc=$?
import sys
from importlib.metadata import version, PackageNotFoundError

floor, ceiling, scm_floor = sys.argv[1:4]

def numeric(s):
    out = []
    for part in s.split("."):
        digits = "".join(c for c in part if c.isdigit())
        if not digits:
            break
        out.append(int(digits))
    return out

def found(names):
    for name in names:
        try:
            return numeric(version(name))
        except PackageNotFoundError:
            continue
    return None

# Distinct statuses, because the caller says a different thing for each: 1 is
# "too old, upgrade", 2 is "too new, and here is what that breaks".
have = found(["setuptools"])
if have is None or have < numeric(floor):
    sys.exit(1)
if have >= numeric(ceiling):
    sys.exit(2)
scm = found(["setuptools_scm", "setuptools-scm"])
if scm is None or scm < numeric(scm_floor):
    sys.exit(1)
try:
    # Every setuptools in the window warns that pkg_resources is deprecated.
    # The question here is only whether it is THERE, and printing that warning
    # on every run would be noise in the one place that must stay readable.
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        import pkg_resources  # noqa: F401
except ImportError:
    sys.exit(1)
sys.exit(0)
PYEOF
    if [[ $probe_rc -eq 0 ]]; then
        return 0
    fi
    info "==> build prerequisites"
    if [[ $probe_rc -eq 2 ]]; then
        # Say what is being changed and why before changing it. A silent
        # downgrade of a system-wide build tool is exactly the kind of thing
        # that costs somebody else a day.
        local too_new
        too_new="$("$PY" -c 'from importlib.metadata import version
print(version("setuptools"))' 2>/dev/null || echo "(unreadable)")"
        warn "setuptools $too_new is installed and is too NEW for this
   distribution: apt's colcon-core declares setuptools<80, 'setup.py develop
   --uninstall' (which colcon runs for every ament_python package under
   --symlink-install) is gone above it, and pkg_resources -- which /usr/bin/vcs
   and apt's pbr both import -- is gone with it. Pinning it back below
   $SETUPTOOLS_CEILING, which is what every build here was verified against."
    fi
    # Under sudo, into the same environment as everything else, and for the same
    # reason: the package installs below run as root and import these at build
    # time. An unprivileged upgrade would land in the invoking user's ~/.local,
    # which root's interpreter does not read -- it would report success and the
    # build would still use the distro's too-old setuptools.
    #
    # These are third-party build tools rather than packages of ours, so --deps
    # resolution is left alone here: setuptools_scm needs what it needs. NOT
    # -U, and that is the fix: `-U` means "newest that satisfies", and with no
    # ceiling the newest was 84.0.0. A bounded specifier makes pip move
    # setuptools INTO the window from either side.
    if ! "${SUDO[@]}" "$PY" -m pip install -q \
            "setuptools>=$SETUPTOOLS_FLOOR,<$SETUPTOOLS_CEILING" \
            "setuptools_scm[toml]>=$SETUPTOOLS_SCM_FLOOR" wheel; then
        die "could not install the build prerequisites.

   If pip reported an externally-managed environment (PEP 668), this
   interpreter is managed by the distribution and pip will not write to it.
   Either install them with the system package manager:

       sudo apt install python3-setuptools python3-setuptools-scm   # Debian/Ubuntu

   or point this script at an interpreter you own:

       ./dgpy_install.sh --python /path/to/venv/bin/python
       DGPY_PYTHON=/path/to/venv/bin/python ./dgpy_install.sh"
    fi
    # The install above is also the repair for a missing pkg_resources, because
    # every setuptools in the window still ships it. Confirm that rather than
    # assume it: a build that goes ahead without it fails five packages later
    # with a traceback that blames pbr, which is not where anybody would look.
    if ! "${SUDO[@]}" "$PY" -c 'import pkg_resources' >/dev/null 2>&1; then
        die "pkg_resources still does not import after installing setuptools.

   Apt reports python3-pkg-resources installed while its files are gone from
   disk on machines where something ran a system-wide pip upgrade of
   setuptools. Restore that one package -- it changes nothing else, and leaves
   whatever is in /usr/local alone:

       sudo apt-get install --reinstall python3-pkg-resources"
    fi
}

# Fail on a missing sudo before the first build rather than after it, and prompt
# for the password once, up front, rather than partway through pip's output.
if [[ $DRYRUN -eq 0 ]]; then
    # Before sudo, before the first compile: refuse if any of these is already
    # installed from somebody else's source tree. Checked over the whole
    # selection first, so a refusal is not buried under pip output and does not
    # arrive after half the workspace has been reinstalled.
    for i in "${INDICES[@]}"; do
        entry="${PACKAGES[$i]}"
        # Only for packages this repository actually has a source tree for.
        # Reporting "replacing it" about a package we are not going to touch --
        # dgpython_nidaqmx, say, installed by another project on a machine that
        # has only the acq layer checked out -- says the opposite of the truth.
        [[ -d "$ROOT/${entry%%|*}" ]] || continue
        report_foreign_install "${entry##*|}"
    done
    require_privilege
    ensure_build_prereqs
fi

failed=()
optional_failed=()
for i in "${INDICES[@]}"; do
    entry="${PACKAGES[$i]}"; dir="${entry%%|*}"; dist="${entry##*|}"
    # A package whose source is not checked out belongs to a manifest this
    # machine has not imported. Skip it -- but not when it was named outright
    # with --only, where silence would look like success.
    if [[ ! -d "$ROOT/$dir" ]]; then
        [[ "$SELECT" == only ]] && die "$dir is missing. Run tari.bash --phase sources first."
        printf '\033[90m==> %s skipped\033[0m (%s is not checked out)\n' "$dist" "$dir"
        continue
    fi
    if [[ $FORCE -eq 0 ]]; then
        result="$(package_status "$dir" "$dist")"
        if [[ "${result%%|*}" == "OK" ]]; then
            printf '\033[32m==> %s is current\033[0m (%s)\n' "$dist" "${result#*|}"
            continue
        fi
    fi
    install_one "$dir" "$dist" || failed+=("$dist")
done

if [[ $WITH_EXTRAS -eq 1 ]]; then
    # Always rebuilt, with no staleness check, and deliberately. These link
    # spatialnde2's C++ ABI, so the thing that invalidates them is spatialnde2
    # being reinstalled -- which their own commit hash cannot see. An extra left
    # in place across a spatialnde2 rebuild does not fail to import; it
    # segfaults when the math runs. A recompile is cheap against that.
    for entry in "${EXTRAS[@]}"; do
        IFS='|' read -r dir dist need <<<"$entry"
        case "$need" in
            required|optional) ;;
            *) die "EXTRAS entry '$entry' must end in |required or |optional." ;;
        esac
        if [[ ! -d "$ROOT/$dir" ]]; then
            printf '\033[90m==> %s skipped\033[0m (%s is not checked out)\n' "$dist" "$dir"
            continue
        fi
        # A required extra joins the same list as a package, so it is fatal. An
        # optional one is collected separately and warned about at the end: the
        # loop goes on either way, but only the required list decides whether
        # this was an install failure.
        if ! install_one "$dir" "$dist"; then
            if [[ "$need" == required ]]; then
                failed+=("$dist")
            else
                optional_failed+=("$dist")
            fi
        fi
    done
fi

echo
if [[ ${#failed[@]} -gt 0 ]]; then
    die "failed: ${failed[*]}"
fi
[[ $DRYRUN -eq 1 ]] && { info "Dry run; nothing was installed."; exit 0; }
info "Done. Verify with: ./dgpy_install.sh --check"
if [[ ${#optional_failed[@]} -gt 0 ]]; then
    warn "these OPTIONAL extras did not build: ${optional_failed[*]}
   Everything else is installed and usable. Nothing that has to work imports
   them -- see the EXTRAS comment in this script for what each one is for and
   what is lost without it."
    exit "$EXIT_OPTIONAL_EXTRA_FAILED"
fi
