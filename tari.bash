#!/usr/bin/env bash
#
# Bootstrap the TARI / NDE scanning workspace on Ubuntu 22.04 (or WSL2).
#
#     ./tari.bash --layer sim      simulation only; nothing private, no hardware
#     ./tari.bash --layer acq      + the dataguzzler-python acquisition stack
#     ./tari.bash --layer hw       + instrument drivers (needs two vendor SDKs)
#     ./tari.bash --layer site     + our cell manifests and calibration
#
# Layers are additive and each is a strict superset of the one before, so
# --layer hw imports sim, then acq, then hw. Everything is idempotent: run it
# again after a pull and it does the work that is now missing and nothing else.
#
# Seven phases, runnable individually with --phase:
#
#     prereqs   apt packages, rosdep, vcstool, colcon
#     sources   vcs import of the layer chain
#     rosdep    rosdep install over ros_ws/src
#     python    dgpy_install.sh -- spatialnde2 and the dataguzzler modules
#     build     one colcon build over ros_ws
#     env       write tari_setup.bash
#     verify    smoke-test the layer
#
# NOT A CONTAINER SCRIPT. This installs natively. The docker tooling next to
# this file exists only because one development machine runs Arch, where ROS
# Iron is not packaged; it is a local convenience and not how this stack is
# meant to be deployed.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$ROOT/ros_ws"
ROSDISTRO="${ROSDISTRO:-iron}"

LAYER=""
ONLY_PHASE=""
WITH_SOFA=0
WITH_TEST_DATA=0
DRYRUN=0
DO_CHECK_REMOTES=0

ALL_PHASES=(prereqs sources rosdep python build env verify)

# ---------------------------------------------------------------------------
say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
# Fatal normally, advisory under --dry-run, whose whole purpose is to show the
# entire plan on a machine that is not set up yet.
fatal_unless_dry() { if [[ $DRYRUN -eq 1 ]]; then warn "$*"; else die "$*"; fi; }
# colcon's generated setup.bash reads COLCON_TRACE and other variables it does
# not set, so sourcing one under `set -u` aborts with "unbound variable". Relax
# nounset across the source and put it back afterwards.
source_quietly() {
    local restore=0
    [[ $- == *u* ]] && restore=1
    set +u
    # shellcheck disable=SC1090
    source "$1"
    [[ $restore -eq 1 ]] && set -u
    return 0
}
source_ros() {
    if [[ -f "/opt/ros/$ROSDISTRO/setup.bash" ]]; then
        source_quietly "/opt/ros/$ROSDISTRO/setup.bash"
    else
        fatal_unless_dry "ROS $ROSDISTRO is not installed at /opt/ros/$ROSDISTRO"
    fi
}
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [[ $DRYRUN -eq 1 ]]; then printf '    + %s\n' "$*"; else eval "$@"; fi; }

usage() { sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; cat <<'EOF'

Options:
  --layer LAYER      container | sim | acq | hw | site   (required, unless
                     --check-remotes). Each includes the ones before it.
  --phase PHASE      run one phase only (see the list above)
  --with-sofa        also fetch the SOFA binary release (1.3 GB, soft robotics)
  --with-test-data   also clone the recorded scan fixtures the suites use
                     (~95 MB over git-lfs; without it those sections skip)
  --check-remotes    test that every manifest URL resolves, then exit
  -n, --dry-run      print what would run
  -h, --help         this message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --layer)         LAYER="${2:?--layer needs a value}"; shift ;;
        --phase)         ONLY_PHASE="${2:?--phase needs a value}"; shift ;;
        --with-sofa)     WITH_SOFA=1 ;;
        --with-test-data) WITH_TEST_DATA=1 ;;
        --check-remotes) DO_CHECK_REMOTES=1 ;;
        -n|--dry-run)    DRYRUN=1 ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Layer chain. Additive by construction: importing sim then acq then hw leaves
