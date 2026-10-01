"""The three Python-environment repairs the bootstrap owes, and their bounds.

All three come from the same clean-machine logs, and all three are cases where
the scripts said they were handling something and then did not.

  1. setuptools. `pip install -U "setuptools>=64"` resolved to 84.0.0 and broke,
     in one command, every package build here (`No module named
     'pkg_resources'`), every ament_python package in ros_ws (`error: option
     --uninstall not recognized`, because `setup.py develop --uninstall` is
     gone above 80) and `/usr/bin/vcs`. pip printed the reason inside the very
     command that caused it: `colcon-core 0.21.3 requires setuptools<80`.

  2. A setup.py (egg-info) install. dgpy_install.sh printed "replacing it" and
     pip then refused with `uninstall-distutils-installed-package` on four
     consecutive runs.

  3. A pip Qt shadowing the system Qt. The warning only enumerated
     DISTRIBUTIONS, so a leftover package directory whose metadata was gone --
     which still shadows apt's copy on sys.path -- was invisible. That is the
     one that produced `undefined symbol: _ZdaPvm` out of `import spatialnde2`.

The two detectors are tested by extracting the Python they embed and running it
against a temporary directory. Nothing here installs anything or needs network.

    python3 -m pytest test/test_env_repair.py
"""

import os
import re
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SETUPTOOLS_CEILING = 80


def read(rel):
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        pytest.skip(f"{rel} is not checked out")
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def code_lines(text):
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        yield number, line


def embedded_python(text, after):
    """The first `<<'PYEOF' ... PYEOF` heredoc at or after a marker.

    The detectors are shell functions wrapping a Python program. Testing the
    Python directly is the only way to exercise them without a machine in the
    broken state, and extracting it means the test cannot drift away from the
    code that actually runs.
    """
    start = text.index(after)
    begin = text.index("<<'PYEOF'", start)
    begin = text.index("\n", begin) + 1
    end = text.index("\nPYEOF", begin)
    return text[begin:end]


# ---------------------------------------------------------------------------
# 1. The setuptools window.
# ---------------------------------------------------------------------------
SETUPTOOLS_INSTALL = re.compile(r"pip\s+install\b[^\n]*\bsetuptools\b")
# A bound written either literally (`<80`) or through the declared ceiling
# (`<$SETUPTOOLS_CEILING`, which is what the scripts actually do).
UPPER_BOUND = re.compile(r"setuptools[^'\"\s]*<\s*[\d$]")


def unbounded_setuptools_installs(rel, text):
    found = []
    for number, line in code_lines(text):
        if not SETUPTOOLS_INSTALL.search(line):
            continue
        # setuptools_scm is a different distribution and has no ceiling.
        stripped = re.sub(r"setuptools_scm\S*|setuptools-scm\S*", "", line)
        if not re.search(r"\bsetuptools\b", stripped):
            continue
        if UPPER_BOUND.search(stripped):
            continue
        found.append(f"{rel}:{number}: {line.strip()}")
    return found


@pytest.mark.parametrize("rel", ("tari.bash", "dgpy_install.sh"))
def test_no_unbounded_setuptools_install(rel):
    """Every install of setuptools carries an upper bound.

    `-U "setuptools>=64"` is the exact form that broke a clean machine: `-U`
    means "newest that satisfies", and with no ceiling the newest was 84.
    """
    found = unbounded_setuptools_installs(rel, read(rel))
    assert not found, (
        "setuptools installed with no upper bound; apt's colcon-core on this "
        "distribution declares setuptools<80:\n" + "\n".join(found)
    )


