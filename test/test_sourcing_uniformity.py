"""THE SOURCING RULE: one place names the ROS environment, and the generated
setup file reproduces the environment the build phase used.

The operator's report after the first cell run was that tari.bash is
"inconsistent about sourcing /opt/ros/iron/setup.bash or even just
tari_setup.bash". Auditing it, the `source` calls themselves were already
right -- phase_rosdep, phase_build and phase_verify all go through
source_ros(). What was actually inconsistent is the half nobody calls sourcing:
the build phase ran colcon in an environment that tari_setup.bash did not
reproduce, so building through the script and building by hand were two
different builds.

Two variables, both visible in the log:

  * COLCON_DEFAULTS_FILE was set on phase_build's command line only. colcon's
    defaults extension resolves `colcon_defaults.yaml` against the current
    directory, the build runs from ros_ws and the file is in the workspace
    root, so a hand-run build does not read it and compiles with an empty
    CMAKE_BUILD_TYPE. The operator's hand-run build had to pass
    `--cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo`, which is a third build
    type, neither the script's nor an unset one.

  * the ros2plugin skip was a local array in phase_build. With SOFA absent the
    script skips that package; a hand-run colcon build does not know, attempts
    it, and dies with

        CMake Error at CMakeLists.txt:9 (message):
          Please specify variable SOFA_INSTALL_DIR in your environnement

    which is the SOFA failure in the log, and it came from a build by hand
    rather than from the script.

So the rule being tested is: every step that runs colcon, ros2 or
`rosdep install` calls source_ros() and then workspace_env(), and
workspace_env_lines() is the one definition of the build environment -- read by
the build phase and written into tari_setup.bash.

Greps over the script's own text, plus one real `--phase env` run in a
temporary directory. Nothing builds, installs or touches the network.

    python3 -m pytest test/test_sourcing_uniformity.py
"""

import os
import re
import shutil
import subprocess

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARI = os.path.join(ROOT, "tari.bash")


def read(rel=("tari.bash",)):
    path = os.path.join(ROOT, rel if isinstance(rel, str) else rel[0])
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def code_lines(text):
    """Line number and text for every line that is not a comment.

    Same crude rule as test_script_robustness: this script carries long
    diagnostic blocks that quote the very forms being asserted about, and all
    of them are comments.
    """
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        yield number, line


def functions(text):
    """{name: body-as-code} for every `name() {` ... `}` at column 0."""
    out = {}
    for match in re.finditer(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{(.*?)^\}",
                             text, re.M | re.S):
        out[match.group(1)] = "\n".join(
            line for _, line in code_lines(match.group(2)))
    return out


# ---------------------------------------------------------------------------
# 1. Anything that needs the ROS environment asks for it the same way.
#
# `rosdep update` in phase_prereqs is the one exemption and it is deliberate:
# that step exists to be run on a machine where /opt/ros may have appeared one
# command ago, it needs nothing out of the distribution, and sourcing a
# setup.bash there would make the first bootstrap depend on what it is
# bootstrapping. An exemption that is not written down is indistinguishable
# from the bug, so the comment block is asserted too.
# ---------------------------------------------------------------------------
NEEDS_ROS = (
    re.compile(r"\bcolcon\s+(build|list|test)\b"),
    re.compile(r"\bros2\s+(pkg|run|launch|topic|node|param)\b"),
    re.compile(r"\brosdep\s+install\b"),
)

# These print a command rather than running one. The script's diagnostics quote
# the commands they are about -- "a later 'colcon test' passes having run
# nothing", "Try: ros2 launch ..." -- so a line that only tells the operator
# about a command is not a line that needs an environment. Kept narrow on
# purpose: `run` and `eval` are not here, so an actual invocation always counts.
PRINTS_ONLY = re.compile(r"^\s*(warn|note|say|die|fatal_unless_dry|echo|printf)\b")

# usage() prints the --help text and workspace_env_lines() prints the comments
# that go into tari_setup.bash; both quote commands they do not run, across
# heredocs and case arms that the per-line rule above cannot see into.
EXEMPT = {"usage", "workspace_env_lines"}


def invokes_ros(body):
    """True when a line in `body` RUNS a ROS command, rather than printing one."""
    for line in body.splitlines():
        if PRINTS_ONLY.match(line):
            continue
        if any(pattern.search(line) for pattern in NEEDS_ROS):
            return True
    return False


