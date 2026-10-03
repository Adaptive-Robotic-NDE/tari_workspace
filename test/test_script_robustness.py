"""Static guards against three shell/colcon faults that a clean-machine
bootstrap found and a development machine cannot.

Each of these produced a wrong answer rather than an error, which is why they are
worth a test rather than a comment. Nothing here runs a build or installs
anything; every check reads a file.

    python3 -m pytest test/
"""

import os
import re

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SHELL_SCRIPTS = ("tari.bash", "dgpy_install.sh", "ros2_docker.sh")


def read(rel):
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        pytest.skip(f"{rel} is not checked out")
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def code_lines(text):
    """Line number and text for every line that is not a comment.

    Crude on purpose: these scripts carry long diagnostics and explanatory
    blocks that quote the very forms being banned, and every one of those blocks
    is comments or a quoted heredoc. A line whose first non-blank character is
    `#` is prose here.
    """
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        yield number, line


# ---------------------------------------------------------------------------
# 1. `producer | grep -q` under `set -o pipefail`.
#
# grep -q exits at its first match and closes the pipe; a producer with more to
# say then dies of SIGPIPE, and pipefail makes the pipeline's status 141. So the
# pipeline reports FAILURE precisely when the thing being looked for is present
# and the producer is long-winded:
#
#     $ set -euo pipefail
#     $ if ldconfig -p | grep -q libk4a; then echo FOUND; else echo "NOT ($?)"; fi
#     NOT (141)
#
# Measured on lablinux 2026-09-30, where it made `tari.bash --layer hw` refuse to
# build with "MISSING: Azure Kinect Sensor SDK" on a machine carrying libk4a
# 1.4.2. The fix is to read the producer's whole output first -- tari.bash's
# have_shared_lib() does -- or to drop -q.
#
# Only producers that can outrun the consumer matter. A `printf` or a here-string
# cannot, so the list is the commands that emit more than a pipe buffer.
# ---------------------------------------------------------------------------
CHATTY_PRODUCERS = ("ldconfig", "dpkg -l", "dpkg -L", "apt-cache", "pip list",
                    "pip freeze", "colcon list", "find ", "git log")

GREP_Q = re.compile(r"\|\s*grep\b[^|]*\s-[A-Za-z]*q")


@pytest.mark.parametrize("rel", SHELL_SCRIPTS)
def test_no_grep_q_on_a_chatty_producer(rel):
    text = read(rel)
    if "pipefail" not in text:
        pytest.skip(f"{rel} does not set pipefail")
    found = []
    for number, line in code_lines(text):
        if not GREP_Q.search(line):
            continue
        for producer in CHATTY_PRODUCERS:
            if producer in line.split("|")[0]:
                found.append(f"{rel}:{number}: {line.strip()}")
                break
    assert not found, (
        "`... | grep -q` under pipefail returns 141 when the match is FOUND "
        "and the producer keeps writing. Read the output into a variable "
        "first (see have_shared_lib in tari.bash):\n" + "\n".join(found))


def test_the_grep_q_check_catches_the_original_fault():
    """A guard that passes everything is not a guard."""
    original = "    if ldconfig -p 2>/dev/null | grep -q libk4a; then"
    assert GREP_Q.search(original)
    assert "ldconfig" in original.split("|")[0]


# ---------------------------------------------------------------------------
# 2. colcon-defaults reads colcon_defaults.yaml from the CURRENT DIRECTORY.
#
# colcon_defaults/argument_parser/defaults.py does
#
#     local_defaults_path = Path(WORKSPACE_DEFAULTS_FILE)   # 'colcon_defaults.yaml'
#
# a relative path, resolved against the process's cwd. tari.bash builds from
# ros_ws while colcon_defaults.yaml sits in the workspace root one level up, so
# the file was never read: the whole workspace compiled with an empty
# CMAKE_BUILD_TYPE, meaning no optimisation flags at all, and nothing said so.
# COLCON_DEFAULTS_FILE is the environment variable that names it absolutely.
# ---------------------------------------------------------------------------
def build_phase_body():
    """tari.bash's phase_build, as code with comments stripped.

    A line is the wrong unit here: the colcon invocation is a continued line
    inside a quoted run "..." argument. The function body is the unit that can
    be asserted about.
    """
    text = read("tari.bash")
    match = re.search(r"^phase_build\(\)\s*\{(.*?)^\}", text, re.M | re.S)
    assert match, "tari.bash has no phase_build"
    body = "\n".join(line for _, line in code_lines(match.group(1)))
    assert "colcon build" in body, "phase_build no longer runs colcon build"
    return body