def test_the_bound_check_catches_the_original_form():
    """Guards the check above against degrading into one that passes all."""
    bad = 'sudo "$PY" -m pip install -q -U "setuptools>=64" wheel\n'
    assert unbounded_setuptools_installs("fake.sh", bad)
    good = 'sudo "$PY" -m pip install -q "setuptools>=64,<80" wheel\n'
    assert not unbounded_setuptools_installs("fake.sh", good)
    # setuptools_scm alone is not the capped distribution.
    scm = 'sudo "$PY" -m pip install "setuptools_scm[toml]>=8"\n'
    assert not unbounded_setuptools_installs("fake.sh", scm)
    # And a comment is not a command.
    assert not unbounded_setuptools_installs(
        "fake.sh", "# pip install -U setuptools would be wrong\n"
    )


def ceiling_in(rel):
    match = re.search(r"^SETUPTOOLS_CEILING=(\d+)", read(rel), re.MULTILINE)
    assert match, f"{rel} does not declare SETUPTOOLS_CEILING"
    return int(match.group(1))


def test_both_scripts_declare_the_same_ceiling():
    """One of them reports, the other repairs. A split would be silent.

    tari.bash's prereqs phase says a machine is above the ceiling; the python
    phase, through dgpy_install.sh, pins it back. If the two numbers drifted
    apart the warning and the repair would disagree about what is broken.
    """
    assert ceiling_in("tari.bash") == ceiling_in("dgpy_install.sh")
    assert ceiling_in("tari.bash") == SETUPTOOLS_CEILING, (
        "the ceiling moved; this test and the README's Known limits entry "
        "both name the number and have to move with it"
    )


def test_the_installer_bounds_its_specifier_from_the_declared_ceiling():
    text = read("dgpy_install.sh")
    assert '"setuptools>=$SETUPTOOLS_FLOOR,<$SETUPTOOLS_CEILING"' in text, (
        "the pip specifier no longer derives from SETUPTOOLS_CEILING, so the "
        "declaration and the install can disagree"
    )


def fake_site(tmp_path, setuptools_version, scm_version="8.1.0"):
    """A directory of .dist-info metadata, which is all the probe reads."""
    site_dir = tmp_path / ("site-" + setuptools_version)
    for name, version in (("setuptools", setuptools_version),
                          ("setuptools_scm", scm_version)):
        info = site_dir / ("%s-%s.dist-info" % (name, version))
        info.mkdir(parents=True)
        (info / "METADATA").write_text(
            "Metadata-Version: 2.1\nName: %s\nVersion: %s\n" % (name, version),
            encoding="utf-8",
        )
    return site_dir


@pytest.mark.parametrize("version,expected", [
    ("59.6.0", 1),     # jammy's own: too old, upgrade
    ("70.1.0", 0),     # in the window: leave it alone
    ("84.0.0", 2),     # what `-U "setuptools>=64"` resolved to: too new
])
def test_the_build_prereq_probe_classifies_the_version(tmp_path, version,
                                                       expected):
    """1 means upgrade, 2 means pin back, 0 means do nothing.

    Three distinct answers because the caller says a different thing for each,
    and because 84.0.0 satisfying `>=64` is precisely why the old probe passed
    on a machine that was already broken.
    """
    code = embedded_python(read("dgpy_install.sh"), "ensure_build_prereqs() {")
    env = dict(os.environ)
    env["PYTHONPATH"] = str(fake_site(tmp_path, version))
    result = subprocess.run(
        [sys.executable, "-c", code, "64", "80", "8"],
        capture_output=True, text=True, env=env, cwd=str(tmp_path),
    )
    assert result.returncode == expected, (
        "setuptools %s classified %d, expected %d\n%s"
        % (version, result.returncode, expected, result.stderr)
    )
    # And it says nothing on the way: this runs on every install.
    assert result.stdout == "" and result.stderr == "", result.stderr


