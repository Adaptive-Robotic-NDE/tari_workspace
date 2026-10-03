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
#     sources   fetch the layer chain's manifests, one repository at a time
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

# ---------------------------------------------------------------------------
# A SHARED WORKSPACE, DRIVEN BY WHICHEVER HUMAN IS LOGGED IN.
#
# The robot runs as an unprivileged shared account (`labuser` on the cell), so
# the workspace lives in that account's home -- but labuser has no sudo, and
# almost every phase here needs it. So the person who runs this script is a
# NAMED account with sudo, operating on a tree that another account owns and
# that the whole `labusers` group has to be able to rewrite tomorrow.
#
# The group half of that is already arranged on the cell: the directories carry
# the setgid bit, so anything created inside them inherits the group. What
# setgid DOES NOT do is make the file group-WRITABLE -- that comes from the
# creating process's umask, and the default 022 produces
#
#     -rw-r--r--  lesthatj labusers   package.dsv
#
# which the next person in the group cannot write, truncate or chmod. Only the
# owner can chmod a file, so nothing short of root repairs it afterwards. That
# is the whole of the "setgid causes its own set of issues" problem, and it is
# what the first cell run died of: ros_ws/build and ros_ws/install were full of
# another account's 0644 files, and the build came apart into two hundred lines
# of
#
#     CMake Error ... (configure_file): Operation not permitted
#     PermissionError: [Errno 13] ... install/csf_loader_msgs/.../package.dsv
#
# none of which says "someone else owns this file". 0002 is therefore not a
# preference: with setgid directories it is the other half of the mechanism,
# and without it the sticky group buys nothing at all. It costs nothing on a
# single-user machine, where the primary group is the user's own.
#
# TARI_UMASK overrides, for a machine that really does want 022.
# ---------------------------------------------------------------------------
umask "${TARI_UMASK:-0002}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$ROOT/ros_ws"
ROSDISTRO="${ROSDISTRO:-iron}"

LAYER=""
ONLY_PHASE=""
WITH_SOFA=0
WITH_TEST_DATA=0
DRYRUN=0
DO_CHECK_REMOTES=0
#: Bring every checkout to exactly what the manifest says, including moving a
#: remote and abandoning local commits. Off by default: the sources phase is
#: deliberately conservative, because several of these checkouts have work in
#: progress at any given time and silently resetting one would be the worst
#: thing this script could do.
RESYNC=0
#: ...and also throw away uncommitted changes. Separate from --resync on
#: purpose: a moved remote or a diverged branch is recoverable from the reflog,
#: and an uncommitted edit is not recoverable from anywhere.
DISCARD_LOCAL=0
#: Required in addition to --discard-local-changes before anything with REAL
#: content changes is reset. Cosmetic dirt -- line endings, a mode bit, a
#: submodule pointer -- does not need it; see classify_dirty.
ASSUME_YES=0

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

# ---------------------------------------------------------------------------
# `apt-get update` exits 0 with an index it failed to refresh.
#
# The cell machine carries a dozen third-party apt sources belonging to other
# projects, and one of them -- librealsense -- has an expired signing key:
#
#     W: GPG error: https://librealsense.intel.com/Debian/apt-repo jammy
#        InRelease: ... NO_PUBKEY FB0B24895113F120
#     W: Some index files failed to download. They have been ignored, or old
#        ones used instead.
#
# apt still exits 0, so `run "sudo apt-get update"` reports success, and the
# three lines that matter scroll past inside several hundred lines of progress
# bars. "old ones used instead" is the part worth catching: the next
# `apt-get install` then resolves against a stale index, and whatever that gets
# wrong surfaces as a missing package somewhere else entirely.
#
# Not repaired here. Importing somebody else's signing key, or disabling their
# repository, is a decision about a machine shared with other projects and is
# not this script's to make -- but a sourced failure is named once, with the
# command, instead of being left in the noise.
# ---------------------------------------------------------------------------
apt_update() {
    if [[ $DRYRUN -eq 1 ]]; then
        printf '    + %s\n' "sudo apt-get update"
        return 0
    fi
    local out rc=0
    out="$(sudo apt-get update 2>&1)" || rc=$?
    printf '%s\n' "$out"
    [[ $rc -eq 0 ]] || return $rc

    local failed keys
    failed="$(printf '%s\n' "$out" | grep -E '^(W|E): (Failed to fetch|The repository)' || true)"
    [[ -n "$failed" ]] || return 0
    warn "apt could not refresh every source, and used the OLD index for those:"
    printf '%s\n' "$failed" | sed 's/^/    /' >&2
    keys="$(printf '%s\n' "$out" | grep -oE 'NO_PUBKEY [0-9A-F]{8,}' | awk '{print $2}' | sort -u || true)"
    if [[ -n "$keys" ]]; then
        warn "A missing signing key is the cause. If that repository belongs to a"
        warn "project on this machine, import its key; if it belongs to none,"
        warn "remove its file from /etc/apt/sources.list.d. Keys seen:"
        printf '%s\n' "$keys" | sed 's/^/    /' >&2
    fi
    warn "Everything below resolves against a stale index for those sources."
    return 0
}

# 3,28 is the comment block above and nothing after it. It used to be 3,30,
# which ran two lines past the block and printed `set -euo pipefail` as part of
# --help.
usage() { sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; cat <<'EOF'

Options:
  --layer LAYER      container | sim | acq | hw | site   (required, unless
                     --check-remotes). Each includes the ones before it.
  --phase PHASE      run one phase only (see the list above)
  --with-sofa        also fetch the SOFA binary release (1.3 GB, soft robotics)
  --with-test-data   also clone the recorded scan fixtures the suites use
                     (~95 MB over git-lfs; without it those sections skip)
  --check-remotes    test that every manifest URL resolves, then exit
  --resync           force every checkout to exactly what the manifest says:
                     move a remote that points somewhere else, switch branch,
                     and hard-reset a branch that has diverged. REFUSES a
                     checkout with uncommitted changes. Discarded commits stay
                     in that repository's reflog, and their hashes are printed.
                     This is what to use after a manifest changes a repository's
                     url or version -- without it those are reported and left
                     alone, which is right for a development machine and wrong
                     for a cell that just needs to match.
  --discard-local-changes
                     with --resync, also throw away uncommitted changes
                     (reset --hard plus clean -fd; ignored files are kept).
                     Nothing recovers these. Implies --resync.
                     COSMETIC dirt -- CRLF line endings, a mode bit, a
                     submodule pointer -- is discarded on this flag alone and
                     named as cosmetic. A checkout with real content changes
                     additionally needs --yes, so a genuine edit cannot be
                     thrown away buried in two hundred line-ending diffs.
  --yes              do not stop for real content changes under
                     --discard-local-changes. Nothing recovers them.
  -n, --dry-run      print what would run; writes nothing, installs nothing
  -h, --help         this message

Environment:
  TARI_FETCH_ATTEMPTS   tries per repository before the sources phase gives up
                        on a transient network error (default 5)
  TARI_FETCH_BACKOFF    seconds before the second try, doubling thereafter
                        (default 5)
  TARI_COLCON_WORKERS   override the build phase's --parallel-workers, which
                        otherwise follows available RAM
  TARI_UMASK            umask for everything this script creates (default
                        0002, so the labusers group can rewrite it tomorrow)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --layer)         LAYER="${2:?--layer needs a value}"; shift ;;
        --phase)         ONLY_PHASE="${2:?--phase needs a value}"; shift ;;
        --with-sofa)     WITH_SOFA=1 ;;
        --with-test-data) WITH_TEST_DATA=1 ;;
        --check-remotes) DO_CHECK_REMOTES=1 ;;
        --resync)        RESYNC=1 ;;
        --discard-local-changes)
                         # Implies --resync: discarding edits in order to leave
                         # the checkout where it already was makes no sense.
                         DISCARD_LOCAL=1; RESYNC=1 ;;
        --yes)           ASSUME_YES=1 ;;
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
# The paths every manifest in the layer chain names, one per line. Used by the
# safe.directory export below and nowhere else yet; kept here rather than
# inside phase_sources because the ownership preamble runs before any phase.
# ---------------------------------------------------------------------------
layer_manifest_paths() {
    local l
    for l in $(layer_chain "$LAYER"); do
        [[ -f "$ROOT/$l.repos" ]] || continue
        manifest_entries "$ROOT/$l.repos" | cut -f1
    done
}

