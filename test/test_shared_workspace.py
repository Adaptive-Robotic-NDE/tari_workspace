"""A workspace in someone else's home, driven by whichever human is logged in.

The robot runs as an unprivileged shared account (`labuser` on the cell), so
the workspace lives in that account's home -- but labuser has no sudo and
almost every phase needs it, so the person who runs the script is a named
account with sudo, operating on a tree another account owns and that the whole
`labusers` group has to be able to rewrite tomorrow. The directories carry the
setgid bit so new files inherit the group.

Setgid gives the GROUP, not group WRITE: the mode comes from the creating
process's umask, and the default 022 produces `-rw-r--r-- lesthatj labusers`,
which nobody else in the group can write, truncate or chmod. The first cell run
died of exactly that, twice over, and neither failure named ownership:

  * the python phase, where `sudo pip install .` makes setuptools_scm run git
    as root over labuser's checkout:

        fatal: detected dubious ownership in repository at
               '/home/labuser/tari/dgpython-opencv-camera'
        error: metadata-generation-failed

  * the build phase, where ros_ws/build and ros_ws/install were full of another
    account's 0644 files:

        CMake Error ... (configure_file): Operation not permitted
        PermissionError: [Errno 13] ... install/.../package.dsv

    seven packages failed and seventeen aborted behind them.

Both were worked around on the machine by hand -- `sudo git config --global
--add safe.directory "*"`, then `sudo chown -R`, then `rm -rf build install`.
The tests here are about the script not needing that next time.

Nothing here installs anything, builds anything or touches the network.

    python3 -m pytest test/test_shared_workspace.py
"""

import os
import re
import shutil
import stat
import subprocess

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARI = os.path.join(ROOT, "tari.bash")
INSTALLER = os.path.join(ROOT, "dgpy_install.sh")

skip_if_root = pytest.mark.skipif(
    os.geteuid() == 0,
    reason="root ignores file permissions, so none of this can be observed",
)


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as handle:
        return handle.read()


def workspace(tmp_path):
    """A workspace root holding a copy of tari.bash and an empty manifest.

    tari.bash takes its ROOT from its own location, so it has to be copied
    rather than run in place.
    """
    root = tmp_path / "ws"
    root.mkdir()
    shutil.copy(TARI, root / "tari.bash")
    shutil.copy(os.path.join(ROOT, "colcon_defaults.yaml"),
                root / "colcon_defaults.yaml")
    (root / "container.repos").write_text("repositories:\n", encoding="utf-8")
    return root


def run_tari(root, args, timeout=120):
    return subprocess.run(
        [str(root / "tari.bash"), "--layer", "container", *args],
        cwd=str(root), capture_output=True, text=True, timeout=timeout,
    )


# ---------------------------------------------------------------------------
# 1. The umask, which is the other half of the setgid bit.
# ---------------------------------------------------------------------------
def test_the_script_sets_a_group_writable_umask():
    text = read("tari.bash")
    match = re.search(r"^umask\s+\"?\$\{TARI_UMASK:-(\d+)\}", text, re.M)
    assert match, (
        "tari.bash does not set a umask. With setgid directories and the "
        "default 022, every file it creates is group-READABLE and not "
        "group-writable, so the next person in labusers cannot rebuild over "
        "it and only root can repair it.")
    mode = int(match.group(1), 8)
    assert not (mode & stat.S_IWGRP), (
        "the default umask masks group write (%s), which is the fault, not the "
        "fix" % match.group(1))


@skip_if_root
def test_what_the_env_phase_writes_is_group_writable(tmp_path):
    """The claim above, measured rather than grepped.

    tari_setup.bash is the file every shell here sources; if the group cannot
    rewrite it, the next person's `--phase env` fails instead of updating it.
    """
    root = workspace(tmp_path)
    result = run_tari(root, ("--phase", "env"))
    assert result.returncode == 0, result.stdout + result.stderr
    mode = os.stat(str(root / "tari_setup.bash")).st_mode
    assert mode & stat.S_IWGRP, (
        "tari_setup.bash is mode %o: the labusers group cannot rewrite it"
        % stat.S_IMODE(mode))