def test_the_build_prereq_probe_requires_pkg_resources(tmp_path):
    """A version comparison cannot see files that are gone from disk.

    dpkg reports python3-pkg-resources installed while all 17 of its files are
    missing, on machines where something ran a system-wide pip upgrade of
    setuptools. The probe has to import it.
    """
    code = embedded_python(read("dgpy_install.sh"), "ensure_build_prereqs() {")
    env = dict(os.environ)
    env["PYTHONPATH"] = str(fake_site(tmp_path, "70.1.0"))
    blocker = (
        "import builtins\n"
        "real = builtins.__import__\n"
        "def fake(name, *a, **k):\n"
        "    if name == 'pkg_resources':\n"
        "        raise ImportError('gone')\n"
        "    return real(name, *a, **k)\n"
        "builtins.__import__ = fake\n"
    )
    result = subprocess.run(
        [sys.executable, "-c", blocker + code, "64", "80", "8"],
        capture_output=True, text=True, env=env, cwd=str(tmp_path),
    )
    assert result.returncode == 1, (
        "an in-window setuptools with no pkg_resources was reported as fine; "
        "every package build would then fail on pbr's import of it"
    )


def test_the_prereqs_phase_probes_pkg_resources_directly():
    """Not through whichever tool happens to notice first.

    The old check ran only when `vcs` was both installed AND broken, so a
    machine with no vcstool -- or one where vcs happened to still work --
    reached the python phase and failed five package builds on pbr's
    `import pkg_resources` instead.
    """
    text = read("tari.bash")
    body = text[text.index("ensure_working_vcs() {"):]
    body = body[:body.index("\n}\n")]
    assert "import pkg_resources" in body
    first_probe = body.index("import pkg_resources")
    vcs_probe = body.index("vcs --version")
    assert first_probe < vcs_probe, (
        "pkg_resources is still probed only after vcs, so a machine without "
        "vcstool is never checked"
    )