# ---------------------------------------------------------------------------
# git refuses to touch a repository somebody else owns.
#
#     fatal: detected dubious ownership in repository at
#            '/home/labuser/tari/dgpython-opencv-camera'
#
# which is CVE-2022-24765's fix doing its job: the workspace is in labuser's
# home and git is running as lesthatj, or (worse) as root under `sudo pip`.
# That is exactly how the first cell run lost its python phase -- two packages'
# setup.py call setuptools_scm, setuptools_scm shells out to git, git was root,
# and the build died with "git introspection failed" and
# `error: metadata-generation-failed`.
#
# The reflex is `sudo git config --global --add safe.directory "*"`, which is
# what was done on the cell and is the wrong shape of fix: it is permanent, it
# is machine-wide, it applies to root, and it says every repository on the box
# is trusted for ever in order to get past one bootstrap.
#
# GIT_CONFIG_COUNT/KEY/VALUE is the same setting scoped to this process tree.
# It writes nothing into anybody's ~/.gitconfig, it lists ONLY the checkouts
# this workspace's own manifests name, and it is gone when the script exits.
# (git >= 2.31 for the environment form; jammy carries 2.34.)
#
# An existing GIT_CONFIG_COUNT is respected rather than clobbered: the entries
# are appended after whatever the caller already set.
# ---------------------------------------------------------------------------
export_workspace_safe_directories() {
    local -a dirs=("$ROOT")
    local d i
    while IFS= read -r d; do
        [[ -n "$d" ]] && dirs+=("$ROOT/$d")
    done < <(layer_manifest_paths)

    i="${GIT_CONFIG_COUNT:-0}"
    [[ "$i" =~ ^[0-9]+$ ]] || i=0
    for d in "${dirs[@]}"; do
        export "GIT_CONFIG_KEY_$i=safe.directory"
        export "GIT_CONFIG_VALUE_$i=$d"
        i=$(( i + 1 ))
    done
    export GIT_CONFIG_COUNT="$i"
    # The sudo'd steps are a separate problem: sudo runs with env_reset and
    # drops all of these. dgpy_install.sh re-adds them for the package it is
    # installing; see git_safe_env_for there.
}

# ---------------------------------------------------------------------------
# Somebody else's 0644 files in ros_ws/build and ros_ws/install.
#
# This is the failure the umask note at the top of the file describes, seen
# from the other end: the artefacts are already there, already owned by another
# account, and already not group-writable, so no umask fixes them now. What a
# build does with them is unreadable --
#
#     CMake Error at .../CMakePackageConfigHelpers.cmake:344 (configure_file):
#       Operation not permitted
#
# because cmake writes the file and then copies its timestamps, and utime() on
# a file you do not own is EPERM rather than EACCES. Seven packages failed and
# seventeen aborted behind them on the first cell run, and not one line of the
# output named ownership.
#
# So ask the question directly, before the build phase spends four minutes
# arriving at it: is there anything under build/ or install/ that this account
# cannot write? `find -writable` tests access(W_OK), which is false both for a
# foreign-owned 0644 file and for a mode-0444 one, and -print -quit stops at
# the first hit so the check costs nothing on a healthy tree.
#
# Reported with the remedy and then fatal, rather than repaired: the choice
# between "delete the artefacts" and "chgrp the artefacts" is the operator's,
# and the second one needs a privilege this function cannot assume it has.
# ---------------------------------------------------------------------------
assert_workspace_artefacts_writable() {
    local d hit
    for d in "$WS/build" "$WS/install" "$WS/log"; do
        [[ -d "$d" ]] || continue
        # Regular files and directories only. -writable calls access(), which
        # FOLLOWS a symlink, so a dangling one answers "not writable" -- and
        # --symlink-install fills these trees with symlinks, several of which
        # point at a container path that does not exist on the host. -type
        # uses lstat, so naming the two types skips every link. (Measured on
        # lablinux: without this the check fired on
        # build/keyence_interfaces/.../keyence_interfaces -> /home/user/...)
        hit="$(find "$d" \( -type f -o -type d \) ! -writable -print -quit 2>/dev/null || true)"
        [[ -n "$hit" ]] || continue
        warn "$d holds files this account cannot write. The first one is:"
        warn "    $(ls -ld "$hit" 2>/dev/null || echo "$hit")"
        warn "On a shared workspace that is the setgid bit without the umask:"
        warn "another account built here with umask 022, so its files are 0644"
        warn "and only their owner can chmod them. colcon reports this as"
        warn "'Operation not permitted' from configure_file and as a"
        warn "PermissionError on package.dsv, naming neither ownership nor the"
        warn "account. Pick one:"
        warn "    rm -rf '$WS/build' '$WS/install' '$WS/log'   # a clean rebuild"
        warn "    sudo chgrp -R labusers '$WS' && sudo chmod -R g+rwX '$WS'"
        # fatal_unless_dry dies outside --dry-run, so reaching the next line at
        # all means this is a dry run, whose whole purpose is to describe a
        # machine that is not set up yet. Returning non-zero here would make
        # `--dry-run` exit 1 under `set -e` and print none of the rest.
        fatal_unless_dry "ros_ws artefacts are not writable by $(id -un) (see above)"
        return 0
    done
    return 0
}