def test_every_step_that_needs_ros_sources_it_the_same_way():
    offenders = []
    for name, body in functions(read()).items():
        if name in EXEMPT or not invokes_ros(body):
            continue
        if "source_ros" not in body:
            offenders.append("%s() runs a ROS command without source_ros" % name)
        if "workspace_env" not in body:
            offenders.append("%s() runs a ROS command without workspace_env" % name)
    assert not offenders, (
        "The rule is source_ros() then workspace_env(), in that order, in every "
        "step that runs colcon, ros2 or `rosdep install`. See the sourcing rule "
        "block above phase_build.\n" + "\n".join(offenders))


def test_the_audit_tells_a_command_from_a_mention_of_one():
    """Both halves, or the audit is either useless or unsatisfiable."""
    assert invokes_ros('    run "cd ws && colcon build --symlink-install"')
    assert invokes_ros('    ros2 pkg prefix "$p" >/dev/null')
    assert not invokes_ros('    warn "a later \'colcon test\' runs nothing"')
    assert not invokes_ros('    note "Try: ros2 launch tari_bringup ..."')


def test_the_rosdep_update_exemption_is_written_down():
    text = read()
    match = re.search(r"THE SOURCING RULE.*?^# ={10,}", text, re.M | re.S)
    assert match, "tari.bash has no sourcing-rule block to point at"
    block = match.group(0)
    assert "rosdep update" in block, (
        "phase_prereqs runs `rosdep update` with no ROS environment. That is "
        "correct and it is the only exemption, so it has to be named in the "
        "sourcing-rule block -- otherwise it reads as the inconsistency the "
        "block exists to deny.")


def test_only_source_ros_names_the_distribution_setup_file():
    """One place knows the path, so one place can guard it.

    A bare `source /opt/ros/.../setup.bash` is two faults: it takes the
    caller's shell down when the file is missing, and under `set -u` it aborts
    on a variable colcon's generated script reads without setting.

    The generated tari_setup.bash heredoc is the one other place that writes
    the path, and it goes through its own guarded helper; it is allowed here
    because it is a string being written to a file, not a source call.
    """
    offenders = []
    for number, line in code_lines(read()):
        if "/opt/ros/" not in line:
            continue
        if not re.search(r"(^|\s)(source|\.)\s", line):
            continue
        if "source_quietly" in line or "__tari_source" in line:
            continue
        offenders.append("tari.bash:%d: %s" % (number, line.strip()))
    assert not offenders, (
        "sourcing /opt/ros/.../setup.bash outside source_ros/source_quietly:\n"
        + "\n".join(offenders))


# ---------------------------------------------------------------------------
# 2. One definition of the build environment.
# ---------------------------------------------------------------------------
def test_the_build_environment_is_defined_once():
    funcs = functions(read())
    assert "workspace_env_lines" in funcs, (
        "workspace_env_lines is where the build environment lives; both "
        "phase_build and phase_env read it.")
    env = funcs["workspace_env_lines"]
    for var in ("COLCON_DEFAULTS_FILE", "GAZEBO_MODEL_PATH", "SOFA_INSTALL_DIR"):
        assert var in env, "%s is not in workspace_env_lines" % var


def test_phase_build_does_not_set_the_environment_on_its_own_command_line():
    """The regression this whole file is about.

    A variable set inline in phase_build is a variable tari_setup.bash does not
    have, which is a hand-run build that differs from the scripted one.
    """
    body = functions(read())["phase_build"]
    inline = re.findall(r"\b(COLCON_DEFAULTS_FILE|SOFA_INSTALL_DIR)\s*=", body)
    assert not inline, (
        "phase_build sets %s inline. Put it in workspace_env_lines, which "
        "phase_env also writes into tari_setup.bash." % ", ".join(sorted(set(inline))))


def test_phase_env_writes_the_same_lines_the_build_phase_evaluates():
    body = functions(read())["phase_env"]
    assert "workspace_env_lines" in body, (
        "phase_env no longer generates tari_setup.bash from "
        "workspace_env_lines, so the generated file and the build environment "
        "can drift again.")