@skip_if_root
def test_tari_umask_is_honoured(tmp_path):
    """So a machine that really does want 022 can have it.

    Also proves the umask is actually applied rather than merely written down:
    the same run with a different value produces a different mode.
    """
    root = workspace(tmp_path)
    env = dict(os.environ, TARI_UMASK="0022")
    result = subprocess.run(
        [str(root / "tari.bash"), "--layer", "container", "--phase", "env"],
        cwd=str(root), capture_output=True, text=True, env=env, timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    mode = os.stat(str(root / "tari_setup.bash")).st_mode
    assert not (mode & stat.S_IWGRP), "TARI_UMASK was ignored"


# ---------------------------------------------------------------------------
# 2. Somebody else's artefacts under ros_ws, caught before the build.
#
# A foreign-owned 0644 file cannot be created here without root, and these
# tests must run unprivileged -- but `find -writable` tests access(W_OK), which
# is false for a mode-0444 file the caller owns and for a foreign-owned 0644
# one alike. So 0444 is a faithful stand-in for the condition, and the thing
# being tested is that the script asks the question at all and says what to do
# about the answer.
# ---------------------------------------------------------------------------
@skip_if_root
def test_an_unwritable_build_artefact_stops_the_run_before_the_build(tmp_path):
    root = workspace(tmp_path)
    stale = root / "ros_ws" / "install" / "csf_loader_msgs" / "share"
    stale.mkdir(parents=True)
    dsv = stale / "package.dsv"
    dsv.write_text("stale\n", encoding="utf-8")
    os.chmod(str(dsv), 0o444)

    result = run_tari(root, ("--phase", "build"))
    out = result.stdout + result.stderr
    assert result.returncode != 0, out
    assert "cannot write" in out, out
    assert "package.dsv" in out, "it did not say which file"
    assert "rm -rf" in out, "it did not say how to recover"
    assert "chgrp" in out, "it did not offer the other recovery"
    # And it stopped BEFORE colcon, which is the whole point: the real failure
    # was four minutes of CMake errors that named neither ownership nor an
    # account.
    assert "colcon build" not in out.replace("rm -rf", ""), out


@skip_if_root
def test_a_healthy_workspace_passes_the_check(tmp_path):
    """A guard that refuses everything is not a guard either."""
    root = workspace(tmp_path)
    (root / "ros_ws" / "build").mkdir(parents=True)
    (root / "ros_ws" / "build" / "ok.txt").write_text("fine", encoding="utf-8")
    result = run_tari(root, ("--phase", "env"))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "cannot write" not in (result.stdout + result.stderr)


@skip_if_root
def test_dry_run_reports_the_fault_without_failing(tmp_path):
    """--dry-run exists to describe a machine that is not set up yet.

    fatal_unless_dry is the existing idiom for that; the check has to use it or
    a dry run on the broken machine cannot print the rest of the plan.
    """
    root = workspace(tmp_path)
    (root / "ros_ws" / "build").mkdir(parents=True)
    bad = root / "ros_ws" / "build" / "locked.txt"
    bad.write_text("x", encoding="utf-8")
    os.chmod(str(bad), 0o444)

    result = run_tari(root, ("--phase", "env", "--dry-run"))
    out = result.stdout + result.stderr
    assert "cannot write" in out, out
    assert result.returncode == 0, "a dry run must not fail on it:\n" + out


# ---------------------------------------------------------------------------
# 3. git's dubious-ownership refusal, scoped rather than switched off.
# ---------------------------------------------------------------------------
def code_only(text):
    """Every line that is not a comment.

    Necessary here rather than merely tidy: the comment block explaining this
    fix quotes the hand workaround it exists to replace, so a search over the
    whole file finds the forbidden form in the prose that forbids it.
    """
    return "\n".join(line for line in text.splitlines()
                     if not line.lstrip().startswith("#"))


def test_tari_scopes_safe_directory_to_this_process():
    text = read("tari.bash")
    assert "GIT_CONFIG_COUNT" in text, (
        "nothing arranges safe.directory, so every git call on a tree owned by "
        "another account refuses with 'detected dubious ownership'.")
    assert "safe.directory" in text
    code = code_only(text)
    for forbidden in ("--global --add safe.directory",
                      'safe.directory "*"',
                      "safe.directory '*'"):
        assert forbidden not in code, (
            "tari.bash writes a permanent, machine-wide safe.directory (%s). "
            "That is the hand workaround, not the fix: GIT_CONFIG_COUNT/KEY/"
            "VALUE applies the same setting to this process only." % forbidden)


def test_the_installer_passes_safe_directory_through_sudo():
    """sudo runs with env_reset, so GIT_CONFIG_* has to be named explicitly."""
    text = read("dgpy_install.sh")
    assert "GIT_CONFIG_KEY_" in text and "safe.directory" in text, (
        "dgpy_install.sh installs under sudo and every package is versioned by "
        "setuptools_scm, which shells out to git. Without safe.directory in "
        "that environment the build dies with 'git introspection failed: "
        "fatal: detected dubious ownership'.")


@skip_if_root
def test_the_installers_dry_run_shows_the_safe_directory_env():
    """Measured on the printed command, because that is what will be run.

    dgpy_install.sh builds the printed command and the executed one with the
    same function, which is what makes this worth asserting on.
    """
    if not os.path.isdir(os.path.join(ROOT, "dataguzzler-python")):
        pytest.skip("dataguzzler-python is not checked out")
    result = subprocess.run(
        [INSTALLER, "--dry-run", "--force", "--only", "dataguzzler-python"],
        cwd=ROOT, capture_output=True, text=True, timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "GIT_CONFIG_KEY_0=safe.directory" in result.stdout, result.stdout
    assert "GIT_CONFIG_COUNT=" in result.stdout, result.stdout
    # The workspace root is listed as well as the package: setuptools_scm walks
    # up from wherever it starts, and for spatialnde2 pip is run from the cmake
    # build directory rather than the source root.
    assert os.path.join(ROOT, "dataguzzler-python") in result.stdout
    assert "GIT_CONFIG_VALUE_1=%s" % ROOT in result.stdout, result.stdout


# ---------------------------------------------------------------------------
# 4. The policy itself: one group, setgid, and a umask that leaves group write.
#
# Two out of three is the state the cell was in, and it looks like it works
# until a second person builds. What CANNOT be tested here is the warning
# itself: triggering it needs a workspace whose top-level entries have two
# different owners, and creating a file owned by another account needs root.
# So the silent path is measured, the loud path is read.
# ---------------------------------------------------------------------------
def test_the_policy_check_runs_before_every_phase():
    text = read("tari.bash")
    code = code_only(text)
    for fn in ("export_workspace_safe_directories",
               "warn_about_shared_workspace_policy",
               "assert_workspace_artefacts_writable"):
        assert ("\n%s\n" % fn) in code, (
            "%s is never called at top level. All three are about the "
            "workspace belonging to another account, so they have to run for "
            "every invocation -- including a bare `--phase build`, which is "
            "the one the ownership fault destroys." % fn)
    # Before the dispatcher, or a `--phase build` skips them.
    assert code.index("warn_about_shared_workspace_policy\n") < \
        code.index('if [[ -n "$ONLY_PHASE" ]]'), \
        "the checks run after the phase dispatcher, so --phase skips them"


def test_the_policy_names_all_three_parts():
    """An incomplete arrangement is the fault; a partial remedy repeats it."""
    text = read("tari.bash")
    match = re.search(r"THE POLICY, checked.*?^warn_about_shared_workspace_policy",
                      text, re.M | re.S)
    assert match, "the policy block is gone"
    block = match.group(0)
    for part in ("labusers", "setgid", "umask"):
        assert part in block, "the policy does not mention %s" % part


@skip_if_root
def test_the_policy_check_is_silent_on_a_single_owner_workspace(tmp_path):
    """Most machines are one person's, and this must not nag there."""
    root = workspace(tmp_path)
    result = run_tari(root, ("--phase", "env"))
    assert result.returncode == 0, result.stdout + result.stderr
    out = result.stdout + result.stderr
    assert "shared workspace" not in out, out
    assert "setgid" not in out, out
