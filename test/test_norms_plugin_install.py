"""The site layer installs the NORMS metadata plug-in, correctly.

NORMS/EASEL documents a measurement from the files it finds and the forms the
operator fills in; a plug-in is the only path by which anything inside the data
files reaches that record. EASEL starts it BY ABSOLUTE PATH with no shell, so it
has to land at a fixed location on the acquisition machine rather than stay in
a checkout.

Everything here is driven through tari.bash's own --dry-run, so nothing is
installed and no privilege is used. The failure modes being guarded are all
quiet ones -- the plug-in installed on a machine that does not need it, not
installed on one that does, or installed without the executable bit, which EASEL
reports only as "Plug-in Not Defined" after a scan has already been taken.

    python3 -m pytest test/
"""

import os
import re
import subprocess
import tempfile

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARI = os.path.join(ROOT, "tari.bash")
SOURCE = os.path.join(ROOT, "ROS-Scanning", "norms", "ec_scan_plugin.py")


def build_phase(layer, dest=None):
    """tari.bash's build phase, dry, for one layer. Returns its output."""
    env = dict(os.environ)
    if dest is not None:
        env["TARI_NORMS_PLUGIN_DIR"] = dest
    result = subprocess.run(
        [TARI, "--layer", layer, "--phase", "build", "--dry-run"],
        cwd=ROOT, capture_output=True, text=True, env=env, timeout=600,
    )
    assert result.returncode == 0, result.stderr + result.stdout
    return result.stdout + result.stderr


@pytest.fixture
def empty_dest():
    with tempfile.TemporaryDirectory() as d:
        yield os.path.join(d, "ec-scan")


def test_the_site_layer_installs_it(empty_dest):
    out = build_phase("site", empty_dest)
    assert "ec_scan_plugin.py" in out, out


def test_no_other_layer_installs_it(empty_dest):
    """A site takes eddy-current scans; a simulation workstation does not, and
    a plug-in on it would be a file nobody can explain later."""
    for layer in ("sim", "acq", "hw"):
        out = build_phase(layer, empty_dest)
        assert "ec_scan_plugin" not in out, f"--layer {layer} touched the plug-in:\n{out}"


def test_it_is_installed_executable(empty_dest):
    """0755, and this is the assertion worth having: without the executable bit
    EASEL reports "Plug-in Not Defined", runs nothing, and records no metadata
    at all -- discovered after a scan, not before one."""
    out = build_phase("site", empty_dest)
    command = [l for l in out.splitlines() if "sudo install" in l]
    assert command, f"the install command was not printed:\n{out}"
    assert re.search(r"sudo install -D -m 0755 ", command[0]), command[0]
    assert SOURCE in command[0], command[0]
    assert os.path.join(empty_dest, "ec_scan_plugin.py") in command[0], command[0]


def test_it_is_idempotent(empty_dest):
    """tari.bash is run again on every deployment; an install that copies every
    time rewrites a file EASEL may be about to start."""
    out = build_phase("site", empty_dest)
    assert "sudo install" in out

    os.makedirs(empty_dest, exist_ok=True)
    with open(SOURCE, "rb") as src, \
            open(os.path.join(empty_dest, "ec_scan_plugin.py"), "wb") as dst:
        dst.write(src.read())

    again = build_phase("site", empty_dest)
    assert "sudo install" not in again, f"copied again although current:\n{again}"
    assert "already current" in again, again


def test_it_says_how_to_configure_easel(empty_dest):
    """The install is half the job: a plug-in EASEL has not been pointed at is
    a file on a disk. The four Setup fields are printed where the person doing
    the deployment is looking."""
    out = build_phase("site", empty_dest)
    for field in ("Plugin Executable", "Extension(s)", "Arguments", "Restriction"):
        assert field in out, f"{field!r} is not in the deployment output:\n{out}"
    assert "Only Oldest" in out, out


def test_the_thing_being_installed_satisfies_easels_contract():
    """The source file itself, checked where the deployment can see it.

    ROS-Scanning's own suite tests the plug-in's behaviour; this is the subset a
    bootstrap cares about, because these three are what make EASEL discard a run
    without the operator seeing anything: no executable bit, no shebang, or an
    interpreter resolved through PATH -- EASEL passes its own environment, and a
    sourced ROS overlay puts a python3 first that has no numpy.
    """
    if not os.path.exists(SOURCE):
        pytest.skip("ROS-Scanning is not checked out")
    assert os.access(SOURCE, os.X_OK), "no executable bit on the source"
    with open(SOURCE, "rb") as handle:
        first = handle.readline()
    assert first.startswith(b"#!"), "no shebang"
    assert not first.rstrip(b"\n").endswith(b"\r"), "CRLF shebang"
    assert b"/usr/bin/env" not in first, \
        "the interpreter must be pinned, not resolved through PATH"