# every repository from all three, which is why the manifests must be disjoint.
# ---------------------------------------------------------------------------
layer_chain() {
    case "$1" in
        container) echo "container" ;;
        sim)  echo "container sim" ;;
        acq)  echo "container sim acq" ;;
        hw)   echo "container sim acq hw" ;;
        site) echo "container sim acq hw site" ;;
        *)    die "unknown layer: $1 (expected container, sim, acq, hw or site)" ;;
    esac
}
layer_at_least() {  # layer_at_least acq  -> true when LAYER is acq, hw or site
    local want="$1" l
    for l in $(layer_chain "$LAYER"); do [[ "$l" == "$want" ]] && return 0; done
    return 1
}

# ---------------------------------------------------------------------------
check_remotes() {
    local rc=0 f url path
    command -v python3 >/dev/null || die "python3 is required"
    say "Checking that every manifest URL resolves"
    while read -r f path url; do
        if git ls-remote --exit-code "$url" >/dev/null 2>&1; then
            printf '  \033[32mok     \033[0m %-46s %s\n' "$path" "$url"
        else
            printf '  \033[31mFAILED \033[0m %-46s %s\n' "$path" "$url"
            rc=1
        fi
    done < <(python3 - "$ROOT" <<'PYEOF'
import sys, yaml, os
root = sys.argv[1]
for f in ("container.repos", "sim.repos", "acq.repos", "hw.repos", "site.repos"):
    p = os.path.join(root, f)
    if not os.path.exists(p):
        continue
    for path, spec in (yaml.safe_load(open(p))["repositories"] or {}).items():
        print(f, path, spec["url"])
PYEOF
)
    if [[ $rc -ne 0 ]]; then
        echo
        warn "Some remotes do not resolve. Entries marked PENDING in the manifests"
        warn "are repositories that have not been created yet; the rest is a real fault."
    fi
    return $rc
}

if [[ $DO_CHECK_REMOTES -eq 1 ]]; then
    check_remotes || true
    exit 0
fi

[[ -n "$LAYER" ]] || { usage; die "no --layer given"; }
layer_chain "$LAYER" >/dev/null