# ---------------------------------------------------------------------------
# 2. The setup.py (egg-info) install pip refuses to replace.
# ---------------------------------------------------------------------------
def run_detector(code, cwd, argv, prologue=""):
    result = subprocess.run(
        [sys.executable, "-c", prologue + code] + list(argv),
        cwd=str(cwd), capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    return result.stdout


LEGACY_DETECTOR = None


def legacy_detector():
    global LEGACY_DETECTOR
    if LEGACY_DETECTOR is None:
        LEGACY_DETECTOR = embedded_python(read("dgpy_install.sh"),
                                          "legacy_metadata_path() {")
    return LEGACY_DETECTOR


def make_egg_info(site_dir, name, version):
    """What `python3 setup.py install` leaves: metadata with no file list."""
    egg = site_dir / ("%s-%s.egg-info" % (name, version))
    egg.mkdir(parents=True)
    (egg / "PKG-INFO").write_text(
        "Metadata-Version: 1.0\nName: %s\nVersion: %s\n" % (name, version),
        encoding="utf-8",
    )
    (site_dir / name.replace("-", "_")).mkdir(exist_ok=True)
    return egg


def make_dist_info(site_dir, name, version):
    """What pip leaves: metadata WITH a RECORD, which pip can remove itself."""
    info = site_dir / ("%s-%s.dist-info" % (name.replace("-", "_"), version))
    info.mkdir(parents=True)
    (info / "METADATA").write_text(
        "Metadata-Version: 2.1\nName: %s\nVersion: %s\n" % (name, version),
        encoding="utf-8",
    )
    (info / "RECORD").write_text("", encoding="utf-8")
    return info


def test_an_egg_info_install_is_detected(tmp_path):
    site_dir = tmp_path / "site"
    egg = make_egg_info(site_dir, "dgpython_nidaqmx", "0.0.0")
    out = run_detector(
        legacy_detector(), tmp_path, ["dgpython_nidaqmx"],
        prologue="import sys; sys.path.insert(0, %r)\n" % str(site_dir),
    )
    assert out.strip() == str(egg.resolve()), out


def test_a_normal_pip_install_is_not_reported(tmp_path):
    """pip replaces its own installs. Deleting metadata there would be wrong."""
    site_dir = tmp_path / "site"
    make_dist_info(site_dir, "dgpython-nidaqmx", "0.1.dev11")
    out = run_detector(
        legacy_detector(), tmp_path, ["dgpython_nidaqmx"],
        prologue="import sys; sys.path.insert(0, %r)\n" % str(site_dir),
    )
    assert out.strip() == "", out


def test_a_package_that_is_not_installed_is_not_reported(tmp_path):
    out = run_detector(legacy_detector(), tmp_path,
                       ["no-such-distribution-at-all"])
    assert out.strip() == "", out


def test_the_installer_clears_the_metadata_before_installing():
    """Order matters: after the build, before pip.

    Clearing it is pointless if the build failed, and useless after pip has
    already refused.
    """
    text = read("dgpy_install.sh")
    body = text[text.index("install_one() {"):]
    body = body[:body.index("\n}\n")]
    assert "remove_legacy_metadata" in body, (
        "install_one no longer clears a setup.py install, so pip's "
        "uninstall-distutils-installed-package refusal is unrecoverable again"
    )
    assert body.index("remove_legacy_metadata") < body.index('"${cmd[@]}" .')


def test_the_metadata_removal_refuses_an_apt_owned_path():
    """A python3-* deb ships .egg-info directories too."""
    text = read("dgpy_install.sh")
    body = text[text.index("remove_legacy_metadata() {"):]
    body = body[:body.index("\n}\n")]
    assert "dpkg -S" in body, (
        "nothing checks whether the metadata path belongs to a Debian package"
    )
    assert body.index("dpkg -S") < body.index("rm -rf")


# ---------------------------------------------------------------------------
# 3. The pip Qt that has no metadata at all.
# ---------------------------------------------------------------------------
def qt_detector():
    return embedded_python(read("tari.bash"), "warn_about_pip_qt() {")


QT_PROLOGUE = """\
import site
site.getsitepackages = lambda: [%r]
site.getusersitepackages = lambda: ""
"""


def test_an_orphaned_qt_directory_is_reported(tmp_path):
    """The case the distribution scan cannot see.

    An interrupted `pip uninstall PyQt5`, or a pip install over an apt copy,
    leaves the package directory with its .dist-info gone. importlib.metadata
    then reports nothing while the directory still precedes apt's on sys.path.
    """
    site_dir = tmp_path / "site"
    (site_dir / "PyQt5").mkdir(parents=True)
    (site_dir / "pyqt5_plugins").mkdir()
    # Not Qt, and must never be named.
    (site_dir / "numpy").mkdir()
    # Qt-named but it IS a metadata directory, not a package.
    (site_dir / "PyQt5-5.15.6.dist-info").mkdir()

    out = run_detector(qt_detector(), tmp_path, [],
                       prologue=QT_PROLOGUE % str(site_dir))
    assert "PyQt5 -- NO metadata" in out, out
    assert "pyqt5_plugins -- NO metadata" in out, out
    assert "sudo rm -rf %s" % (site_dir / "PyQt5") in out, out
    assert "numpy" not in out, out
    assert "dist-info -- NO metadata" not in out, out


def test_an_apt_site_directory_is_never_reported(tmp_path):
    """/usr/lib/python3/dist-packages is the system Qt and is the wanted one."""
    out = run_detector(qt_detector(), tmp_path, [],
                       prologue=QT_PROLOGUE % "/usr/lib/python3/dist-packages")
    for line in out.splitlines():
        assert "/usr/lib/python3/dist-packages" not in line, out


def test_the_qt_warning_names_the_import_symptom():
    """Naming the symptom is what connects the warning to what it prevents."""
    text = read("tari.bash")
    body = text[text.index("warn_about_pip_qt() {"):]
    body = body[:body.index("\n}\n")]
    assert "_ZdaPvm" in body, (
        "the warning no longer names the undefined-symbol ImportError it "
        "predicts, which is the only thing that ties it to 'import "
        "spatialnde2' failing"
    )
    assert "pip uninstall" in body and "rm -rf" in body, (
        "both removal forms must be printed: pip cannot remove a directory "
        "it has no record of"
    )
