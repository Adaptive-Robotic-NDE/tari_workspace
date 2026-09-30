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

# Is a shared library in the loader cache?
#
# NOT `ldconfig -p | grep -q <name>`, which is wrong under `set -o pipefail` and
# silently reports the opposite of the truth. `ldconfig -p` prints a few thousand
# lines; `grep -q` exits at the FIRST match and closes the pipe, ldconfig then
# dies of SIGPIPE, and pipefail makes the pipeline's status 141 -- so the `if`
# takes the "not installed" branch precisely BECAUSE the library was found:
#
#     $ set -euo pipefail
#     $ if ldconfig -p | grep -q libk4a; then echo FOUND; else echo "NOT ($?)"; fi
#     NOT (141)
#     $ set +o pipefail; ldconfig -p | grep -q libk4a && echo FOUND
#     FOUND
#
# Measured on lablinux 2026-09-30, where this made --layer hw refuse to build
# with "MISSING: Azure Kinect Sensor SDK" on a machine carrying libk4a 1.4.2 and
# a working k4aConfig.cmake. Read all of ldconfig's output first; then nothing
# closes a pipe early.
have_shared_lib() {
    local cache
    cache="$(ldconfig -p 2>/dev/null || true)"
    grep -Fq "$1" <<<"$cache"
}
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

# ---------------------------------------------------------------------------
# The ROS 2 apt repository.
#
# This has to happen BEFORE the first apt-get install, not after it.
# python3-vcstool, python3-colcon-common-extensions and python3-rosdep are not
# in Ubuntu universe: on 22.04 each has exactly one version-table entry and it
# is this repository. The old order -- apt-get install, then notice /opt/ros is
# missing and tell the user to go and install ROS -- could never work on a
# machine that had not had ROS on it already.
#
# Iron is end-of-life. That means nothing new will be published, not that the
# suite is gone: as of 2026-09-30 the jammy index still carries 2164 ros-iron-*
# binaries, frozen at their November 2024 builds, including every package this
# workspace needs.
#
# HTTPS to packages.ros.org is, as of 2026-09-30, broken. The name is a CNAME to
# ftp.osuosl.org, which serves a certificate covering only osuosl.org and
# *.osuosl.org, so the SNI never matches and every TLS client rejects it -- on
# IPv4 and IPv6 alike, and regardless of the local CA store:
#
#     curl: (60) SSL: no alternative certificate subject name matches
#           target host name 'packages.ros.org'
#
# So try three URLs in order: packages.ros.org over https, which starts working
# again by itself the day they fix the certificate; the same tree on the osuosl
# mirror over https; and packages.ros.org over http. Falling back to http is not
# a security downgrade that matters here -- apt authenticates a repository by the
# detached GPG signature on InRelease, which is why signed-by below is not
# optional. It is also why an unsigned or keyless workaround is never acceptable.
# ---------------------------------------------------------------------------
# The ROS 2 apt repository.
#
# Open Robotics reorganised their repository hosting and now ship a versioned
# `ros2-apt-source` package that installs the signing key and the sources list
# together. That is the current upstream instruction and it is what
# ensure_ros_apt_repo() follows, so the key rotating or the host moving stops
# being something this script has to track.
#
# It also avoids a live fault: https://packages.ros.org currently presents a
# certificate for *.osuosl.org, so fetching that host directly over https fails
# name verification. The deb is fetched from GitHub releases instead, over https
# with a valid certificate, and apt still authenticates the repository itself by
# the detached GPG signature on InRelease.
#
# ROS Iron is end of life, so its package set is frozen. That is expected; the
# workspace is pinned to Iron and several packages will not build against a newer
# distribution.
# ---------------------------------------------------------------------------