# ===========================================================================
phase_prereqs() {
    say "Prerequisites"

    # The container layer is the one layer that is meant to work anywhere: it
    # supplies the Ubuntu the others need. It wants git and docker, nothing
    # from apt, so do not send a non-Ubuntu host down the apt path for it.
    if [[ "$LAYER" == "container" ]]; then
        local missing=()
        command -v git    >/dev/null || missing+=(git)
        command -v docker >/dev/null || missing+=(docker)
        if [[ ${#missing[@]} -gt 0 ]]; then
            die "the container layer needs: ${missing[*]}"
        fi
        note "container layer: git and docker present, nothing else required"
        return 0
    fi

    if [[ ! -f /etc/os-release ]] || ! grep -qi ubuntu /etc/os-release; then
        warn "This is not Ubuntu. The package names below are Debian/Ubuntu names"
        warn "and apt will not exist elsewhere. Install the equivalents by hand."
    fi

    local pkgs=(
        python3-pip python3-vcstool python3-colcon-common-extensions
        python3-rosdep git wget unzip
    )
    # spatialnde2 needs a full C++/SWIG/Qt/OSG toolchain. Taken from its own
    # README's Ubuntu line so the two cannot drift apart.
    layer_at_least acq && pkgs+=(
        cmake swig python3-dev cython3 python3-numpy python3-setuptools
        python3-wheel python3-tomli-w python3-setuptools-scm libxml2-dev
        libeigen3-dev libhdf5-dev opencl-headers ocl-icd-opencl-dev
        opencl-clhpp-headers libpng-dev libopenscenegraph-dev freeglut3-dev
        qtbase5-dev qttools5-dev python3-pyqt5 python3-matplotlib
        python3-pyopencl
        # Blender provides the mesh UV parameterization that surface projection
        # needs; `bpy` is the same thing importable from Python.
        blender
    )

    run "sudo apt-get update"
    run "sudo apt-get install -y ${pkgs[*]}"

    # rosdep init fails, loudly and uselessly, if it has already been done.
    if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
        run "sudo rosdep init"
    else
        note "rosdep already initialised"
    fi
    run "rosdep update --rosdistro $ROSDISTRO"

    if [[ ! -d "/opt/ros/$ROSDISTRO" ]]; then
        local msg="ROS $ROSDISTRO is not installed at /opt/ros/$ROSDISTRO.
   Install it first: https://docs.ros.org/en/$ROSDISTRO/Installation.html"
        # Under --dry-run the point is to see the whole plan, so this is not
        # allowed to cut the run short.
        if [[ $DRYRUN -eq 1 ]]; then warn "$msg"; else die "$msg"; fi
    fi
}

# vcstool is an apt package, and --phase prereqs is apt-only. The container
# layer exists precisely because the host need not be Ubuntu, so requiring apt
# to obtain it would be circular. A manifest entry is only "clone this URL at
# this version", so do that directly when vcs is unavailable.
import_manifest() {
    local manifest="$1"
    if command -v vcs >/dev/null; then
        run "vcs import --input '$manifest' '$ROOT'"
        return
    fi
    # NOT `git clone --branch`: a manifest version may be a branch, a tag OR a
    # commit, and --branch rejects a commit. Clone, then check out whatever it
    # is. A failure has to fail the phase -- a half-imported workspace that
    # reports success is worse than one that stops.
    local path url version rc=0
    while IFS=$'\t' read -r path url version; do
        if [[ -d "$ROOT/$path/.git" ]]; then
            note "$path already present"
            continue
        fi
        if ! run "git clone --quiet '$url' '$ROOT/$path'"; then
            warn "clone failed: $path"; rc=1; continue
        fi
        if ! run "git -C '$ROOT/$path' checkout --quiet '$version'"; then
            warn "no such version '$version' in $path"; rc=1; continue
        fi
        note "$path at $version"
    done < <(python3 - "$manifest" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for path, spec in (d.get("repositories") or {}).items():
    print("%s\t%s\t%s" % (path, spec["url"], spec["version"]))
PYEOF
)
    return $rc
}

phase_sources() {
    say "Sources"
    command -v vcs >/dev/null \
        || note "vcstool not found; cloning from the manifests directly"
    mkdir -p "$WS/src"
    for l in $(layer_chain "$LAYER"); do
        note "importing $l.repos"
        import_manifest "$ROOT/$l.repos" \
            || fatal_unless_dry "$l.repos did not import cleanly (see above)"
    done

    if [[ $WITH_TEST_DATA -eq 1 ]]; then
        install_test_data
    fi

    if [[ $WITH_SOFA -eq 1 ]]; then
        install_sofa
    fi
}

install_test_data() {
    local dir="$ROOT/test_data"
    local url="git@github.com:Adaptive-Robotic-NDE/test_data_staging.git"
    if [[ -d "$dir" ]]; then note "test data already present at $dir"; return 0; fi
    command -v git-lfs >/dev/null 2>&1 \
        || die "git-lfs is required for the test fixtures; install it first"
    say "recorded scan fixtures (git-lfs)"
    run "git clone '$url' '$dir'"
}

install_sofa() {
    local dir="$WS/src/sofa"
    local url="https://github.com/sofa-framework/sofa/releases/download/v25.12.00/SOFA_v25.12.00_Linux-Python_3.10.zip"
    if [[ -d "$dir" ]]; then note "SOFA already present at $dir"; return 0; fi
    say "SOFA binary release (1.3 GB)"
    run "wget -qO /tmp/sofa.zip '$url'"
    run "mkdir -p '$dir'"
    run "unzip -q /tmp/sofa.zip -d '$dir'"
    run "rm /tmp/sofa.zip"
    run "mv '$dir'/SOFA_v*/* '$dir'/"
    run "rmdir '$dir'/SOFA_v* 2>/dev/null || rm -rf '$dir'/SOFA_v*"
    # SOFA is not a ROS package and its CMakeLists.txt is not one either.
    run "touch '$dir/COLCON_IGNORE'"
}

phase_rosdep() {
    say "System dependencies"
    source_ros
    run "rosdep install --from-paths '$WS/src' --ignore-src -y -r --rosdistro $ROSDISTRO"

    if layer_at_least hw; then
        check_vendor_sdks
    fi
}

# Two hardware dependencies that rosdep structurally cannot supply. Both are
# checked here rather than discovered at build or run time.
check_vendor_sdks() {
    local missing=0
    say "Vendor SDKs"

    if ldconfig -p 2>/dev/null | grep -q libk4a; then
        note "Azure Kinect SDK (libk4a) found"
    else
        missing=1
        cat >&2 <<'EOF'

  MISSING: Azure Kinect Sensor SDK (libk4a)

  azure_kinect_ros_driver links against it. It is not installable by rosdep --
  it comes from Microsoft's repository and requires accepting a licence, so it
  cannot be automated here. On 22.04 the packages come from the 18.04 pool:

      curl -sSL https://packages.microsoft.com/keys/microsoft.asc \
          | sudo gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
      echo "deb [signed-by=/usr/share/keyrings/microsoft.gpg] \
          https://packages.microsoft.com/ubuntu/18.04/prod bionic main" \
          | sudo tee /etc/apt/sources.list.d/microsoft-prod.list
      sudo apt-get update && sudo apt-get install -y libk4a1.4-dev k4a-tools

EOF
    fi

    if python3 -c "import nidaqmx" 2>/dev/null; then
        note "NI-DAQmx Python bindings found"
    else
        missing=1
        cat >&2 <<'EOF'
  MISSING: NI-DAQmx

  dgpython-nidaqmx imports it at module load. Proprietary, x86-64 only, from
  National Instruments. Install the driver, then: pip install nidaqmx

EOF
    fi

    if [[ $missing -eq 1 ]]; then
        fatal_unless_dry "hardware layer requested but vendor SDKs are missing (see above).
   Everything except the drivers above will still build with --layer acq."
    fi
}

phase_python() {
    layer_at_least acq || { note "python phase is acq and above; skipping for --layer $LAYER"; return 0; }
    say "dataguzzler-python stack"
    note "colcon does not build any of this; dgpy_install.sh does."
    if [[ $DRYRUN -eq 1 ]]; then
        run "'$ROOT/dgpy_install.sh' --dry-run"
    else
        "$ROOT/dgpy_install.sh"
    fi
}

phase_build() {
    say "colcon build"
    source_ros

    # sofaros2plugin does a hard CMake error("Please specify variable
    # SOFA_INSTALL_DIR") when that variable is unset, and one failing package
    # aborts the whole build -- so without this, a default bootstrap that never
    # asked for SOFA dies partway through with an error about soft robotics.
    #
    # SOFA is opt-in (--with-sofa), so when it is absent the package that needs
    # it is skipped rather than ignored on disk: --packages-skip leaves the
    # source tree untouched, where a COLCON_IGNORE file would show up as an
    # uncommitted change in tari_ros forever.
    local skip=()
    if [[ -d "$WS/src/sofa" ]]; then
        export SOFA_INSTALL_DIR="$WS/src/sofa"
        note "SOFA_INSTALL_DIR=$SOFA_INSTALL_DIR"
    else
        skip=(--packages-skip ros2plugin)
        note "SOFA not present; skipping ros2plugin (use --with-sofa to build it)"
    fi
    # ONE build, ONE build type. The previous bootstrap ran a release build and
    # then a second --symlink-install build for a single package; mixing them in
    # one workspace is what produced packages with an install/ tree and no ament
    # index marker, which fail every ros2 run silently. Release flags live in
    # colcon_defaults.yaml next to this script rather than in a mixin fetched
    # from the internet at bootstrap time.
    run "cd '$WS' && colcon build --symlink-install ${skip[*]}"
}

phase_env() {
    say "Environment"
    local out="$ROOT/tari_setup.bash"
    local models="$WS/src/tari_ros/tari_ur_launch/models"

    cat > "$out" <<EOF
# Generated by tari.bash on $(date -u +%Y-%m-%dT%H:%M:%SZ) for layer '$LAYER'.
# Regenerate with: ./tari.bash --layer $LAYER --phase env
#
# Source this in every shell that runs anything here, INCLUDING shells that run
# dataguzzler-python. dgpython_rosmotion is a colcon package, so \`import
# dgpython_rosmotion\` in a .dgp resolves through the overlay, not through pip.

source /opt/ros/$ROSDISTRO/setup.bash
[ -f "$WS/install/setup.bash" ] && source "$WS/install/setup.bash"

# Gazebo finds our models here rather than by copying them into
# /usr/share/gazebo-11/models, which needed root, was not idempotent, and left
# stale copies behind whenever a model was renamed.
export GAZEBO_MODEL_PATH="$models\${GAZEBO_MODEL_PATH:+:\$GAZEBO_MODEL_PATH}"

EOF

    # Cell manifests: tari_bringup searches every PACKAGE named in
    # TARI_CELL_PATH first and its own config/cells last, so a site manifest
    # overrides a shipped one without editing the shared package. A package
    # name rather than a path, so it survives the workspace moving.
    #
    # Only written for the site layer. Naming tari_cell_configs in a sim-layer
    # setup would point at a package that layer deliberately does not have --
    # harmless, because search_paths() ignores entries it cannot resolve, but
    # it reads like the setup is broken when it is doing exactly the right
    # thing.
    if layer_at_least site; then
        cat >> "$out" <<EOF

export TARI_CELL_PATH="tari_cell_configs\${TARI_CELL_PATH:+:\$TARI_CELL_PATH}"
EOF
    fi

    if [[ -d "$WS/src/sofa" ]]; then
        echo "export SOFA_INSTALL_DIR=\"$WS/src/sofa\"" >> "$out"
    fi

    note "wrote $out"
    note "source it with:  source ./tari_setup.bash"
}

phase_verify() {
    say "Verify (layer: $LAYER)"
    if [[ $DRYRUN -eq 1 ]]; then
        note "would check the ament index for the layer's packages,"
        note "and run dgpy_install.sh --check for acq and above"
        return 0
    fi
    local rc=0

    # Every layer: the overlay exists and the packages that layer promised are
    # findable through the ament index -- not merely present in install/, which
    # is the failure mode a partial build produces.
    if [[ ! -f "$WS/install/setup.bash" ]]; then
        warn "no colcon overlay at $WS/install"; return 1
    fi
    source_ros
    source_quietly "$WS/install/setup.bash"

    local expect=(tari_bringup tari_interfaces tari_cpp_mtc tari_noether_srv
                  dgpython_ros2_actionserver)
    layer_at_least site && expect+=(tari_cell_configs)
    for p in "${expect[@]}"; do
        if ros2 pkg prefix "$p" >/dev/null 2>&1; then
            printf '  \033[32mok     \033[0m %s\n' "$p"
        else
            printf '  \033[31mMISSING\033[0m %s (built but not on the ament index?)\n' "$p"
            rc=1
        fi
    done

    if layer_at_least acq; then
        echo
        note "dataguzzler-python stack:"
        "$ROOT/dgpy_install.sh" --check || rc=1
    fi

    echo
    if [[ $rc -eq 0 ]]; then
        say "Layer '$LAYER' verified."
        case "$LAYER" in
            sim) note "Try: ros2 launch tari_bringup bringup.launch.py cell:=sim mode:=sim" ;;
            *)   note "Try: ros2 run tari_bringup tari_cell_info --cell sim --mode sim" ;;
        esac
    else
        warn "Layer '$LAYER' did not verify cleanly (see above)."
    fi
    return $rc
}

# ===========================================================================
if [[ -n "$ONLY_PHASE" ]]; then
    printf '%s\n' "${ALL_PHASES[@]}" | grep -qx "$ONLY_PHASE" \
        || die "unknown phase: $ONLY_PHASE (one of: ${ALL_PHASES[*]})"
    "phase_$ONLY_PHASE"
    exit $?
fi

for p in "${ALL_PHASES[@]}"; do
    "phase_$p"
done
