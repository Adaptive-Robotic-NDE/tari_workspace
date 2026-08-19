#!/usr/bin/env bash
#
# Build and install the dataguzzler-python side of the workspace.
#
# These are ordinary Python distributions, not ROS packages, so colcon has
# nothing to do with them -- colcon owns ros_ws/src and nothing else. This
# script owns everything at the workspace root.
#
# Installs are NOT editable. That is deliberate, but it has a consequence
# worth stating plainly: editing a source file changes nothing until you
# reinstall, and there is no error to tell you so. --check exists for exactly
# that, and every package now carries a setuptools_scm version embedding the
# commit it was built from, so the question is answerable without guessing.
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

# Not installed by default. It is a Cython extension that does `import
# spatialnde2` at build time, so it needs spatialnde2 installed first and a
# working compiler, and nothing in the scan path requires it.
EXTRAS=(
    "dgpython-opencv-camera/spatialnde2_cpp_calibration_function|spatialnde2_cpp_calibration_function"
)

MODE=install
SELECT=all
SELECT_ARG=""
FORCE=0
DRYRUN=0
WITH_EXTRAS=0

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1m%s\033[0m\n' "$*"; }

usage() {
    sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --check              report drift for every package; install nothing
  --list               print the install order and exit
  --only NAME          operate on one package only
  --from NAME          operate on NAME and every package after it
  --force              reinstall even when the installed copy is current
  --with-extras        also build the optional Cython extras
  -n, --dry-run        print the pip commands without running them
  --python PYTHON      interpreter to install into (default: python3,
                       override with DGPY_PYTHON)
  -h, --help           this message

Exit status:
  0  everything requested succeeded; with --check, everything is current
  1  a build or install failed; with --check, something is stale or missing
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
        -n|--dry-run)  DRYRUN=1 ;;
        --python)      PY="${2:?--python needs an interpreter}"; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

command -v "$PY" >/dev/null 2>&1 || die "interpreter not found: $PY"

# ---------------------------------------------------------------------------
# Guard: this script must never install anything colcon owns.
#
# A package.xml means colcon builds it, and a pip install of the same source
# then puts a second copy on PYTHONPATH where the colcon one shadows it -- you
# edit one and run the other. That failure has already cost this project a
# session, twice, at two different levels. It is cheap to make impossible.
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
# Drift detection
#
# setuptools_scm writes the commit into the version: 0.1.dev8+g8334b335f, and
# appends .dYYYYMMDD when the tree was dirty at build time. So the installed
# metadata alone says which source produced it.
# ---------------------------------------------------------------------------
installed_version() {
    "$PY" - "$1" <<'PYEOF' 2>/dev/null
import sys
from importlib.metadata import version, PackageNotFoundError
try:
    print(version(sys.argv[1]))
except PackageNotFoundError:
    sys.exit(1)
PYEOF
}

# Prints one of: OK / STALE / DIRTY / MISSING / UNVERSIONED, then a detail line.
package_status() {
    local dir="$1" dist="$2" ver head short
    if ! ver="$(installed_version "$dist")"; then
        echo "MISSING|not installed"
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
    if [[ "$ver" != *"+g"* ]]; then
        echo "UNVERSIONED|$ver carries no commit; cannot tell what it was built from"
        return
    fi
    short="${ver##*+g}"
    short="${short%%.*}"
    if [[ "$head" == "$short"* ]]; then
        echo "OK|$ver"
    else
        echo "STALE|$ver installed, HEAD is ${head:0:${#short}}"
    fi
}

