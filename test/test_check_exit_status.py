"""What --check reports as a FAILURE, and the one case that is exempt.

dgpy_install.sh --check is an assertion, not a report: tari.bash's verify phase
runs it and fails the phase on a non-zero exit, and the container image build
runs it so that an image quietly missing a dataguzzler package fails the build
rather than surfacing as an ImportError in a scan months later.

Those two callers want different things from one state. DIRTY means the source
has uncommitted changes, so no installed copy can be KNOWN to match it:

  * On a developer's or a cell machine that uncertainty is the whole point, and
    tari.bash must keep failing on it. That caller passes no flag.
  * In an image build it is false. The layer copies a tree in and installs from
    exactly that tree seconds later, so the installed copy is known to match,
    uncommitted changes and all. Without an exemption no image could be built
    while anyone had uncommitted work in any of nine packages -- which is most
    days.

So the exemption is opt-in and narrow, and these tests pin both halves: that
--allow-dirty excuses DIRTY and ONLY DIRTY, and that the default is unchanged.
The second half is the regression that would matter, because it is silent --
a --check that stopped failing would make every caller above pass forever.

    python3 -m pytest test/

Nothing here installs anything. package_status() is replaced with a stub that
reports a fixed state, so the script runs its reporting logic over invented
input and never looks at a real package.
"""

import os
import subprocess

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALLER = os.path.join(ROOT, "dgpy_install.sh")


def installer_reporting(tmp_path, state, detail="stub detail"):
    """A copy of the installer whose package_status() always returns `state`.

    Replacing the function rather than building a workspace keeps the test about
    the reporting logic -- which states are fatal -- instead of about git, pip,
    and what happens to be installed on the machine running the suite.
    """
    if not os.path.exists(INSTALLER):
        pytest.skip("dgpy_install.sh is not checked out")
    with open(INSTALLER, encoding="utf-8") as handle:
        lines = handle.read().splitlines(True)

    start = next(i for i, line in enumerate(lines)
                 if line.startswith("package_status()"))
    # The function's closing brace is the next line that is exactly "}" in
    # column 0; anything else would be inside it.
    end = next(i for i in range(start + 1, len(lines))
               if lines[i].rstrip() == "}")
    lines[start:end + 1] = ['package_status() { echo "%s|%s"; }\n' % (state, detail)]

    path = tmp_path / "dgpy_install.sh"
    path.write_text("".join(lines), encoding="utf-8")
    path.chmod(0o755)
    return str(path)


def check(script, *args):
    return subprocess.run([script, "--check", *args],
                          cwd=ROOT, capture_output=True, text=True)


def test_dirty_fails_check_by_default(tmp_path):
    """tari.bash's verify phase depends on this, and passes no flag.

    If this ever passes, a machine running something other than what is checked
    out stops being detectable by the one command that exists to detect it.
    """
    result = check(installer_reporting(tmp_path, "DIRTY"))
    assert result.returncode == 1, result.stdout


def test_allow_dirty_excuses_dirty(tmp_path):
    """The image build's case: installed from this tree, uncommitted and all."""
    result = check(installer_reporting(tmp_path, "DIRTY"), "--allow-dirty")
    assert result.returncode == 0, result.stdout + result.stderr


def test_allow_dirty_still_says_the_tree_was_dirty(tmp_path):
    """Exempt is not hidden. A passing build that silently shipped uncommitted
    work would be worse than a failing one."""
    result = check(installer_reporting(tmp_path, "DIRTY"), "--allow-dirty")
    assert "DIRTY" in result.stdout
    # ...and it must not tell the reader to go and reinstall, which is the
    # advice for the states that ARE faults.
    assert "Reinstall the packages above" not in result.stdout


@pytest.mark.parametrize("state", ["MISSING", "STALE", "EDITABLE", "USER-SITE",
                                   "LEGACY", "UNVERSIONED", "BROKEN"])
def test_allow_dirty_excuses_nothing_else(tmp_path, state):
    """The flag is an exemption for one state, not a way to pass --check.

    EDITABLE and USER-SITE especially: those mean the install itself is in the
    wrong place rather than merely out of date, and a per-user copy shadows the
    system one on sys.path, so an image that shipped either would run something
    other than what it installed.
    """
    result = check(installer_reporting(tmp_path, state), "--allow-dirty")
    assert result.returncode == 1, f"{state} was excused:\n{result.stdout}"


def test_ok_passes_either_way(tmp_path):
    """The flag must not change the ordinary answer."""
    for args in ((), ("--allow-dirty",)):
        result = check(installer_reporting(tmp_path, "OK", "1.0"), *args)
        assert result.returncode == 0, result.stdout


def test_absent_still_passes(tmp_path):
    """Pre-existing exemption, same shape as the new one: an absent source says
    which layer this machine has rather than that anything is wrong. Pinned here
    because the new branch sits directly beside it in the same case."""
    result = check(installer_reporting(tmp_path, "ABSENT", "not checked out"))
    assert result.returncode == 0, result.stdout