def workspace_env_body():
    """tari.bash's workspace_env_lines, as code with comments stripped.

    The variables the build needs used to be set on phase_build's own command
    line, which meant the generated tari_setup.bash did not have them and a
    hand-run build was a different build. They now live in one function that
    both the build phase and the env phase read, so that is the function to
    assert about.
    """
    text = read("tari.bash")
    match = re.search(r"^workspace_env_lines\(\)\s*\{(.*?)^\}", text, re.M | re.S)
    assert match, "tari.bash has no workspace_env_lines"
    return "\n".join(line for _, line in code_lines(match.group(1)))


def test_colcon_build_names_the_defaults_file_absolutely():
    if not os.path.exists(os.path.join(ROOT, "colcon_defaults.yaml")):
        pytest.skip("no colcon_defaults.yaml in this workspace")
    body = build_phase_body()
    env = workspace_env_body()
    assert "COLCON_DEFAULTS_FILE" in body or "workspace_env" in body, (
        "colcon-defaults resolves colcon_defaults.yaml against the current "
        "directory, and this build runs from ros_ws while the file is in the "
        "workspace root -- so it is not read and CMAKE_BUILD_TYPE stays empty, "
        "which means the whole workspace compiles with no optimisation flags. "
        'Set COLCON_DEFAULTS_FILE="$ROOT/colcon_defaults.yaml".')
    assert "COLCON_DEFAULTS_FILE" in env, (
        "phase_build gets its environment from workspace_env_lines, so that is "
        "where COLCON_DEFAULTS_FILE has to be -- otherwise neither the scripted "
        "build nor tari_setup.bash has it.")


def test_colcon_build_bounds_its_parallelism():
    """One worker per core is an OOM on MoveIt-scale C++ on a shared machine."""
    assert "--parallel-workers" in build_phase_body(), (
        "colcon defaults to one worker per core; sixteen simultaneous links of "
        "moveit_task_constructor_core-sized translation units get a compiler "
        "OOM-killed and the build dies with a bare "
        '"c++: fatal error: Killed signal terminated program".')


# ---------------------------------------------------------------------------
# 3. Every rosdep key that must not be resolved needs a reason next to it.
#
# --skip-keys is how a real dependency gets silently dropped, so the list is
# only safe while each entry carries the argument for it. Both of today's
# entries are cases where resolving the key would install the WRONG thing:
# `libvtk` is VTK 7 on jammy while noether_tpp requires VTK 9, and `catkin` has
# no rule at all under a ROS 2 distribution.
# ---------------------------------------------------------------------------
def test_every_skipped_rosdep_key_is_explained():
    text = read("tari.bash")
    match = re.search(r"^ROSDEP_SKIP_KEYS=\(([^)]*)\)", text, re.M)
    if match is None:
        pytest.skip("tari.bash skips no rosdep keys")
    keys = match.group(1).split()
    assert keys, "ROSDEP_SKIP_KEYS is empty; drop the variable instead"
    # The comment block immediately above the assignment is where the reasons go.
    preamble = text[:match.start()].splitlines()
    block = []
    for line in reversed(preamble):
        if not line.startswith("#"):
            break
        block.append(line)
    block = "\n".join(block)
    missing = [k for k in keys if k not in block]
    assert not missing, (
        "--skip-keys silently drops a dependency, so each key needs its reason "
        "in the comment block above ROSDEP_SKIP_KEYS. Unexplained: "
        + ", ".join(missing))