install_one() {
    local dir="$1" dist="$2"
    assert_not_a_ros_package "$dir"
    [[ -d "$ROOT/$dir" ]] || die "$dir is missing. Run tari.bash --phase sources first."
    info "==> $dist  ($dir)"
    if [[ $DRYRUN -eq 1 ]]; then
        echo "    $PY -m pip install --no-deps --no-build-isolation ./$dir"
        return 0
    fi
    ( cd "$ROOT/$dir" && "$PY" -m pip install --no-deps --no-build-isolation . )
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
    info "Optional extras (--with-extras):"
    for entry in "${EXTRAS[@]}"; do printf '  %-26s -> %s\n' "${entry%%|*}" "${entry##*|}"; done
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
    printf '%-26s %-12s %s\n' "PACKAGE" "STATE" "DETAIL"
    for i in "${INDICES[@]}"; do
        entry="${PACKAGES[$i]}"; dir="${entry%%|*}"; dist="${entry##*|}"
        result="$(package_status "$dir" "$dist")"
        state="${result%%|*}"; detail="${result#*|}"
        case "$state" in
            OK)     colour="\033[32m" ;;
            DIRTY)  colour="\033[33m"; rc=1 ;;
            *)      colour="\033[31m"; rc=1 ;;
        esac
        printf "%-26s ${colour}%-12s\033[0m %s\n" "$dir" "$state" "$detail"
    done
    echo
    if [[ $rc -eq 0 ]]; then
        info "Every installed package matches its checked-out commit."
    else
        echo "Reinstall the packages above with:  ./dgpy_install.sh"
        echo "DIRTY means the source has uncommitted changes, so no installed copy"
        echo "can be known to match it -- reinstall to run what you are editing."
    fi
    exit $rc
fi

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
ensure_build_prereqs() {
    # Ubuntu 22.04 ships setuptools 59.6 and setuptools_scm 6.4.2. 59.6 ignores
    # pyproject.toml's [project] table whenever a setup.py is present, and 6.4.2
    # predates the version_file option that spatialnde2's generated pyproject
    # uses. Both produce confusing failures a long way downstream of the cause.
    #
    # Only upgrade when the versions are actually too old. On a distro that
    # marks its Python externally managed (PEP 668 -- Arch, Ubuntu 23.04+) an
    # unconditional upgrade fails, and it would fail for no reason on the many
    # systems that are already fine.
    if "$PY" - <<'PYEOF'
import sys
from importlib.metadata import version, PackageNotFoundError

def numeric(s):
    out = []
    for part in s.split("."):
        digits = "".join(c for c in part if c.isdigit())
        if not digits:
            break
        out.append(int(digits))
    return out

def at_least(names, minimum):
    for name in names:
        try:
            return numeric(version(name)) >= numeric(minimum)
        except PackageNotFoundError:
            continue
    return False

sys.exit(0 if at_least(["setuptools"], "64")
         and at_least(["setuptools_scm", "setuptools-scm"], "8") else 1)
PYEOF
    then
        return 0
    fi
    info "==> build prerequisites"
    if ! "$PY" -m pip install -q -U "setuptools>=64" "setuptools_scm[toml]>=8" wheel; then
        die "could not install the build prerequisites.

   If pip reported an externally-managed environment (PEP 668), this
   interpreter is managed by the distribution and pip will not write to it.
   Either install them with the system package manager:

       sudo apt install python3-setuptools python3-setuptools-scm   # Debian/Ubuntu

   or point this script at an interpreter you own:

       ./dgpy_install.sh --python /path/to/venv/bin/python
       DGPY_PYTHON=/path/to/venv/bin/python ./dgpy_install.sh"
    fi
}

[[ $DRYRUN -eq 0 ]] && ensure_build_prereqs

failed=()
for i in "${INDICES[@]}"; do
    entry="${PACKAGES[$i]}"; dir="${entry%%|*}"; dist="${entry##*|}"
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
    for entry in "${EXTRAS[@]}"; do
        install_one "${entry%%|*}" "${entry##*|}" || failed+=("${entry##*|}")
    done
fi

echo
if [[ ${#failed[@]} -gt 0 ]]; then
    die "failed: ${failed[*]}"
fi
[[ $DRYRUN -eq 1 ]] && { info "Dry run; nothing was installed."; exit 0; }
info "Done. Verify with: ./dgpy_install.sh --check"