def test_the_sofa_package_name_is_not_written_twice():
    """--packages-skip and the note in tari_setup.bash have to agree.

    They did not have to agree before, because only one of them existed.
    """
    text = read()
    hits = [n for n, line in code_lines(text) if "ros2plugin" in line]
    assert hits, "ros2plugin is no longer mentioned; has the package been renamed?"
    assert len(hits) == 1, (
        "ros2plugin is spelled out at lines %s. One of those is the skip and "
        "one is the generated note; name it once (SOFA_PACKAGE) so they cannot "
        "disagree." % ", ".join(str(n) for n in hits))


# ---------------------------------------------------------------------------
# 3. The generated file itself, from a real run.
# ---------------------------------------------------------------------------
def env_workspace(tmp_path):
    root = tmp_path / "ws"
    root.mkdir()
    shutil.copy(TARI, root / "tari.bash")
    shutil.copy(os.path.join(ROOT, "colcon_defaults.yaml"),
                root / "colcon_defaults.yaml")
    (root / "container.repos").write_text("repositories:\n", encoding="utf-8")
    return root


def run_env(root, args=()):
    return subprocess.run(
        [str(root / "tari.bash"), "--layer", "container", "--phase", "env",
         *args],
        cwd=str(root), capture_output=True, text=True, timeout=120,
    )


def test_the_env_phase_writes_a_file_that_survives_set_u(tmp_path):
    """It is sourced by every shell here, including ones with `set -u`.

    colcon's generated setup.bash reads COLCON_TRACE and other variables it
    does not set, so an unguarded source under nounset aborts with "unbound
    variable" -- which is why source_quietly exists inside the script, and why
    the generated file needs the same guard. ROS is not installed on the
    machine this test runs on, so this also exercises the missing-file path:
    it must complain and carry on, never kill the sourcing shell.
    """
    root = env_workspace(tmp_path)
    result = run_env(root)
    assert result.returncode == 0, result.stdout + result.stderr
    setup = root / "tari_setup.bash"
    assert setup.exists(), result.stdout + result.stderr

    probe = subprocess.run(
        ["bash", "-c",
         'set -euo pipefail; source "%s" || true; '
         'echo "DEFAULTS=${COLCON_DEFAULTS_FILE:-unset}"' % setup],
        capture_output=True, text=True, timeout=60,
    )
    assert "DEFAULTS=" in probe.stdout, probe.stdout + probe.stderr
    assert "unset" not in probe.stdout, (
        "COLCON_DEFAULTS_FILE is not exported by tari_setup.bash, so a build "
        "run from a shell that sourced it still compiles with an empty "
        "CMAKE_BUILD_TYPE:\n" + probe.stdout + probe.stderr)


def test_the_generated_file_is_lf_only(tmp_path):
    """This script must never emit CRLF, whatever its inputs looked like."""
    root = env_workspace(tmp_path)
    assert run_env(root).returncode == 0
    assert b"\r\n" not in (root / "tari_setup.bash").read_bytes()


def test_the_generated_file_records_the_sofa_skip(tmp_path):
    """So a hand-run colcon build does not walk into the CMake error.

    With SOFA absent the script skips the package; without this line nothing
    tells anyone else to.
    """
    root = env_workspace(tmp_path)
    assert run_env(root).returncode == 0
    text = (root / "tari_setup.bash").read_text()
    assert "ros2plugin" in text, (
        "tari_setup.bash does not mention the package that needs SOFA, so a "
        "build by hand attempts it and dies with 'Please specify variable "
        "SOFA_INSTALL_DIR in your environnement'.")


def test_dry_run_writes_nothing(tmp_path):
    """--dry-run is the one flag that has to be trustworthy on a shared box.

    phase_env used to write tari_setup.bash whatever the flag said.
    """
    root = env_workspace(tmp_path)
    result = run_env(root, args=("--dry-run",))
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (root / "tari_setup.bash").exists(), (
        "--dry-run wrote tari_setup.bash")
    assert "would write" in result.stdout, "it did not say what it would write"


def test_the_sourcing_audit_catches_the_original_shape():
    """A guard that passes everything is not a guard."""
    bad = functions(
        "phase_x() {\n"
        '    run "cd ws && COLCON_DEFAULTS_FILE=x colcon build"\n'
        "}\n")
    body = bad["phase_x"]
    assert any(p.search(body) for p in NEEDS_ROS)
    assert "source_ros" not in body
    assert re.findall(r"\b(COLCON_DEFAULTS_FILE|SOFA_INSTALL_DIR)\s*=", body)


if __name__ == "__main__":      # pragma: no cover
    raise SystemExit(pytest.main([__file__]))