# ---------------------------------------------------------------------------
# THE POLICY, checked rather than assumed, and only where it applies.
#
# A workspace driven by several named accounts needs all three of:
#
#   1. one group everybody is in                     (labusers)
#   2. setgid on the directories, so new files inherit it
#   3. a umask that leaves group write on            (0002, set at the top)
#
# Two out of three is the state the cell was in, and it looks like it is
# working right up to the moment a second person builds. So say so -- but only
# on a workspace that is actually shared, which is what more than one owner
# among its top-level entries means. On a single-user machine, where the
# primary group is the user's own, none of this is a finding and the function
# is silent.
#
# A warning, not fatal: arranging a group is an administrative act, the script
# cannot do it without privileges it should not assume, and a workspace that is
# merely awkward still builds for whoever owns it.
# ---------------------------------------------------------------------------
warn_about_shared_workspace_policy() {
    local owners
    owners="$( { find "$ROOT" -maxdepth 1 -mindepth 1 -printf '%u\n'
                 [[ -d "$WS/src" ]] && find "$WS/src" -maxdepth 1 -mindepth 1 -printf '%u\n'
                 true; } 2>/dev/null | sort -u | tr '\n' ' ' || true)"
    # One owner: not shared, nothing to say. Two or more means two people have
    # already written here, and then the mode bits decide whether a third can.
    [[ "$(wc -w <<<"$owners")" -ge 2 ]] || return 0

    local mode group
    mode="$(stat -c '%a' "$ROOT" 2>/dev/null || echo '')"
    group="$(stat -c '%G' "$ROOT" 2>/dev/null || echo '?')"
    note "shared workspace: owners are $owners(group $group)"
    local -a complaints=()
    [[ "${#mode}" -eq 4 && "${mode:0:1}" =~ [2367] ]] \
        || complaints+=("the setgid bit is not set, so a new file does not inherit group $group")
    [[ "${mode: -2:1}" =~ [2367] ]] \
        || complaints+=("the group cannot write it (mode $mode)")
    [[ ${#complaints[@]} -gt 0 ]] || return 0

    warn "This workspace is written by more than one account ($owners)"
    warn "and its shared-access arrangement is incomplete:"
    local c
    for c in "${complaints[@]}"; do warn "    $c"; done
    warn "Everything this script creates is group-writable (umask $(umask)),"
    warn "but that only helps where the group is right. Arrange it once:"
    warn "    sudo chgrp -R labusers '$ROOT'"
    warn "    sudo find '$ROOT' -type d -exec chmod g+rwxs {} +"
    warn "    sudo find '$ROOT' -type f -exec chmod g+rw {} +"
    warn "and have every account that drives this set 'umask 0002' in its own"
    warn "shell startup file, or the next 022 build recreates the problem."
    return 0
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
    apt_update
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
    apt_update
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
# Three of bpy's four declared dependencies, from apt so pip does not choose
# them. The fourth, zstandard, IS NOT AN UBUNTU 22.04 PACKAGE under that name --
# `apt-cache policy python3-zstandard` finds nothing and apt fails the whole
# install line with "E: Unable to locate package python3-zstandard", which takes
# the prereqs phase down with it. python3-zstd is a DIFFERENT binding (module
# `zstd`, not `zstandard`), so it does not satisfy the dependency. install_bpy
# pip-installs it; see the note there.
cython3
python3-numpy
python3-requests
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
# bpy IS AVAILABLE, BUT NOT FROM PyPI. tari_mesh_filter_srv and x3d_converter do
# `import bpy` at the top and die without it, and jammy's blender package ships no
# Python module at all (dpkg -L blender lists nothing named bpy). A plain
# `pip install bpy` also fails, which is what makes this look impossible. Blender
# publish their own index:
#
#     --extra-index-url https://download.blender.org/pypi/
#
# which serves bpy-4.0.0-cp310-cp310-manylinux_2_28_x86_64.whl. Two things follow.
# It is a 390 MB wheel that unpacks to 1.3 GB, so it is installed only from the sim
# layer up, where those
# two nodes live. And it declares `Requires-Python: ==3.10.*`, exactly -- so it
# resolves on jammy and on nothing newer; a machine on a later Python needs
# Blender's own interpreter instead.
#
# THREE of its four dependencies come from apt, not from pip: --no-deps is the
# rule here, and letting pip resolve cython, numpy and requests would put versions
# nobody chose ahead of the apt copies on sys.path for every project on the
# machine.
#
# The fourth, `zstandard`, has no Ubuntu 22.04 package. `python3-zstandard` does
# not exist -- naming it in the apt list fails the entire install line with
#
#     E: Unable to locate package python3-zstandard
#
# and takes the prereqs phase with it. `python3-zstd` is NOT a substitute: it is
# a different binding providing the module `zstd`. So this one is pip'd, --no-deps
# like the rest, next to bpy itself.
#
# It is a soft dependency in practice: only bpy's `blend_render_info` imports it,
# to read a zstd-compressed .blend header, and it does so lazily. `import bpy`,
# the mesh API and `bpy.ops.uv.smart_project` all work without it -- measured on
# jammy 2026-09-30 -- so its absence is a warning, not a failure.
#
# ONE IS STILL NOT HERE:
#
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

#: Blender's own package index. bpy is not on PyPI; see the note above.
BPY_INDEX="https://download.blender.org/pypi/"

# zstandard, the one bpy dependency apt cannot supply. Separate from install_bpy
# on purpose, and called even when bpy is already there: a machine bootstrapped
# before this existed has bpy and not this, and an early return inside
# install_bpy would never top it up.
install_bpy_zstandard() {
    python3 -c 'import zstandard' 2>/dev/null && return 0
    note "zstandard -- no Ubuntu package under that name, and python3-zstd is a"
    note "different binding (module 'zstd') that does not satisfy it"
    run "sudo python3 -m pip install --no-deps zstandard" \
        || warn "zstandard did not install. Only bpy's blend_render_info imports
   it, lazily, to read a zstd-compressed .blend header; the mesh API and
   bpy.ops.uv.smart_project do not need it."
    return 0
}

install_bpy() {
    # Only from the sim layer up: the two nodes that import it are ROS nodes, and
    # the wheel is 390 MB and unpacks to 1.3 GB.
    layer_at_least sim || return 0
    if python3 -c 'import bpy' 2>/dev/null; then
        note "bpy already present"
        install_bpy_zstandard
        return 0
    fi
    say "bpy (Blender as a Python module)"
    note "390 MB wheel, 1.3 GB installed, from ${BPY_INDEX} -- it is not on PyPI"
    # Requires-Python is ==3.10.*, so say so before pip does: on anything else the
    # resolver reports only that no version matched, which reads as a network or
    # index fault rather than an interpreter one.
    local pyver
    pyver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
    if [[ "$pyver" != "3.10" ]]; then
        warn "bpy publishes CPython 3.10 wheels only and this is Python $pyver."
        warn "tari_mesh_filter_srv and x3d_converter will not run; they need"
        warn "Blender's own interpreter on this platform."
        return 0
    fi
    run "sudo python3 -m pip install --no-deps --extra-index-url '$BPY_INDEX' bpy"
    install_bpy_zstandard
    if [[ $DRYRUN -eq 0 ]] && ! python3 -c 'import bpy' 2>/dev/null; then
        warn "bpy installed but does not import; tari_mesh_filter_srv and"
        warn "x3d_converter will fail. Check its apt dependencies above."
    fi
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
# pkg_resources, and the setuptools version that decides whether it exists.
#
# ONE BROKEN THING, FOUR SYMPTOMS, none of which names it. A system-wide
# `pip install -U setuptools` resolves to something at or above 80, writes it
# into /usr/local/lib/python3.10/dist-packages ahead of apt's 59.6.0 on
# sys.path, and from that moment this distribution's own tooling is broken:
#
#   * /usr/bin/vcs is `from pkg_resources import load_entry_point`, so
#         ModuleNotFoundError: No module named 'pkg_resources'
#   * apt's pbr (reached through a setuptools entry point) imports
#     pkg_resources too, so EVERY package build fails metadata generation --
#     measured on marvin 2026-09-30, five packages in one run:
#         error: failed: spatialnde2 dataguzzler-python dgpython_param_manager
#                dgpython-local spatialnde2_ec_functions
#   * `setup.py develop --uninstall` is gone above 80, and that is what colcon
#     runs for an ament_python package under --symlink-install, so the whole
#     Python half of ros_ws fails with
#         error: option --uninstall not recognized
#     and everything downstream of those packages aborts.
#   * apt's colcon-core declares `setuptools<80,>=30.3.0` outright, and pip
#     says so inside the very command that installs the offending version.
#
# Checked HERE, in the first phase, because every one of those symptoms shows
# up in a later phase a long way from its cause. dgpy_install.sh holds the same
# ceiling for the install it does itself; see SETUPTOOLS_CEILING there.
#
# dpkg can also report python3-pkg-resources installed while all 17 of its
# files are gone from disk -- seen on a machine where another project had run
# `sudo pip3 install setuptools --break-system-packages`. Reinstalling that one
# package restores them, removes nothing, and leaves /usr/local alone.
# ---------------------------------------------------------------------------
SETUPTOOLS_CEILING=80          # exclusive; must match dgpy_install.sh

ensure_working_vcs() {
    # 1. pkg_resources has to import. That is the module every symptom above
    #    actually fails on, so probe it directly rather than through whichever
    #    tool happens to notice first.
    if ! python3 -c 'import pkg_resources' 2>/dev/null; then
        warn "pkg_resources does not import. vcstool, colcon and every package"
        warn "build here go through it; restoring python3-pkg-resources"
        note "(same version, nothing removed, /usr/local left alone)"
        run "sudo apt-get install -y --reinstall python3-pkg-resources"
        if ! python3 -c 'import pkg_resources' 2>/dev/null; then
            warn "pkg_resources STILL does not import, so something on this"
            warn "machine has a setuptools without it ahead of apt's on"
            warn "sys.path. See the setuptools note below."
        fi
    fi

    # 2. setuptools has to be below the ceiling -- and the WHERE matters as much
    #    as the version, which is what the first cell run proved.
    #
    #    That machine carried setuptools 84.0.0 in
    #    /home/lesthatj/.local/lib/python3.10/site-packages: the invoking
    #    human's per-user site directory. The python phase duly ran
    #    `sudo pip install 'setuptools>=64,<80'`, which writes
    #    /usr/local/lib/python3.10/dist-packages -- and the user site precedes
    #    that on sys.path, so the pin could not take effect and never did. The
    #    warning fired again on the next invocation, and the colcon build that
    #    followed still loaded setuptools out of ~/.local (visible in its own
    #    stderr: ".local/lib/python3.10/site-packages/setuptools/_distutils").
    #    So the old text, "The python phase pins it back", was a claim the run
    #    disproved.
    #
    #    On a shared machine this is worse than one stale install: the version
    #    that wins depends on WHICH HUMAN ran the script, so the same workspace
    #    builds for one account and not for another, and `sudo pip` cannot
    #    reach either copy. Report the location and print the command that
    #    matches it.
    local ver major loc
    read -r ver loc <<<"$(python3 - <<'PYEOF' 2>/dev/null || true
import os
from importlib.metadata import distribution
d = distribution("setuptools")
print(d.version, os.path.realpath(str(d.locate_file(""))))
PYEOF
)"
    major="${ver%%.*}"
    if [[ -n "$major" && "$major" =~ ^[0-9]+$ && "$major" -ge $SETUPTOOLS_CEILING ]]; then
        warn "setuptools $ver is installed, and $SETUPTOOLS_CEILING or newer breaks this"
        warn "distribution's colcon (no 'setup.py develop --uninstall', so every"
        warn "ament_python package fails to build under --symlink-install) and"
        warn "everything that imports pkg_resources."
        warn "    it is at: ${loc:-unknown}"
        case "${loc:-}" in
            "$HOME"/*)
                warn "That is YOUR OWN per-user site directory, which precedes every"
                warn "system directory on sys.path -- so the python phase's"
                warn "'sudo pip install' CANNOT displace it and will not try."
                warn "Remove it, as yourself and WITHOUT sudo:"
                warn "    python3 -m pip uninstall -y setuptools"
                warn "    python3 -c 'import setuptools; print(setuptools.__file__)'"
                warn "On a shared machine do this for every account that runs builds:"
                warn "whichever ~/.local wins is whoever is logged in."
                ;;
            *)
                warn "The python phase pins it back below $SETUPTOOLS_CEILING. On a sim-layer"
                warn "machine, which never runs that phase, do it by hand:"
                warn "    sudo python3 -m pip install 'setuptools>=64,<$SETUPTOOLS_CEILING'"
                ;;
        esac
    fi

    # 3. Only then is it worth asking about vcs itself. The sources phase no
    #    longer uses it -- see the comment above sync_one_repo for why -- but
    #    the manifests document `vcs import < sim.repos` for use by hand, so a
    #    broken /usr/bin/vcs is still a finding.
    if command -v vcs >/dev/null && ! vcs --version >/dev/null 2>&1; then
        warn "vcs is installed but does not run:"
        vcs --version 2>&1 | sed 's/^/    /' >&2 || true
        warn "The sources phase does not need it -- it fetches with git"
        warn "directly -- so this does not block a bootstrap."
    fi

    # 4. pytest has to import, for a reason that is nothing to do with running
    #    the suites here.
    #
    #    python3-pytest is in the apt list above, and the first cell run
    #    installed it -- and the build that followed still said, eleven times,
    #
    #        CMake Warning at .../ament_add_pytest_test.cmake:82 (message):
    #          The Python module 'pytest' was not found, pytests cannot be run.
    #          On Linux, install the 'python3-pytest' package.
    #
    #    on a machine where that package was already the newest version.
    #    ament_cmake_pytest probes the interpreter cmake found, so this is a
    #    statement about THAT interpreter's sys.path, and that machine had a
    #    private ~/.local ahead of the system directories (see the setuptools
    #    note above, same directory, same account).
    #
    #    The consequence is quiet and bad: those eleven packages configure with
    #    no tests registered at all, so `colcon test` afterwards passes having
    #    run nothing. The advice apt's own message gives -- install
    #    python3-pytest -- is already done, which is exactly why it has to be
    #    said differently here.
    if ! python3 -c 'import pytest' 2>/dev/null; then
        warn "pytest does not import for $(command -v python3):"
        python3 -c 'import pytest' 2>&1 | tail -3 | sed 's/^/    /' >&2 || true
        warn "python3-pytest is installed by this phase, so this is about what"
        warn "is ahead of it on sys.path rather than about a missing package."
        warn "Every ament package then configures with NO tests registered --"
        warn "'The Python module pytest was not found' -- and a later"
        warn "'colcon test' passes having run nothing. Check whose copy wins:"
        warn "    python3 -c 'import sys; print(sys.path)'"
        warn "    ls ~/.local/lib/python3.*/site-packages"
    fi
    return 0
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
    apt_update
    run "sudo apt-get install -y --no-remove ${pkgs[*]}"
    ensure_working_vcs
    install_pip_prereqs
    install_bpy
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
    # Comments and blank lines are stripped, so the list above can be annotated.
    # Without this a `# note` line becomes an apt argument and the install fails
    # on a package named '#'.
    run "sudo apt-get install -y --no-remove $(ros_apt_packages \
         | sed -e 's/#.*//' -e '/^[[:space:]]*$/d' | tr '\n' ' ')"
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
    warn_about_dangling_rosdep_sources
    run "rosdep update --rosdistro $ROSDISTRO"

    # The Azure Kinect SDK is deliberately NOT installed here; see
    # check_vendor_sdks for why, and for the exact commands. Report it early
    # rather than at the end of a long build.
    if layer_at_least hw && ! have_shared_lib libk4a; then
        warn "the Azure Kinect SDK is not installed; --layer hw will stop at the"
        warn "rosdep phase and print the commands. It is a manual step on purpose."
    fi
}

# ---------------------------------------------------------------------------
# `rosdep update`'s six-line ERROR that is not a fault.
#
# Every prereqs run in the clean-machine logs ends the rosdep step with this,
# four times out of four:
#
#     ERROR: unable to process source [file:///usr/share/python3-rosdep2/debian.yaml]:
#         <urlopen error [Errno 2] No such file or directory:
#         '/usr/share/python3-rosdep2/debian.yaml'>
#         (file:///usr/share/python3-rosdep2/debian.yaml)
#     ...
#     ERROR: Not all sources were able to be updated.
#
# It is Debian's own rosdep package, python3-rosdep2, which ships BOTH
# /etc/ros/rosdep/sources.list.d/30-debian.list and the yaml that list points
# at. Remove the package without purging its conffile and the pointer outlives
# its target, so rosdep reports an unreachable source for ever. rosdep still
# exits 0 and its other sources update normally -- measured in all four runs --
# so this never stopped anything. It just looks exactly like the thing that
# would.
#
# Reported rather than repaired: the file is a dpkg conffile, and deleting one
# behind dpkg's back makes the next upgrade of that package ask a question
# nobody will understand. Naming it in one line is the whole fix.
# ---------------------------------------------------------------------------
warn_about_dangling_rosdep_sources() {
    local dir=/etc/ros/rosdep/sources.list.d
    [[ -d "$dir" ]] || return 0
    local listfile target found=0
    for listfile in "$dir"/*.list; do
        [[ -f "$listfile" ]] || continue
        while read -r _kind url _rest; do
            [[ "${url:-}" == file://* ]] || continue
            target="${url#file://}"
            [[ -e "$target" ]] && continue
            if [[ $found -eq 0 ]]; then
                warn "rosdep is configured with a local source whose file does not exist."
                warn "'rosdep update' will print several ERROR lines about it and then"
                warn "carry on; it still exits 0 and every other source updates. This is"
                warn "what a half-removed python3-rosdep2 leaves behind. To silence it:"
                found=1
            fi
            warn "    sudo rm $listfile    # points at the missing $target"
        done < <(grep -v '^[[:space:]]*#' "$listfile" 2>/dev/null || true)
    done
    return 0
}

# ---------------------------------------------------------------------------
# Fetching the sources: THIS PHASE DOES NOT USE `vcs import`, and the reason is
# measured rather than stylistic.
#
# `vcs import` fans out over its repositories concurrently (10 workers by
# default) and github.com throttles concurrent SSH connections per source
# address. On marvin, 2026-09-30, importing hw.repos' nine repositories gave
# eight simultaneous failures -- the progress line was `E.EEEEEEE`, one dot for
# the one HTTPS entry -- every one of them:
#
#     Could not clone repository
#     'git@github.com:isuthermography/dgpython-azurekinect_staging.git':
#     Cloning into '.'...
#     kex_exchange_identification: read: Connection reset by peer
#     Connection reset by 140.82.112.3 port 22
#     fatal: Could not read from remote repository.
#
#     Please make sure you have the correct access rights
#     and the repository exists.
#
# followed by `error: hw.repos did not import cleanly (see above)`. The last
# line of that message is why this is worth so much comment: it reads as a
# credential or a typo, and it is neither -- the same key cloned the same
# repositories a minute later. Re-running did not help either, because every
# repository was attempted again at the same concurrency and throttled again,
# and because the four dgpython modules had been left as EMPTY DIRECTORIES,
# which the python phase then reported as
#
#     ERROR: Directory '.' is not installable. Neither 'setup.py' nor
#     'pyproject.toml' found.
#
# So: one repository at a time, retry the failures that are transient, and make
# a re-run cost nothing for everything that already succeeded.
#
# THE SECOND REASON is `vcs import`'s behaviour on a checkout that already
# exists: it does not fast-forward an existing branch. A repository cloned last
# month at `iron` stays at last month's commit and `vcs import` reports success,
# so a stale tree is indistinguishable from a current one. Nothing here can
# detect that later -- the version in the manifest is a branch name, which
# matches whatever the branch pointed at whenever it was cloned. The loop below
# fetches and fast-forwards explicitly, and says which of the two happened.
#
# Deliberately NOT done: changing a remote URL, touching a dirty working tree,
# or resetting a branch that has diverged. Several of these checkouts carry
# work in progress. Each of those cases is reported and left exactly as it was.
# ---------------------------------------------------------------------------
# One attempt per transient failure, doubling the wait. Five attempts starting
# at 5 s spans about 75 s, which is longer than github's throttle window has
# been observed to last.
FETCH_ATTEMPTS="${TARI_FETCH_ATTEMPTS:-5}"
FETCH_BACKOFF="${TARI_FETCH_BACKOFF:-5}"

# Failures worth retrying: a refused or dropped connection, not a refused
# identity. `Permission denied (publickey)` and `Repository not found` are
# answers, and repeating the question does not change them -- retrying those
# would turn a clear credential error into a 75 s pause and then the same clear
# credential error.
#
# The definitive cases are tested FIRST, and that ordering is load-bearing:
# git's final line is `fatal: Could not read from remote repository.` for both
# kinds, and the throttled clone even ends with "Please make sure you have the
# correct access rights and the repository exists." So the decision has to be
# made on the SPECIFIC line -- kex_exchange_identification / Connection reset
# on one side, Permission denied / Repository not found on the other -- and
# never on the summary line, which says the same thing either way.
fetch_error_is_transient() {
    local text="$1"
    # Answers. Not retried, whatever else is in the output.
    case "$text" in
        *"Permission denied"*)                        return 1 ;;
        *"Repository not found"*)                     return 1 ;;
        *"Host key verification failed"*)             return 1 ;;
        *"could not read Username"*)                  return 1 ;;
        *"terminal prompts disabled"*)                return 1 ;;
        *"Invalid username or password"*)             return 1 ;;
    esac
    # Dropped or refused connections.
    case "$text" in
        *kex_exchange_identification*|*ssh_exchange_identification*) return 0 ;;
        *"Connection reset by"*|*"Connection closed by"*)            return 0 ;;
        *"Connection timed out"*|*"Operation timed out"*)             return 0 ;;
        *"Connection refused"*)                                       return 0 ;;
        *"The remote end hung up unexpectedly"*|*"early EOF"*)        return 0 ;;
        *"RPC failed"*|*"HTTP 429"*|*"rate limit"*)                   return 0 ;;
        *"Temporary failure in name resolution"*)                     return 0 ;;
    esac
    return 1
}

# Run a git command, retrying transient network failures. Output is captured so
# it can be classified, and printed either way -- indented, so a failure that
# is going to be retried does not look like the end of the story.
git_with_retry() {
    local what="$1"; shift
    local attempt=1 delay="$FETCH_BACKOFF" out rc
    while :; do
        rc=0
        out="$("$@" 2>&1)" || rc=$?
        if [[ $rc -eq 0 ]]; then
            [[ -n "$out" ]] && printf '        %s\n' "$out"
            return 0
        fi
        printf '        %s\n' "$out" >&2
        if [[ $attempt -ge $FETCH_ATTEMPTS ]] || ! fetch_error_is_transient "$out"; then
            return "$rc"
        fi
        warn "$what: attempt $attempt of $FETCH_ATTEMPTS failed on a transient"
        warn "network error; waiting ${delay}s and trying again"
        sleep "$delay"
        attempt=$(( attempt + 1 ))
        delay=$(( delay * 2 ))
    done
}

# A manifest edited on Windows, or copied through an SFTP client in text mode,
# arrives with CRLF line endings and possibly a byte-order mark. PyYAML copes
# with both -- \r\n is a YAML line break and the BOM is consumed by the reader,
# measured against 22.04's python3-yaml 5.4.1 -- so neither corrupts the
# parse. What WOULD survive is a stray \r inside a scalar, which would then be
# appended to a branch name or a URL and produce a `no such version 'iron'`
# that looks nothing like a line-ending fault. One strip() per field closes
# that off and costs nothing.
manifest_entries() {
    python3 - "$1" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
for path, spec in (d.get("repositories") or {}).items():
    print("%s\t%s\t%s" % (path.strip(), str(spec["url"]).strip(),
                          str(spec["version"]).strip()))
PYEOF
}

# A manifest version is a branch, a tag OR a commit, which is why this cannot
# just be `git clone --branch` (that rejects a commit) or `git pull` (that is
# wrong for a tag and for a commit). True when the string can only be a commit.
version_is_a_commit() {
    [[ "$1" =~ ^[0-9a-f]{7,40}$ ]]
}

# FETCH_* counters, so the phase can print one honest summary line.
FETCH_CLONED=0
FETCH_FORWARDED=0
FETCH_CURRENT=0
FETCH_LEFT_ALONE=0
FETCH_RESYNCED=0

# ---------------------------------------------------------------------------
# WHAT KIND OF DIRTY: 224 line-ending diffs that look exactly like work.
#
# The first cell run warned that eleven checkouts under ros_ws/src had
# uncommitted changes, printed 224 `M <file>` lines, and offered
# --discard-local-changes as the way forward. Every one of those 224 paths ends
# in `.py`, across eleven unrelated repositories -- tari_ros, yolo_ros,
# moveit_task_constructor, industrial_reconstruction, csf_loader and the rest,
# including generated files nobody edits like test_copyright.py and
# test_pep257.py -- and not one .xml, .yaml, .xacro or .cmake among them.
# That is not eleven people's work in progress. It is a mechanical rewrite of
# one file type, which is what an SFTP client in automatic/text transfer mode
# does: its text-extension list decides what gets CRLF, and `.py` is on it
# while `.xacro` is not. These trees reach the cell by hand copy from a Windows
# workstation (see the deployment note), so that is the route.
#
# A CRLF working tree against an LF index reports every text file modified, and
# `git diff` reports it as every line changed:
#
#     $ git diff HEAD --numstat                 2  2  a.py
#     $ git diff HEAD --ignore-cr-at-eol --numstat   (nothing)
#
# -- measured, both forms, on a scratch repository. So the discriminator is
# exactly `--ignore-cr-at-eol --numstat`: a file that disappears from it, or
# that survives with 0 insertions and 0 deletions, differs only in its line
# endings or its mode bit. A real edit keeps a nonzero count.
#
# Why this matters more than tidiness: the operator could not tell 224
# line-ending diffs from two real edits, so --discard-local-changes was the
# only way past the warning and it threw away both kinds. Separating them means
# the cosmetic 224 can go without a decision, and a real edit stops the run.
#
# Prints one word: clean, eol (cosmetic only), submodule (only a submodule
# pointer differs) or dirty (real content changes, or untracked files, which
# `clean -fd` would delete).
# ---------------------------------------------------------------------------
classify_dirty() {
    local dest="$1"
    local porcelain real untracked

    porcelain="$(git -C "$dest" status --porcelain 2>/dev/null || true)"
    [[ -n "$porcelain" ]] || { echo clean; return 0; }

    # Untracked files are not cosmetic: clean -fd deletes them, and nothing
    # about a line ending creates a file that is not in the index.
    untracked="$(printf '%s\n' "$porcelain" | grep -c '^??' || true)"
    if [[ "${untracked:-0}" -gt 0 ]]; then echo dirty; return 0; fi

    # A submodule whose HEAD is not the recorded commit. reset --hard does not
    # recurse into one, so this is the state that re-reports itself as
    # "uncommitted changes" on every single run for ever -- which is what
    # moveit_task_constructor's core/python/pybind11 did, twice in one log,
    # including immediately after being "discarded".
    if [[ -f "$dest/.gitmodules" ]] \
       && [[ -z "$(git -C "$dest" status --porcelain --ignore-submodules=all 2>/dev/null || true)" ]]; then
        echo submodule; return 0
    fi

    real="$(git -C "$dest" diff HEAD --ignore-cr-at-eol --numstat 2>/dev/null \
            | awk '$1 != 0 || $2 != 0' || true)"
    if [[ -z "$real" ]]; then echo eol; return 0; fi
    echo dirty
}

# The real content changes in a dirty checkout, as `<added>/<removed> <path>`.
# Printed instead of `status --porcelain` so the two real edits are not buried
# in the line-ending noise next to them.
real_changes_in() {
    git -C "$1" diff HEAD --ignore-cr-at-eol --numstat 2>/dev/null \
        | awk '$1 != 0 || $2 != 0 { printf "+%s/-%s  %s\n", $1, $2, $3 }' || true
}

# Hard-reset a checkout onto the manifest's version, saying what that costs.
#
# Only ever called under --resync. The point of printing the hashes is that a
# discarded commit is not gone: it stays reachable through that repository's
# reflog for ninety days, so `git -C <path> reflog` or a cherry-pick by hash
# gets it back. A resync that printed nothing would make local work look as
# though it had never existed.
resync_hard() {
    local dest="$1" path="$2" target_sha="$3" version="$4" upstream="$5"
    local extra
    extra="$(git -C "$dest" log --oneline "$upstream..HEAD" 2>/dev/null || true)"
    if [[ -n "$extra" ]]; then
        warn "$path: DISCARDING $(printf '%s\n' "$extra" | wc -l | tr -d ' ') local commit(s)"
        warn "to reach $version. Recoverable with: git -C $path reflog"
        printf '%s\n' "$extra" | sed 's/^/     /' >&2
    fi
    if ! git -C "$dest" reset --hard --quiet "$target_sha" 2>/dev/null; then
        warn "$path: could not reset to ${target_sha:0:12}"
        return 1
    fi
    note "$path force-resynced to ${target_sha:0:12} ($version)"
    FETCH_RESYNCED=$(( FETCH_RESYNCED + 1 ))
    return 0
}

sync_one_repo() {
    local path="$1" url="$2" version="$3"
    local dest="$ROOT/$path" head target remote

    if [[ $DRYRUN -eq 1 ]]; then
        if [[ ! -d "$dest/.git" ]]; then
            note "+ clone $url -> $path at $version"
        elif version_is_a_commit "$version" \
             && [[ "$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)" == "$version"* ]]; then
            # The case that makes a re-run cheap. Say so in the plan too, or a
            # dry run describes 26 network operations where the real run does
            # a handful.
            note "+ nothing: $path is already at the pinned $version"
        else
            note "+ fetch and fast-forward $path to $version"
        fi
        return 0
    fi

    # A directory with no .git in it is what a failed clone leaves behind. An
    # empty one is debris and is removed; anything else might be somebody's
    # work and is not this script's to delete.
    if [[ -e "$dest" && ! -d "$dest/.git" ]]; then
        if [[ -d "$dest" ]] && rmdir "$dest" 2>/dev/null; then
            note "$path: removed the empty directory a failed clone left behind"
        else
            warn "$path exists and is not a git checkout. Left alone -- move it"
            warn "aside and run this phase again."
            FETCH_LEFT_ALONE=$(( FETCH_LEFT_ALONE + 1 ))
            return 1
        fi
    fi

    # ---- not there yet: clone -------------------------------------------
    # Into a temporary sibling, then move. A clone interrupted partway leaves
    # nothing at the real path, so "the directory exists" and "the repository
    # was fetched" stay the same statement and a re-run resumes cleanly.
    if [[ ! -d "$dest/.git" ]]; then
        local staging="$dest.tari-incoming"
        rm -rf "$staging"
        mkdir -p "$(dirname "$dest")"
        if ! git_with_retry "$path" git clone --quiet "$url" "$staging"; then
            rm -rf "$staging"
            warn "clone failed: $path ($url)"
            return 1
        fi
        if ! git_with_retry "$path" git -C "$staging" checkout --quiet "$version"; then
            rm -rf "$staging"
            warn "no such version '$version' in $path"
            return 1
        fi
        mv "$staging" "$dest"
        note "$path cloned at $version"
        FETCH_CLONED=$(( FETCH_CLONED + 1 ))
        return 0
    fi

    # ---- already there: resume ------------------------------------------
    remote="$(git -C "$dest" remote get-url origin 2>/dev/null || true)"
    if [[ -n "$remote" && "$remote" != "$url" ]]; then
        if [[ $RESYNC -eq 0 ]]; then
            warn "$path has origin $remote, not the manifest's $url."
            warn "Left exactly as it is -- this script does not move a remote"
            warn "unless you ask. --resync moves it."
            FETCH_LEFT_ALONE=$(( FETCH_LEFT_ALONE + 1 ))
            return 0
        fi
        # THE CASE A MANIFEST CHANGE CREATES. When a third-party repository
        # acquires a local patch it moves to our own fork, and every existing
        # checkout is then pointing at the upstream it came from -- which is
        # exactly the situation where "report and leave alone" means the cell
        # quietly keeps running unpatched code.
        note "$path: origin $remote -> $url"
        if ! git -C "$dest" remote set-url origin "$url"; then
            warn "$path: could not move origin to $url"
            return 1
        fi
    fi

    head="$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)"

    # A pinned commit cannot move, so a checkout already sitting on it needs no
    # network at all. This is most of the workspace on a re-run, and it is what
    # makes a resumed fetch cheap rather than merely correct.
    if version_is_a_commit "$version" && [[ "$head" == "$version"* ]]; then
        note "$path at $version already"
        FETCH_CURRENT=$(( FETCH_CURRENT + 1 ))
        return 0
    fi

    # Uncommitted work: report it and do not fetch over it. Several of these
    # checkouts have work in progress at any given time.
    #
    # --resync DOES NOT override this, and that is the one asymmetry in these
    # flags worth stating out loud: a moved remote and a discarded commit are
    # both recoverable -- the commit sits in the reflog for ninety days and its
    # hash is printed below -- while an uncommitted edit is recoverable from
    # nowhere at all. So it takes its own flag.
    #
    # ...but only REAL changes are irrecoverable, and most of what showed up
    # here was not real. classify_dirty separates the two; see the note above
    # it. Cosmetic dirt is cleared on --discard-local-changes alone and named
    # as cosmetic, so it cannot hide an edit that matters.
    local dirty
    dirty="$(classify_dirty "$dest")"
    if [[ "$dirty" != clean ]]; then
        if [[ $DISCARD_LOCAL -eq 0 ]]; then
            case "$dirty" in
                eol)
                    warn "$path differs from the index ONLY in line endings (and/or a"
                    warn "mode bit): every file is identical with --ignore-cr-at-eol."
                    warn "Not work in progress. This is a CRLF working tree -- a copy"
                    warn "through a Windows client in text mode, or a checkout made"
                    warn "under core.autocrlf=true. Fix the cause on this machine:"
                    warn "    git config --global core.autocrlf false"
                    warn "    git -C $path checkout-index -a -f   # rewrite with LF"
                    warn "or clear it here with --resync --discard-local-changes,"
                    warn "which treats line endings as disposable without --yes."
                    ;;
                submodule)
                    warn "$path has no file changes at all: only a submodule pointer"
                    warn "differs from the recorded commit. reset --hard does not"
                    warn "recurse into a submodule, so this state reports itself for"
                    warn "ever. Repair it with:"
                    warn "    git -C $path submodule update --init --recursive"
                    ;;
                *)
                    warn "$path has uncommitted changes; not fetching over them."
                    real_changes_in "$dest" | sed 's/^/     /' >&2 || true
                    if [[ $RESYNC -eq 1 ]]; then
                        warn "--resync does NOT discard these. Commit or stash them, or pass"
                        warn "--discard-local-changes --yes if they are genuinely disposable."
                    fi
                    ;;
            esac
            FETCH_LEFT_ALONE=$(( FETCH_LEFT_ALONE + 1 ))
            return 0
        fi
        # --discard-local-changes. Real content changes additionally need --yes:
        # the whole reason this guard exists is that 224 line-ending diffs made
        # a real edit invisible, and a flag that discards both kinds puts it
        # straight back.
        if [[ "$dirty" == dirty && $ASSUME_YES -eq 0 ]]; then
            warn "$path has REAL content changes, not just line endings:"
            real_changes_in "$dest" | sed 's/^/     /' >&2 || true
            warn "Refusing to discard these on --discard-local-changes alone."
            warn "Read them (git -C $path diff --ignore-cr-at-eol), then either"
            warn "commit/stash them or add --yes. Nothing recovers them."
            FETCH_LEFT_ALONE=$(( FETCH_LEFT_ALONE + 1 ))
            return 0
        fi
        case "$dirty" in
            eol)       warn "$path: discarding LINE-ENDING-ONLY differences" ;;
            submodule) warn "$path: restoring the recorded submodule pointer" ;;
            *)         warn "$path: DISCARDING real uncommitted changes --"
                       real_changes_in "$dest" | sed 's/^/     /' >&2 || true ;;
        esac
        # clean -fd, deliberately not -fdx: ignored files are build products and
        # generated version stamps, and removing those turns a source resync
        # into a rebuild of everything downstream.
        if ! git -C "$dest" reset --hard --quiet 2>/dev/null \
             || ! git -C "$dest" clean -fdq 2>/dev/null; then
            warn "$path: could not discard local changes"
            return 1
        fi
        # reset --hard leaves a submodule's own HEAD where it was, so without
        # this the checkout is still dirty the moment the reset finishes -- and
        # the next run says "DISCARDING uncommitted changes" about the same
        # pointer again. Advisory: a submodule that cannot be updated (no
        # network, no access) is not a reason to fail the fetch.
        if [[ -f "$dest/.gitmodules" ]]; then
            git -C "$dest" submodule update --init --recursive --quiet 2>/dev/null \
                || warn "$path: submodules did not update; the pointer stays dirty"
        fi
    fi

    if ! git_with_retry "$path" git -C "$dest" fetch --quiet --tags origin; then
        warn "fetch failed: $path"
        return 1
    fi

    # Resolve the manifest version against what was just fetched: a branch
    # first (as its remote-tracking ref, which is the thing that moved), then a
    # tag, then a bare commit.
    if git -C "$dest" rev-parse --verify --quiet "refs/remotes/origin/$version" >/dev/null; then
        target="refs/remotes/origin/$version"
    elif git -C "$dest" rev-parse --verify --quiet "refs/tags/$version" >/dev/null; then
        target="refs/tags/$version"
    elif git -C "$dest" rev-parse --verify --quiet "$version^{commit}" >/dev/null; then
        target="$version"
    else
        warn "no such version '$version' in $path after fetching"
        return 1
    fi

    local target_sha
    target_sha="$(git -C "$dest" rev-parse "$target^{commit}")"
    if [[ "$head" == "$target_sha" ]]; then
        note "$path at $version already"
        FETCH_CURRENT=$(( FETCH_CURRENT + 1 ))
        return 0
    fi

    # THE CASE `vcs import` DOES NOT HANDLE. On the branch the manifest names,
    # fast-forward it -- --ff-only rather than a reset, so a branch that has
    # diverged (a local commit, a rebase) refuses loudly instead of losing it.
    local branch
    branch="$(git -C "$dest" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ -n "$branch" && "$branch" == "$version" ]]; then
        if ! git -C "$dest" merge --ff-only --quiet "$target_sha" 2>/dev/null; then
            if [[ $RESYNC -eq 1 ]]; then
                resync_hard "$dest" "$path" "$target_sha" "$version" "$target_sha" || return 1
                return 0
            fi
            warn "$path is on '$branch' and cannot be fast-forwarded to"
            warn "${target_sha:0:12} -- it has diverged from origin. Left alone;"
            warn "reconcile it by hand (git -C $path log --oneline origin/$version..HEAD),"
            warn "or pass --resync to force it to the manifest."
            FETCH_LEFT_ALONE=$(( FETCH_LEFT_ALONE + 1 ))
            return 0
        fi
        note "$path fast-forwarded to ${target_sha:0:12} ($version)"
        FETCH_FORWARDED=$(( FETCH_FORWARDED + 1 ))
        return 0
    fi

    # Not on that branch: a tag, a pinned commit, or a detached HEAD left by an
    # earlier `vcs import`. Check the version out directly.
    if ! git -C "$dest" checkout --quiet "$version"; then
        if [[ $RESYNC -eq 1 ]]; then
            # A branch that does not exist locally yet -- the manifest moved a
            # repository onto a new branch name, which is what happens the
            # first time a third-party checkout becomes our fork.
            if git -C "$dest" checkout --quiet -B "$version" "$target_sha"; then
                note "$path force-resynced to ${target_sha:0:12} ($version, new local branch)"
                FETCH_RESYNCED=$(( FETCH_RESYNCED + 1 ))
                return 0
            fi
        fi
        warn "could not check out '$version' in $path"
        return 1
    fi
    # And then CONFIRM, because checking out a branch name does not have to
    # land on what was fetched: `git checkout iron` prefers an existing local
    # branch `iron`, which may be months behind origin/iron. Reporting
    # "checked out at $version" there would be exactly the stale-tree lie this
    # whole function exists to stop.
    head="$(git -C "$dest" rev-parse HEAD)"
    if [[ "$head" != "$target_sha" ]]; then
        if ! git -C "$dest" merge --ff-only --quiet "$target_sha" 2>/dev/null; then
            if [[ $RESYNC -eq 1 ]]; then
                resync_hard "$dest" "$path" "$target_sha" "$version" "$target_sha" || return 1
                return 0
            fi
            warn "$path: a local '$version' exists and cannot be fast-forwarded"
            warn "to ${target_sha:0:12}; it has diverged. It is checked out as it"
            warn "stands at ${head:0:12} -- reconcile it by hand, or pass --resync."
            FETCH_LEFT_ALONE=$(( FETCH_LEFT_ALONE + 1 ))
            return 0
        fi
    fi
    note "$path checked out at $version (${target_sha:0:12})"
    FETCH_FORWARDED=$(( FETCH_FORWARDED + 1 ))
    return 0
}

import_manifest() {
    local manifest="$1"
    local path url version rc=0
    [[ -f "$manifest" ]] || { warn "no such manifest: $manifest"; return 1; }
    while IFS=$'\t' read -r path url version; do
        [[ -n "$path" ]] || continue
        sync_one_repo "$path" "$url" "$version" || rc=1
    done < <(manifest_entries "$manifest")
    return $rc
}

phase_sources() {
    say "Sources"
    # Through run(), so --dry-run creates nothing. A dry run that makes
    # directories is a dry run you cannot use to inspect a shared machine.
    run "mkdir -p '$WS/src'"
    local rc=0
    for l in $(layer_chain "$LAYER"); do
        note "importing $l.repos"
        import_manifest "$ROOT/$l.repos" || rc=1
    done

    if [[ $DRYRUN -eq 0 ]]; then
        note "$FETCH_CLONED cloned, $FETCH_FORWARDED updated, $FETCH_CURRENT already current, $FETCH_RESYNCED force-resynced, $FETCH_LEFT_ALONE left alone"
        if [[ $FETCH_LEFT_ALONE -gt 0 && $RESYNC -eq 0 ]]; then
            warn "$FETCH_LEFT_ALONE repository/repositories were LEFT ALONE and did not"
            warn "update. Read the warnings above: a moved remote or a diverged branch"
            warn "is reported, never silently reconciled. --resync forces them to the"
            warn "manifest; --resync --discard-local-changes also drops line-ending and"
            warn "submodule-pointer dirt, and with --yes drops real edits as well."
        fi
    fi
    if [[ $rc -ne 0 ]]; then
        # Say that re-running is the recovery, because with `vcs import` it was
        # not: every repository was re-attempted and re-throttled. Now a repo
        # that cloned is skipped without touching the network at all.
        warn "some repositories did not fetch (see above). RUN THIS PHASE AGAIN:
   everything already cloned is skipped, so a re-run only retries what failed.
   If the failures were 'kex_exchange_identification' or 'Connection reset',
   that is github throttling connections and waiting a minute is the fix. If
   they were 'Permission denied (publickey)', the key is the problem and
   ./tari.bash --check-remotes will say which repositories it cannot read."
        fatal_unless_dry "sources did not import cleanly (see above)"
    fi

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
    workspace_env
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
#
# TWO SHAPES, and the second one has no metadata at all. `pip uninstall PyQt5`
# that was interrupted, or a `pip install` over an apt copy, leaves the
# PACKAGE DIRECTORY in /usr/local/lib/python3.10/dist-packages with its
# .dist-info gone. importlib.metadata then reports nothing while the directory
# still precedes apt's on sys.path, so the shadow is complete and invisible to
# a distribution scan. That is the one the servo operator hit on 2026-09-30:
#
#     ImportError: .../PyQt5/QtCore.abi3.so: undefined symbol: _ZdaPvm
#
# raised out of `import spatialnde2`, and the fix was by hand --
# `sudo rm -rf /usr/local/lib/python3.10/dist-packages/PyQt5*
# /usr/local/lib/python3.10/dist-packages/pyqt5_plugins*`. So look for the
# directories too, and print the removal command for each case, because
# `pip uninstall` cannot remove an orphaned directory it has no record of.
# ---------------------------------------------------------------------------
warn_about_pip_qt() {
    local found
    found="$(python3 - <<'PYEOF' 2>/dev/null
import os
import site
import sys
from importlib.metadata import distributions

INTERESTING = ("pyqt5", "pyqt6", "pyside2", "pyside6", "qtpy",
               "shiboken2", "shiboken6", "opencv-python")

# opencv-python is on that list and is NOT a Qt binding, which made the warning
# read as nonsense on the cell: the heading said "Qt Python bindings" and the
# only entry was opencv-python 4.11.0.86. It belongs here for a different
# reason -- the wheel bundles its own Qt plugins and its own libQt*.so, and it
# shadows apt's python3-opencv, which is the cv2 the rest of this stack was
# built against -- so say which reason applies to each entry instead of
# putting one heading over both.
def why(name):
    if name.lower().startswith("opencv-python"):
        return ("shadows apt's python3-opencv and bundles its own Qt plugins")
    return "a second Qt runtime and sip module ahead of the system one"

# /usr/lib/python3/dist-packages is where apt puts things -- that is the system
# Qt and it is the one we want. Everything else on sys.path shadows it.
def is_apt(path):
    return os.path.realpath(path).startswith("/usr/lib/python3/")

def interesting(name):
    return any(name.lower().startswith(k) for k in INTERESTING)

# Every top-level importable name that SOME installed distribution claims, per
# site directory. Built first, because it is what separates "pip installed
# this and can remove it" from an orphaned directory pip has no record of.
claimed = {}
for dist in distributions():
    location = os.path.realpath(str(dist.locate_file("")))
    names = claimed.setdefault(location, set())
    top = dist.read_text("top_level.txt")
    if top:
        names.update(line.strip() for line in top.splitlines() if line.strip())
    for f in (dist.files or []):
        parts = str(f).split("/")
        if parts and not parts[0].startswith(".."):
            names.add(parts[0].split(".")[0])

for dist in distributions():
    name = (dist.metadata["Name"] or "")
    if not interesting(name):
        continue
    location = os.path.realpath(str(dist.locate_file("")))
    if is_apt(location):
        continue
    print("%s %s (%s)\n        %s\n        remove with: sudo %s -m pip uninstall %s"
          % (name, dist.version, location, why(name), sys.executable, name))

# The orphans: a package directory with a Qt name that NO distribution claims.
# `pip uninstall` cannot touch one of these -- it has no record of it -- so the
# only honest instruction is the path to remove. Metadata directories
# (.dist-info, .egg-info) are not packages and are never reported here.
site_dirs = list(site.getsitepackages())
user_site = site.getusersitepackages()
if user_site:
    site_dirs.append(user_site)
for directory in dict.fromkeys(os.path.realpath(d) for d in site_dirs):
    if not os.path.isdir(directory) or is_apt(directory):
        continue
    owned = claimed.get(directory, set())
    for entry in sorted(os.listdir(directory)):
        if entry.endswith((".dist-info", ".egg-info", ".egg-link", ".pth")):
            continue
        if not interesting(entry) or entry in owned:
            continue
        path = os.path.join(directory, entry)
        if not os.path.isdir(path):
            continue
        print("%s -- NO metadata, so pip cannot see or remove it\n"
              "        remove with: sudo rm -rf %s" % (entry, path))
PYEOF
)"
    [[ -z "$found" ]] && return 0
    warn "pip packages outside apt that shadow a system library this stack links:"
    printf '    %s\n' "$found" >&2
    warn "spatialnde2 links the SYSTEM Qt (qtbase5-dev, python3-pyqt5). A pip Qt"
    warn "ships its own Qt runtime and sip module and can be selected instead at"
    warn "import time, which produces crashes rather than a clean error -- most"
    warn "often 'undefined symbol: _ZdaPvm' out of PyQt5/QtCore.abi3.so during"
    warn "'import spatialnde2'. If these belong to no project on this machine,"
    warn "remove them with the command printed beside each one before building."
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

# ===========================================================================
# THE SOURCING RULE, stated once, because it was not uniform and it showed.
#
#   Every step that runs colcon, ros2, rosdep or a Python that imports rclpy
#   calls source_ros() first, and then workspace_env() -- and nothing else
#   sources anything. source_ros is the ONLY place that names
#   /opt/ros/$ROSDISTRO/setup.bash; it guards on the file existing and relaxes
#   nounset across the source, both of which a bare `source` does not.
#
# The exception, and the only one: `rosdep update` in phase_prereqs runs with
# no ROS environment on purpose. It is the step that exists to be run on a
# machine where /opt/ros may have just appeared, it needs nothing from the
# distribution, and sourcing a setup.bash there would make a first bootstrap
# depend on the thing it is bootstrapping.
#
# WHY THIS IS A SECTION AND NOT A LINE. The sourcing was already right inside
# this script -- phase_rosdep, phase_build and phase_verify all call
# source_ros. What was wrong is that the build phase ran colcon in an
# environment the generated tari_setup.bash did not reproduce, so building by
# hand and building through the script were two different builds:
#
#   * COLCON_DEFAULTS_FILE was set on phase_build's command line only. There is
#     a whole comment below about colcon-defaults resolving its file against
#     the current directory, and a test guarding phase_build for it -- and then
#     tari_setup.bash did not export it, so a hand-run `colcon build` in ros_ws
#     reinstated exactly that trap and compiled with an empty CMAKE_BUILD_TYPE.
#   * the ros2plugin skip was a local array. When SOFA is absent the script
#     skips that package; a hand-run colcon build does not know that, attempts
#     it, and dies with
#
#         CMake Error at CMakeLists.txt:9 (message):
#           Please specify variable SOFA_INSTALL_DIR in your environnement
#
#     which is what happened on the cell: the script's own build never got far
#     enough to matter, and the operator's hand-run build hit this and had to
#     work it out from the CMake error.
#
# So both live in workspace_env_lines(), which emits shell assignments; the
# build phase evaluates them and phase_env writes the same text into
# tari_setup.bash. One source of truth, and a hand-run build is the scripted
# one.
# ===========================================================================
#: The colcon package that needs SOFA, named once. It is `ros2plugin` in
#: tari_ros (sofaros2plugin upstream), and both phase_build's --packages-skip
#: and the note in tari_setup.bash have to agree about it.
SOFA_PACKAGE=ros2plugin

workspace_env_lines() {
    local models="$WS/src/tari_ros/tari_ur_launch/models"

    # colcon-defaults resolves `colcon_defaults.yaml` against the CURRENT
    # DIRECTORY, and every build here runs from ros_ws while the file is in the
    # workspace root. Absolute, in the environment, so it is read wherever
    # colcon is started from.
    echo "export COLCON_DEFAULTS_FILE=\"$ROOT/colcon_defaults.yaml\""

    # Gazebo finds our models here rather than by copying them into
    # /usr/share/gazebo-11/models, which needed root, was not idempotent, and
    # left stale copies behind whenever a model was renamed.
    echo "export GAZEBO_MODEL_PATH=\"$models\${GAZEBO_MODEL_PATH:+:\$GAZEBO_MODEL_PATH}\""

    if [[ -d "$WS/src/sofa" ]]; then
        echo "export SOFA_INSTALL_DIR=\"$WS/src/sofa\""
    else
        echo "# SOFA is not checked out, so $SOFA_PACKAGE cannot build: it does a hard"
        echo "# CMake error when SOFA_INSTALL_DIR is unset. tari.bash's build phase"
        echo "# passes --packages-skip $SOFA_PACKAGE; a colcon build by hand needs"
        echo "# the same, or --with-sofa and a rebuild."
        echo "export TARI_COLCON_SKIP=\"$SOFA_PACKAGE\""
    fi

    # Cell manifests: tari_bringup searches every PACKAGE named in
    # TARI_CELL_PATH first and its own config/cells last, so a site manifest
    # overrides a shipped one without editing the shared package. A package
    # name rather than a path, so it survives the workspace moving.
    #
    # Only for the site layer. Naming tari_cell_configs in a sim-layer setup
    # would point at a package that layer deliberately does not have --
    # harmless, because search_paths() ignores entries it cannot resolve, but
    # it reads like the setup is broken when it is doing exactly the right
    # thing.
    if layer_at_least site; then
        echo "export TARI_CELL_PATH=\"tari_cell_configs\${TARI_CELL_PATH:+:\$TARI_CELL_PATH}\""
    fi
}

# The same lines, applied to this process. Used by every phase that runs
# colcon, so the scripted build and `source ./tari_setup.bash` cannot drift.
workspace_env() {
    local line
    while IFS= read -r line; do
        [[ "$line" == export* ]] || continue
        eval "$line"
    done < <(workspace_env_lines)
}

phase_build() {
    say "colcon build"
    source_ros
    workspace_env

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
        note "SOFA at ${SOFA_INSTALL_DIR:-?} (from workspace_env)"
    else
        skip=(--packages-skip "$SOFA_PACKAGE")
        note "SOFA not present; skipping $SOFA_PACKAGE (use --with-sofa to build it)"
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
    # COLCON_DEFAULTS_FILE comes from workspace_env above rather than from this
    # command line, so the environment that builds here is the one
    # tari_setup.bash reproduces. See the sourcing rule above.
    run "cd '$WS' && colcon build --symlink-install \
         --parallel-workers $workers ${skip[*]}"
}

phase_env() {
    say "Environment"
    local out="$ROOT/tari_setup.bash"

    # --dry-run writes nothing. This phase used to write tari_setup.bash
    # whatever the flag said, which makes --dry-run a modification of the
    # machine and the one flag you cannot trust on a shared box.
    if [[ $DRYRUN -eq 1 ]]; then
        note "+ would write $out:"
        workspace_env_lines | sed 's/^/      /'
        return 0
    fi

    # The two `source` lines are GUARDED and nounset-safe, for the same reason
    # source_ros and source_quietly are: colcon's generated setup.bash reads
    # variables it does not set, so sourcing one from a shell with `set -u`
    # aborts with "unbound variable", and an unguarded `source` of a missing
    # /opt/ros/.../setup.bash takes the caller's shell down with it. A file
    # meant to be sourced by everything has to survive both.
    #
    # Everything after them comes from workspace_env_lines, which is the same
    # text phase_build evaluates -- see the sourcing rule above it.
    cat > "$out" <<EOF
# Generated by tari.bash on $(date -u +%Y-%m-%dT%H:%M:%SZ) for layer '$LAYER'.
# Regenerate with: ./tari.bash --layer $LAYER --phase env
#
# Source this in every shell that runs anything here, INCLUDING shells that run
# dataguzzler-python. dgpython_rosmotion is a colcon package, so \`import
# dgpython_rosmotion\` in a .dgp resolves through the overlay, not through pip.
#
# This is also the environment tari.bash's own build phase uses. Build by hand
# with this sourced and you get the same build; without it you get a different
# one -- an empty CMAKE_BUILD_TYPE, and an attempt at a package that needs SOFA.

__tari_source() {
    [ -f "\$1" ] || { echo "tari_setup.bash: no such file: \$1" >&2; return 1; }
    case "\$-" in *u*) set +u; . "\$1"; set -u ;; *) . "\$1" ;; esac
}
if __tari_source "/opt/ros/$ROSDISTRO/setup.bash"; then
    [ -f "$WS/install/setup.bash" ] && __tari_source "$WS/install/setup.bash"
else
    echo "tari_setup.bash: ROS $ROSDISTRO is not installed, so nothing here" >&2
    echo "will run. Re-bootstrap with ./tari.bash --layer $LAYER" >&2
fi
unset -f __tari_source

EOF
    workspace_env_lines >> "$out"

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
    workspace_env
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
# Both of these are about the workspace belonging to somebody else, so they run
# once for every invocation and before any phase -- including a single
# `--phase build`, which is the one most likely to be run on its own and the
# one the ownership fault destroys.
export_workspace_safe_directories
warn_about_shared_workspace_policy
assert_workspace_artefacts_writable

if [[ -n "$ONLY_PHASE" ]]; then
    printf '%s\n' "${ALL_PHASES[@]}" | grep -qx "$ONLY_PHASE" \
        || die "unknown phase: $ONLY_PHASE (one of: ${ALL_PHASES[*]})"
    "phase_$ONLY_PHASE"
    exit $?
fi

for p in "${ALL_PHASES[@]}"; do
    "phase_$p"
done