ensure_ros_apt_repo() {
    # UPSTREAM'S OWN PACKAGE DOES THIS NOW, and that is what this uses.
    #
    # Open Robotics reorganised the repositories and ship a `ros2-apt-source` deb
    # that installs the signing key and the sources list together, versioned, so
    # the key rotating or the host moving is their problem rather than a
    # hand-written list going stale here. It also sidesteps a real fault: at the
    # time of writing, https://packages.ros.org presents a certificate for
    # *.osuosl.org, so a direct https fetch of that host fails name verification.
    #
    # The deb comes from GitHub releases over https with a valid certificate, and
    # apt still verifies the repository signature afterwards.
    if [[ -f /etc/apt/sources.list.d/ros2.list ]] \
       || dpkg -s ros2-apt-source >/dev/null 2>&1; then
        note "ROS apt repository already configured"
        return 0
    fi
    say "ROS 2 apt repository (upstream ros2-apt-source)"
    run "sudo apt-get update"
    run "sudo apt-get install -y --no-remove curl ca-certificates gnupg"

    if [[ $DRYRUN -ne 0 ]]; then
        note "would install the latest ros2-apt-source deb for this Ubuntu release"
        return 0
    fi

    local version codename deb
    version="$(curl -fsS https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
                | grep -F '"tag_name"' | awk -F'"' '{print $4}')"
    [[ -n "$version" ]] || die "could not read the latest ros-apt-source release from GitHub.
   Check network access to api.github.com, or install the repository by hand:
     https://docs.ros.org/en/$ROSDISTRO/Installation.html"
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"
    deb="/tmp/ros2-apt-source_${version}.${codename}_all.deb"
    note "ros-apt-source $version for $codename"
    run "curl -fsSL -o '$deb' \
         'https://github.com/ros-infrastructure/ros-apt-source/releases/download/${version}/ros2-apt-source_${version}.${codename}_all.deb'"
    run "sudo dpkg -i '$deb'"
    run "rm -f '$deb'"
    run "sudo apt-get update"
}

# ---------------------------------------------------------------------------
# The ROS packages to install from apt.
#
# Deliberately NOT a transcription of every package.xml in ros_ws/src -- rosdep
# resolves those, and phase_rosdep runs it. This is the metapackages plus the
# few things rosdep structurally cannot reach:
#
#   pick-ik    MoveIt loads it BY NAME out of
#              tari_ur_description/config/kinematics.yaml
#              (kinematics_solver: pick_ik/PickIkPlugin). A plugin named in a
#              YAML string appears in no package.xml, so no rosdep run will ever
#              install it -- and without it move_group comes up with no IK
#              solver and every scan pass moves 0 mm.
#   gazebo-*   Gazebo Classic. Iron pulls in none of it by default.
#   ur*        the UR driver, description and MoveIt config; needed in sim too.
#   moveit-resources-*-moveit-config
#              test dependencies of moveit_task_constructor, which is built from
#              source here and fails its tests without them.
# ---------------------------------------------------------------------------
ros_apt_packages() {
    local p
    for p in desktop moveit moveit-visual-tools pick-ik \
             gazebo-ros-pkgs gazebo-ros2-control \
             ur ur-robot-driver ros2-control ros2-controllers \
             rmw-cyclonedds-cpp pcl-ros pcl-conversions graph-msgs \
             py-binding-tools generate-parameter-library backward-ros \
             rviz-visual-tools camera-info-manager cv-bridge image-transport \
             tf2-sensor-msgs angles xacro \
             joint-state-publisher joint-state-publisher-gui \
             realsense2-camera realsense2-description \
             moveit-resources-panda-moveit-config \
             moveit-resources-fanuc-moveit-config \
             launch-testing-ament-cmake ros2-controllers-test-nodes \
             ament-cmake-clang-format ros-testing; do
        echo "ros-$ROSDISTRO-$p"
    done
    # System libraries the source packages in ros_ws/src need to build. rosdep
    # would find most of these too; naming them costs nothing and means a
    # `--phase prereqs` run alone leaves a machine that can compile.
    cat <<'EOF'
libvtk9-dev
libvtk9-qt-dev
libboost-dev
libboost-filesystem-dev
liburdfdom-headers-dev
libyaml-cpp-dev
libfmt-dev
libpcl-dev
libclang-dev
socat
python3-opencv
python3-yaml
python3-pytest
EOF
}

# ---------------------------------------------------------------------------
# Python modules the sim layer's nodes import, that apt does not carry and that
# rosdep cannot reach.
#
# This is the pick_ik problem in Python form. A module named only in an `import`
# statement appears in no package.xml -- and unlike pick_ik there is no rosdep
# key to declare even if it did, because none of these exists as an Ubuntu
# package (`apt-cache policy python3-trimesh python3-pyquaternion` finds
# nothing) and `rosdep resolve` answers "no rosdep rule" for every spelling. So
# the ONLY thing that installs them is this list. Missing, the nodes start and
# then exit 1 on the import, and bring-up reports them as OK because it checked
# the graph before they died:
#
#     industrial_reconstruction   ModuleNotFoundError: No module named 'pyquaternion'
#     pc_reconstruction_srv       ModuleNotFoundError: No module named 'trimesh'
#     pc_reconstruction_action    ModuleNotFoundError: No module named 'trimesh'
#
# Both are pure Python over numpy, so --no-deps costs nothing and keeps pip from
# rewriting anything else in /usr/local, which on a shared machine belongs to
# other projects.
#
# trimesh IS PINNED BELOW 4 ON PURPOSE. 22.04's numpy is apt's 1.21.5, and that
# version is not a free choice: python3-open3d 0.14.1 is built against it, and
# the whole reconstruction path runs on that pair. trimesh 5.1.0 imports
# `ndarray[tuple[int], dtype[DType]]` at module scope, which needs a newer numpy
# typing and dies on 1.21.5 with
#
#     TypeError: 'numpy._DTypeMeta' object is not subscriptable
#
# so installing the current trimesh looks fine and then fails at import. 3.23.5
# is what resolves and works here. Never fix this by upgrading numpy.
#
# TWO MORE ARE NOT HERE, because they cannot be satisfied this way:
#
#   bpy          tari_mesh_filter_srv and x3d_converter do `import bpy` at the
#                top and die without it. jammy's blender ships no Python module,
#                and PyPI has no bpy wheel for CPython 3.10 on Linux, so on
#                22.04 there is no `import bpy` for the system interpreter at
#                all. Those two nodes cannot run on this platform; they need
#                Blender's own interpreter, or a Blender built as a module.
#   ultralytics  plus `lap`, for yolo_ros. Deliberately left out: the wheel
#                closure pulls torch, which is gigabytes and its own CUDA
#                decision. Bring-up already SKIPs yolo by name when they are not
#                importable, which is the correct behaviour rather than a fault.
# ---------------------------------------------------------------------------
PIP_PREREQS=(pyquaternion "trimesh<4")

install_pip_prereqs() {
    local missing=()
    python3 -c 'import pyquaternion' 2>/dev/null || missing+=(pyquaternion)
    python3 -c 'import trimesh'      2>/dev/null || missing+=("trimesh<4")
    if [[ ${#missing[@]} -eq 0 ]]; then
        note "pip prerequisites already present: ${PIP_PREREQS[*]}"
        return 0
    fi
    say "Python modules apt does not have"
    note "${missing[*]}"
    # --no-deps, system-wide, same rule as every other install here.
    run "sudo python3 -m pip install --no-deps $(printf "'%s' " "${missing[@]}")"
}

# ---------------------------------------------------------------------------
# The same problem again, one layer up, for a dataguzzler-python module rather
# than a ROS node.
#
# dgpython_uniwest declares no dependencies at all, and dgpy_install.sh installs
# with --no-deps by policy, so nothing anywhere names what it imports. It will
# not import without both of these -- and the failure is at IMPORT, before any
# instrument is contacted, so it is not "no hardware attached":
#
#     dgpython_uniwest/U454ALowLevelHelper.py   import pyvisa
#     dgpython_uniwest/GPIBLowLevelHelper.py    from events import Events
#
# GPIBLowLevelHelper is reached from U454ALowLevelHelper at module scope, so the
# GPIB path being unused does not make `events` optional.
#
# pyvisa comes from apt because jammy HAS it (python3-pyvisa 1.11.3 in universe,
# with python3-pyvisa-py for the serial backend the U454A talks over). `events`
# is the PyPI Events package and has no Ubuntu package under any spelling, so it
# is the one that has to be pip'd, --no-deps like the rest.
#
# hw only: a sim- or acq-layer machine has no UniWest and no reason to carry a
# VISA stack.
# ---------------------------------------------------------------------------
install_hw_python_prereqs() {
    layer_at_least hw || return 0
    local apt_missing=() pip_missing=()
    python3 -c 'import pyvisa' 2>/dev/null || apt_missing+=(python3-pyvisa python3-pyvisa-py)
    python3 -c 'import events' 2>/dev/null || pip_missing+=(Events)
    if [[ ${#apt_missing[@]} -eq 0 && ${#pip_missing[@]} -eq 0 ]]; then
        note "instrument-module Python prerequisites already present: pyvisa, events"
        return 0
    fi
    say "Python modules the instrument drivers import"
    [[ ${#apt_missing[@]} -gt 0 ]] && \
        run "sudo apt-get install -y --no-remove ${apt_missing[*]}"
    [[ ${#pip_missing[@]} -gt 0 ]] && \
        run "sudo python3 -m pip install --no-deps $(printf "'%s' " "${pip_missing[@]}")"
    return 0
}

# ---------------------------------------------------------------------------
# `command -v vcs` is not enough to know vcstool works.
#
# vcstool's console script still does `from pkg_resources import
# load_entry_point`, and setuptools dropped pkg_resources in 81. So any
# `pip install -U setuptools` anywhere on the system leaves /usr/bin/vcs present
# and broken:
#
#     ModuleNotFoundError: No module named 'pkg_resources'
#
# Seen for real on a machine where another project had run
# `sudo pip3 install setuptools --break-system-packages`: dpkg still reported
# python3-pkg-resources as installed while all 17 of its files were gone from
# disk. Reinstalling that one package restores them and does not touch the newer
# setuptools in /usr/local, which belonged to the other project and had to stay.
# ---------------------------------------------------------------------------
ensure_working_vcs() {
    command -v vcs >/dev/null || return 0
    vcs --version >/dev/null 2>&1 && return 0

    warn "vcs is installed but does not run:"
    vcs --version 2>&1 | sed 's/^/    /' >&2 || true
    if ! python3 -c 'import pkg_resources' 2>/dev/null; then
        note "pkg_resources is missing entirely; restoring python3-pkg-resources"
        note "(same version, nothing removed, /usr/local left alone)"
        run "sudo apt-get install -y --reinstall python3-pkg-resources"
    fi
    if vcs --version >/dev/null 2>&1; then
        note "vcs works now: $(vcs --version)"
    else
        warn "vcs still does not run. phase_sources will clone from the manifests"
        warn "directly instead, which is equivalent, just slower."
    fi
}

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
        build-essential curl gnupg
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
        # An OpenCL implementation, not just the headers and the loader.
        # ocl-icd-opencl-dev supplies libOpenCL.so, which spatialnde2 links, but
        # no driver -- and with no ICD installed, or only one whose driver is not
        # working, clGetPlatformIDs returns PLATFORM_NOT_FOUND_KHR and
        # snde.setup_opencl() raises. Every .dgp here calls it, and so do
        # spatialnde2's own cscan_gate and kdtree tests.
        #
        # PoCL runs on the CPU, so it depends on no GPU driver and cannot be
        # broken by one. It is also what the container image falls back to, which
        # makes it the configuration this stack has actually been run in. A GPU
        # ICD, where the machine has a usable GPU, is an addition rather than a
        # replacement: the loader picks whichever platform enumerates.
        pocl-opencl-icd
        qtbase5-dev qttools5-dev python3-pyqt5 python3-matplotlib
        python3-pyopencl
        # Blender, for the mesh UV parameterization that surface projection
        # needs -- as a PROGRAM. It is NOT the same thing as `import bpy`:
        # jammy's blender 3.0.1 installs no Python module at all (dpkg -L
        # blender lists nothing named bpy), and PyPI has no bpy wheel for
        # CPython 3.10 on Linux any more, so on 22.04 there is no way to make
        # `import bpy` work for the system interpreter. See the bpy note beside
        # PIP_PREREQS below for what that costs at run time.
        blender
        # open3d. jammy/universe has it as python3-open3d 0.14.1, which is the
        # same package the container image installs, so this is the version the
        # reconstruction has been run against.
        #
        # Named here rather than left to rosdep because the ROS packages are not
        # the only consumers: ROS-Scanning's own .dpi modules
        # (mesh_reconstruction, mesh_scan, noether_path, keyence_standoff,
        # azure_gauge) import open3d, and ROS-Scanning is not in ros_ws/src, so
        # no rosdep run over the colcon workspace will ever cover it.
        #
        # DO NOT pip install open3d instead. Its wheel's dependency closure is
        # about sixty distributions, and resolved against Ubuntu 22.04 it wants
        # newer MarkupSafe, attrs, blinker, click and traitlets than apt's --
        # which pip writes into /usr/local, ahead of the apt copies on sys.path,
        # for every project on the machine. (With --no-deps it does not import at
        # all: open3d's __init__ eagerly imports open3d.visualization, which
        # imports plotly and dash.)
        python3-open3d
    )

    # curl and gnupg are needed to fetch and check the ROS signing key, and the
    # three ROS-repo-only packages above are needed before anything else, so the
    # repository has to exist first. --no-remove on every install: apt is never
    # allowed to solve a dependency by taking something off this machine.
    ensure_ros_apt_repo
    run "sudo apt-get update"
    run "sudo apt-get install -y --no-remove ${pkgs[*]}"
    ensure_working_vcs
    install_pip_prereqs
    install_hw_python_prereqs

    # ROS itself, and the packages rosdep cannot reach. Idempotent: apt does
    # nothing when they are all present, so this also serves as the top-up after
    # a pull that added a dependency.
    say "ROS $ROSDISTRO"
    if [[ -d "/opt/ros/$ROSDISTRO" ]]; then
        note "already present at /opt/ros/$ROSDISTRO; topping up"
    else
        note "not present; installing (about 930 packages, a few minutes)"
    fi
    run "sudo apt-get install -y --no-remove $(ros_apt_packages | tr '\n' ' ')"
    if [[ ! -d "/opt/ros/$ROSDISTRO" ]]; then
        fatal_unless_dry "apt finished but there is still no /opt/ros/$ROSDISTRO.
   If apt could not find the ros-$ROSDISTRO-* packages, check
   /etc/apt/sources.list.d/ros2.list and see the comment on
   ensure_ros_apt_repo in this script."
    fi

    # rosdep init fails, loudly and uselessly, if it has already been done.
    if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
        run "sudo rosdep init"
    else
        note "rosdep already initialised"
    fi
    run "rosdep update --rosdistro $ROSDISTRO"

    # The Azure Kinect SDK is deliberately NOT installed here; see
    # check_vendor_sdks for why, and for the exact commands. Report it early
    # rather than at the end of a long build.
    if layer_at_least hw && ! have_shared_lib libk4a; then
        warn "the Azure Kinect SDK is not installed; --layer hw will stop at the"
        warn "rosdep phase and print the commands. It is a manual step on purpose."
    fi
}

# vcstool is an apt package, and --phase prereqs is apt-only. The container
# layer exists precisely because the host need not be Ubuntu, so requiring apt
# to obtain it would be circular. A manifest entry is only "clone this URL at
# this version", so do that directly when vcs is unavailable.
import_manifest() {
    local manifest="$1"
    # `command -v vcs` alone is a trap: the script can exist and still crash on
    # `from pkg_resources import load_entry_point` (see ensure_working_vcs).
    # Test that it actually runs, or the fallback below never gets a chance.
    if command -v vcs >/dev/null && vcs --version >/dev/null 2>&1; then
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
    run "git clone --quiet '$url' '$dir'"

    # Having the git-lfs BINARY is not enough: clone only replaces pointers with
    # content when the lfs filters are configured, and `git lfs install` may
    # never have been run on this account. Without this the working tree holds
    # pointer files, which is worse than having nothing -- the paths exist, so
    # the suites read a pointer where they expect a mesh.
    run "git -C '$dir' lfs install --local"
    run "git -C '$dir' lfs pull"

    local probe
    probe="$(find "$dir" -name '*.ply' -print -quit 2>/dev/null)"
    if [[ -n "$probe" ]] && head -c 40 "$probe" | grep -q 'git-lfs.github.com'; then
        die "the fixtures are still git-lfs pointers, not content: $probe"
    fi
    note "fixtures fetched and verified as content, not pointers"
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

# Rosdep keys that must NOT be resolved. Each one needs a reason.
#
#   libvtk   The generic key resolves to libvtk7-dev on jammy, and VTK 7 and
#            VTK 9 cannot be installed at the same time -- apt satisfies one by
#            removing the other. VTK 9 is the one to keep, and not as a
#            preference: noether_tpp/CMakeLists.txt asks for `VTK 9 REQUIRED`,
#            so vtk7 would not build it anyway. noether_tpp's package.xml
#            declares the generic key, which is why this is skipped here rather
#            than fixed by declaring a version. libvtk9-dev is in the prereq
#            list, so VTK 9 is present on purpose rather than arriving as
#            somebody else's dependency.
#
#   catkin   hw.repos pins libsocket, a third-party C++ socket library whose
#            package.xml is a ROS 1 one: format 2, `build_type: cmake`, and
#            `<buildtool_depend>catkin</buildtool_depend>`. There is no `catkin`
#            rosdep rule under a ROS 2 distribution, so rosdep answers
#
#                libsocket: Cannot locate rosdep definition for [catkin]
#
#            and drops that package's whole key set. libsocket needs nothing
#            else, so nothing is lost, but the line reads as a fault and buries
#            the real ones. It is a pinned upstream checkout, so editing its
#            manifest in the working tree would be undone by the next
#            `vcs import`; skipping the key is the fix that survives.
ROSDEP_SKIP_KEYS=(libvtk catkin)

phase_rosdep() {
    say "System dependencies"
    source_ros
    # --no-remove is not available through rosdep, so the skip list above is what
    # keeps apt from being asked to trade VTK 9 for VTK 7.
    run "rosdep install --from-paths '$WS/src' --ignore-src -y -r \
         --rosdistro $ROSDISTRO --skip-keys '${ROSDEP_SKIP_KEYS[*]}'"

    if layer_at_least hw; then
        check_vendor_sdks
    fi
}

# Two hardware dependencies that rosdep structurally cannot supply. Both are
# checked here rather than discovered at build or run time.
check_vendor_sdks() {
    local missing=0
    say "Vendor SDKs"

    if have_shared_lib libk4a; then
        note "Azure Kinect SDK (libk4a) found"
    else
        missing=1
        cat >&2 <<'EOF'

  MISSING: Azure Kinect Sensor SDK (libk4a)

  azure_kinect_ros_driver links against it, and CMake fails with "could not
  find k4aConfig.cmake" rather than anything about a camera.

  NOT AUTOMATED, on purpose, for three reasons: it needs Microsoft's licence
  accepted, it temporarily adds a DIFFERENT Ubuntu release's archive to this
  machine, and it is only ever needed by --layer hw. Run it yourself and watch
  it. Verified working on Ubuntu 22.04 on 2026-09-30; every command below was
  actually run, in this order.

  1. libsoundio1. libk4a1.4 hard-depends on it and jammy does not have it, so
     it comes from focal. Pin focal below jammy so that NOTHING ELSE can ever
     be satisfied from it, and use your own file so /etc/apt/sources.list is
     never edited:

       sudo tee /etc/apt/sources.list.d/zz-focal-temp.list <<<'deb http://us.archive.ubuntu.com/ubuntu focal main universe'
       printf 'Package: *\nPin: release n=focal\nPin-Priority: 100\n' \
           | sudo tee /etc/apt/preferences.d/zz-focal-temp
       sudo apt-get update && sudo apt-get install -y --no-remove libsoundio1
       sudo rm /etc/apt/sources.list.d/zz-focal-temp.list /etc/apt/preferences.d/zz-focal-temp
       sudo apt-get update

  2. Microsoft's 18.04 pool, as a keyring plus a source file. Do NOT install
     packages-microsoft-prod.deb: removing its source file afterwards then
     leaves dpkg owning files that are not there.

       curl -sSL https://packages.microsoft.com/keys/microsoft.asc \
           | sudo gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg
       echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] \
           https://packages.microsoft.com/ubuntu/18.04/prod bionic main" \
           | sudo tee /etc/apt/sources.list.d/microsoft-prod.list
       sudo apt-get update

  3. The SDK. libk4a1.4's preinst presents Microsoft's EULA through debconf,
     and it calls `db_fset accept-eula seen false` before asking -- so under
     DEBIAN_FRONTEND=noninteractive the question cannot be asked and the
     install fails with:

         eula agree question could not be asked
         libk4a1.4 will not be installed
         dpkg: error processing archive .../libk4a1.4_1.4.2_amd64.deb (--unpack)

     Preseeding accept-eula does not help, for the same reason. The preinst's
     FIRST check is an environment variable, and that is the way through:

       sudo DEBIAN_FRONTEND=noninteractive ACCEPT_EULA=Y \
           apt-get install -y --no-remove 'libk4a1.4*' k4a-tools

     ACCEPT_EULA=Y accepts Microsoft's licence. Read it first if you have not.

  4. Banish the repository again, and check the thing the build needs:

       sudo rm /etc/apt/sources.list.d/microsoft-prod.list /usr/share/keyrings/microsoft.gpg
       sudo apt-get update
       ldconfig -p | grep libk4a
       ls /usr/lib/x86_64-linux-gnu/cmake/k4a/k4aConfig.cmake

  Do not run k4aviewer to check: it needs a camera and a display. The
  find_package above is the real test.

EOF
    fi

    if python3 -c "import nidaqmx" 2>/dev/null; then
        note "NI-DAQmx Python bindings found"
    else
        missing=1
        cat >&2 <<'EOF'
  MISSING: NI-DAQmx

  dgpython-nidaqmx imports it at module load. Proprietary, x86-64 only, from
  National Instruments. Install the driver, then install the bindings the same
  way as everything else here -- system-wide, never per-user:

      sudo python3 -m pip install nidaqmx

EOF
    fi

    if [[ $missing -eq 1 ]]; then
        fatal_unless_dry "hardware layer requested but vendor SDKs are missing (see above).
   Everything except the drivers above will still build with --layer acq."
    fi
}

# ---------------------------------------------------------------------------
# pip-installed Qt shadowing the system Qt.
#
# spatialnde2 is compiled against the system Qt -- qtbase5-dev and
# python3-pyqt5 from apt, which is what the prereqs above install. A pip Qt
# wheel is a second, complete Qt: PyQt6-Qt6 alone is 260 MB of libQt6*.so.6
# inside site-packages, with its own sip module.
#
# That is not inert. dataguzzler_python/Qt.py chooses its bindings at import
# time, and spatialnde2's snde_qt.i typemaps decide whether to hand back
# PySide- or PyQt-wrapped QObjects by looking at which sip module is already
# loaded (PyQt5.sip, then PyQt6.sip). So a stray pip Qt changes which Qt a
# Qt5-compiled library talks to, and the symptom is not a clean ImportError.
#
# Found for real on a lab machine where another project had pip-installed
# PyQt6 6.11.0 system-wide. Warn, and name the packages, rather than removing
# anything: on a shared machine the copy may belong to somebody else.
# ---------------------------------------------------------------------------
warn_about_pip_qt() {
    local found
    found="$(python3 - <<'PYEOF' 2>/dev/null
import os
from importlib.metadata import distributions
interesting = ("pyqt5", "pyqt6", "pyside2", "pyside6", "qtpy",
               "shiboken2", "shiboken6", "opencv-python")
for dist in distributions():
    name = (dist.metadata["Name"] or "")
    if not any(name.lower().startswith(k) for k in interesting):
        continue
    location = os.path.realpath(str(dist.locate_file("")))
    # /usr/lib/python3/dist-packages is where apt puts things -- that is the
    # system Qt and it is the one we want.
    if location.startswith("/usr/lib/python3/"):
        continue
    print("%s %s (%s)" % (name, dist.version, location))
PYEOF
)"
    [[ -z "$found" ]] && return 0
    warn "Qt Python bindings installed outside apt:"
    printf '    %s\n' "$found" >&2
    warn "spatialnde2 links the SYSTEM Qt (qtbase5-dev, python3-pyqt5). A pip Qt"
    warn "ships its own Qt runtime and sip module and can be selected instead at"
    warn "import time, which produces crashes rather than a clean error. If these"
    warn "belong to no project on this machine, remove them before building:"
    warn "    sudo python3 -m pip uninstall <name> ..."
}

phase_python() {
    layer_at_least acq || { note "python phase is acq and above; skipping for --layer $LAYER"; return 0; }
    say "dataguzzler-python stack"
    warn_about_pip_qt
    note "colcon does not build any of this; dgpy_install.sh does."
    # --with-extras, because acq.repos declares spatialnde2-ec-functions and the
    # eddy-current scan does not run without it: ec_acquisition.dpi imports
    # spatialnde2_ec_functions at its top. It is an "extra" in the installer
    # because it costs a compile and is useless on a machine that does no eddy
    # current -- but a machine that imported the manifest declaring it has asked
    # for it. The installer skips any extra whose source is not checked out, so
    # this is a no-op on a workspace that does not have one.
    if [[ $DRYRUN -eq 1 ]]; then
        run "'$ROOT/dgpy_install.sh' --with-extras --dry-run"
        return 0
    fi
    # Exit 2 means every package and every extra the stack actually imports
    # installed, and an extra nothing depends on did not -- see the EXTRAS
    # comment in dgpy_install.sh. The installer has already said which one and
    # why. Failing the phase for it would mean a machine lacking an optional
    # extra's build dependencies could never finish a bootstrap, so this phase
    # carries on and the warning stands.
    local rc=0
    "$ROOT/dgpy_install.sh" --with-extras || rc=$?
    if [[ $rc -eq 2 ]]; then
        warn "an optional dataguzzler-python extra did not build (see above).
   Everything the stack imports is installed; continuing."
        return 0
    fi
    return $rc
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
    #
    # COLCON_DEFAULTS_FILE is not a nicety. colcon-defaults looks for the
    # workspace file at the RELATIVE path `colcon_defaults.yaml`, resolved
    # against the current directory (colcon_defaults/argument_parser/
    # defaults.py: `local_defaults_path = Path(WORKSPACE_DEFAULTS_FILE)`), and
    # this function builds from $WS while the file sits in $ROOT one level up.
    # So the file was never read and neither -DCMAKE_BUILD_TYPE=Release nor
    # -DCMAKE_EXPORT_COMPILE_COMMANDS=ON reached cmake: the whole workspace
    # built with an empty CMAKE_BUILD_TYPE, which means no -O flags at all.
    # Verified on lablinux 2026-09-30 by reading CMAKE_BUILD_TYPE out of
    # ros_ws/build/*/CMakeCache.txt.
    #
    # Parallelism: colcon's default is one worker per core, and an unbounded
    # one of those on a 16-core machine runs sixteen simultaneous C++ links of
    # MoveIt-scale translation units. moveit_task_constructor_core and
    # noether_tpp each peak well over a gigabyte, so the default OOM-kills a
    # compiler on anything with less than about 2 GB per core and the build
    # fails with a bare "c++: fatal error: Killed signal terminated program".
    # Cap the workers at one per 2 GB of AVAILABLE RAM, which is a no-op on a
    # machine that has the memory for its cores. MemAvailable rather than
    # MemTotal on purpose: these machines are shared, and a 28 GB host with
    # another project already holding 11 GB has the headroom of a 16 GB one.
    # TARI_COLCON_WORKERS overrides.
    local workers="${TARI_COLCON_WORKERS:-}"
    if [[ -z "$workers" ]]; then
        local cores mem_gb
        cores="$(nproc)"
        mem_gb="$(awk '/^MemAvailable:/ {printf "%d", $2/1048576}' /proc/meminfo)"
        workers=$(( mem_gb / 2 ))
        [[ $workers -lt 1 ]] && workers=1
        [[ $workers -gt $cores ]] && workers=$cores
        note "$cores cores, ${mem_gb} GB available -> --parallel-workers $workers"
    fi
    run "cd '$WS' && COLCON_DEFAULTS_FILE='$ROOT/colcon_defaults.yaml' \
         colcon build --symlink-install --parallel-workers $workers ${skip[*]}"
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
