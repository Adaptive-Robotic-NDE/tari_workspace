"""The compiled extras must build on Linux as well as on Windows.

Two of the workspace's Python distributions are Cython extensions that link
spatialnde2's C++ ABI, and `dgpy_install.sh --with-extras` builds them. A
setup.py written on one platform compiles on that platform and nowhere else,
and the failure is a compiler error a long way from its cause:
`spatialnde2_cpp_calibration_function` passed MSVC's `/Od` to gcc, which reads it
as the name of a source file, and asked the linker for `opencv_core460`, which is
the Windows file-name spelling of a library called `opencv_core` on Linux and
`opencv_calib` rather than `opencv_calib3d` in OpenCV 5.

So the rules these enforce:

  * a compiler flag that only one toolchain understands must sit inside a branch
    that tests for that toolchain;
  * an OpenCV library is never named with its version in it -- the name and the
    include directory come from the system (pkg-config, or OPENCV_DIR on
    Windows), because they differ per platform and per OpenCV major version.

And one test compiles the thing for real, when this machine has what it needs.

Every extra must also say whether a failed build is fatal, because the two here
differ: nothing imports the calibration function except one demo, while
`ec_acquisition.dpi` imports the eddy-current conditioning at its top and will
not load without it.

Run on any host, no ROS needed:

    python3 -m pytest test/
"""

import ast
import os
import re
import shutil
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

INSTALLER = os.path.join(ROOT, "dgpy_install.sh")

#: The calibration extra's directory, as EXTRAS and BUILD_ENV both spell it.
CALIBRATION_EXTRA = "dgpython-opencv-camera/spatialnde2_cpp_calibration_function"

# Flags only Microsoft's compiler and linker accept. gcc and clang do not take a
# `/`-prefixed switch at all: `/Od` is a path, and the error names a missing file
# rather than an unknown option.
MSVC_ONLY = (
    "/Od", "/Ox", "/O1", "/O2", "/Zi", "/GS", "/GR", "/EHsc", "/MD", "/MT",
    "/debug", "/DEBUG", "-debug",
)

# What a branch has to test for, for an MSVC flag inside it to be conditional.
# Covers both spellings this workspace uses: `sys.platform.startswith("win")`
# and a boolean named for the compiler.
PLATFORM_MARKERS = ("win", "msvc", "msc", "nt", "cygwin")

# An OpenCV library name with a version baked into it: opencv_core460,
# opencv_world4100. The version belongs to one installation, and on Linux the
# library has no version in its link name at all.
VERSIONED_OPENCV = re.compile(r"\bopencv_[a-z0-9]*[a-z]\d{2,}\b")

# pkg-config names to try when deciding whether OpenCV is installed here. Same
# list the calibration setup.py uses; kept in step by
# test_the_pkg_config_names_match_the_setup_py below.
OPENCV_PKG_CONFIG_NAMES = ("opencv4", "opencv5", "opencv")


def extras():
    """[(directory, distribution, required|optional)] from dgpy_install.sh.

    Read out of the installer rather than listed here, so an extra added to the
    script is checked without anybody remembering to add it.
    """
    with open(INSTALLER, encoding="utf-8") as handle:
        text = handle.read()
    match = re.search(r"^EXTRAS=\((.*?)^\)", text, re.M | re.S)
    assert match, "dgpy_install.sh has no EXTRAS array"
    found = []
    for line in match.group(1).splitlines():
        line = line.strip().strip('"')
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        found.append(tuple(parts))
    return found


def build_env(directory):
    """The environment assignments dgpy_install.sh's BUILD_ENV gives `directory`.

    Read out of the installer for the same reason `extras()` is: a build here
    that does not use the variables the installer uses is not testing the build
    the installer performs. `spatialnde2_cpp_calibration_function` needs
    SETUPTOOLS_USE_DISTUTILS=stdlib on any machine whose setuptools has
    rewritten its vendored distutils, and without it the compile test below
    fails on Ubuntu 22.04 while the real install succeeds.
    """
    with open(INSTALLER, encoding="utf-8") as handle:
        text = handle.read()
    match = re.search(r"^declare -A BUILD_ENV=\((.*?)^\)", text, re.M | re.S)
    assert match, "dgpy_install.sh has no BUILD_ENV array"
    env = {}
    for line in match.group(1).splitlines():
        line = line.strip()
        entry = re.match(r"^\[(?P<key>[^]]+)\]=\"(?P<value>[^\"]*)\"$", line)
        if not entry or entry.group("key") != directory:
            continue
        for assignment in entry.group("value").split():
            name, _, value = assignment.partition("=")
            env[name] = value
    return env


def build_env_for_this_interpreter(directory):
    """build_env(), minus anything this interpreter cannot honour.

    The one such variable is SETUPTOOLS_USE_DISTUTILS=stdlib, which selects the
    standard library's distutils -- removed in Python 3.12, where setting it
    stops setuptools loading its own build backend at all. dgpy_install.sh drops
    it on such an interpreter (see interpreter_has_stdlib_distutils there), and
    this has to make the same decision or the test builds with an environment
    the installer would never use.
    """
    env = build_env(directory)
    if sys.version_info >= (3, 12):
        env.pop("SETUPTOOLS_USE_DISTUTILS", None)
    return env


def setup_py_paths():
    """The setup.py of every extra whose source is checked out here."""
    out = []
    for entry in extras():
        path = os.path.join(ROOT, entry[0], "setup.py")
        if os.path.exists(path):
            out.append(path)
    return out


SETUP_PY = setup_py_paths()


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def platform_guarded_ranges(text):
    """Line ranges of every `if`/`elif` body that tests for a platform.

    Anything lexically inside one of these is conditional on the platform, which
    is what makes a toolchain-specific flag acceptable.
    """
    ranges = []
    tree = ast.parse(text)
    for node in ast.walk(tree):
        if not isinstance(node, ast.If):
            continue
        test = ast.dump(node.test).lower()
        if not any(marker in test for marker in PLATFORM_MARKERS):
            continue
        for body in (node.body, node.orelse):
            for statement in body:
                end = getattr(statement, "end_lineno", statement.lineno)
                ranges.append((statement.lineno, end))
    return ranges


def prose_lines(tree):
    """Line numbers occupied by docstrings.

    A docstring is prose, like a comment: it explains the rules and names the
    very spellings they forbid. Comments never reach the AST at all, so only
    docstrings have to be excluded explicitly.
    """
    lines = set()
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef,
                                 ast.ClassDef)):
            continue
        body = getattr(node, "body", None)
        if not body:
            continue
        first = body[0]
        if (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
                and isinstance(first.value.value, str)):
            lines.update(range(first.lineno,
                               getattr(first, "end_lineno", first.lineno) + 1))
    return lines


def code_string_constants(text):
    """(line, value) for every string literal that is not a docstring."""
    tree = ast.parse(text)
    prose = prose_lines(tree)
    for node in ast.walk(tree):
        if not isinstance(node, ast.Constant) or not isinstance(node.value, str):
            continue
        if node.lineno in prose:
            continue
        yield node.lineno, node.value


def unconditional_msvc_flags(text):
    """Every MSVC-only flag that is not inside a platform branch.

    String constants only: the same tokens appear in comments and in diagnostic
    messages explaining the rule, and those are not flags.
    """
    guarded = platform_guarded_ranges(text)
    found = []
    for lineno, value in code_string_constants(text):
        if value.strip() not in MSVC_ONLY:
            continue
        if any(low <= lineno <= high for low, high in guarded):
            continue
        found.append((lineno, value))
    return found


def versioned_opencv_names(text):
    """Every version-suffixed OpenCV library name in a string constant."""
    found = []
    for lineno, value in code_string_constants(text):
        for match in VERSIONED_OPENCV.finditer(value):
            found.append((lineno, match.group(0)))
    return found


# ---------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------

def test_the_extras_were_found():
    """A broken reader would make every parametrised test below pass by
    collecting nothing."""
    assert extras(), "no EXTRAS parsed out of dgpy_install.sh"
    assert SETUP_PY, "none of the extras' setup.py files were found"


@pytest.mark.parametrize("path", SETUP_PY, ids=lambda p: os.path.basename(
    os.path.dirname(p)))
def test_no_unconditional_msvc_only_flag(path):
    found = unconditional_msvc_flags(read(path))
    assert not found, (
        "%s passes a Microsoft-only compiler or linker flag on every platform. "
        "gcc reads a /-prefixed switch as a file name, so the build fails with "
        "an error about a missing source file. Put it inside a branch that "
        "tests sys.platform or the compiler:\n%s"
        % (os.path.relpath(path, ROOT),
           "\n".join("  line %d: %r" % f for f in found)))


@pytest.mark.parametrize("path", SETUP_PY, ids=lambda p: os.path.basename(
    os.path.dirname(p)))
def test_no_version_suffixed_opencv_library_name(path):
    found = versioned_opencv_names(read(path))
    assert not found, (
        "%s names an OpenCV library with a version in it. That spelling exists "
        "only in a Windows build's file names; on Linux the link name carries "
        "no version, and the calibration routines moved from opencv_calib3d to "
        "opencv_calib in OpenCV 5. Ask the system instead -- pkg-config, or "
        "OPENCV_DIR on Windows:\n%s"
        % (os.path.relpath(path, ROOT),
           "\n".join("  line %d: %s" % f for f in found)))


def test_the_checks_above_actually_catch_something():
    """A guard that passes everything is not a guard. Each snippet below is the
    form the rules forbid, taken from the code as it was."""
    original = (
        "extra_compile_args = ['/Od', '/Zi', '/GS'] + definitions\n"
        "extra_link_args = ['-debug'] + explicit\n"
        "libs.append('opencv_core460')\n"
        "libs.append('opencv_calib3d460')\n"
    )
    flags = [flag for _line, flag in unconditional_msvc_flags(original)]
    assert set(flags) == {"/Od", "/Zi", "/GS", "-debug"}, flags
    names = [name for _line, name in versioned_opencv_names(original)]
    assert names == ["opencv_core460", "opencv_calib3d460"], names

    # ... and the same flags inside a platform branch are fine, in both of the
    # spellings this workspace uses.
    for guard in ('if sys.platform.startswith("win"):', "if msvc:"):
        conditional = guard + "\n    args = ['/Od', '/Zi']\n"
        assert not unconditional_msvc_flags(conditional), guard

    # A flag named in a comment or in an error message is not a flag.
    assert not unconditional_msvc_flags("# /Od is MSVC's disable-optimisation\n")
    assert not versioned_opencv_names("# never say opencv_core460\n")


def test_the_pkg_config_names_match_the_setup_py():
    """The OpenCV spellings this test looks for must be the ones the build
    actually tries, or the compile test below skips on a machine that could
    have built it."""
    text = read(os.path.join(
        ROOT, "dgpython-opencv-camera/spatialnde2_cpp_calibration_function/setup.py"))
    match = re.search(r"OPENCV_PKG_CONFIG_NAMES\s*=\s*\(([^)]*)\)", text)
    assert match, "the calibration setup.py no longer lists pkg-config names"
    names = tuple(re.findall(r'"([^"]+)"', match.group(1)))
    assert names == OPENCV_PKG_CONFIG_NAMES, (
        "setup.py tries %s, this test looks for %s" % (names,
                                                       OPENCV_PKG_CONFIG_NAMES))


# ---------------------------------------------------------------------------
# Whether a failed extra is fatal
# ---------------------------------------------------------------------------

def test_every_extra_says_whether_it_is_required():
    """`dgpy_install.sh` treats a required extra's failure as fatal and an
    optional one's as a warning, so an entry that says neither would silently
    take the fatal path and stop a bootstrap for something nothing needs."""
    for entry in extras():
        assert len(entry) == 3, (
            "EXTRAS entry %r must be <directory>|<distribution>|required|optional"
            % ("|".join(entry),))
        assert entry[2] in ("required", "optional"), (
            "EXTRAS entry %r: third field is %r, expected required or optional"
            % ("|".join(entry), entry[2]))


def test_the_installer_distinguishes_required_from_optional():
    """Both words have to actually decide something, and the distinct exit
    status has to exist -- otherwise the third field is decoration."""
    text = read(INSTALLER)
    assert "EXIT_OPTIONAL_EXTRA_FAILED" in text, (
        "dgpy_install.sh defines no separate exit status for a failed optional "
        "extra, so a caller cannot tell it from a failed install")
    assert "optional_failed" in text, (
        "dgpy_install.sh collects every failed extra into one list, so one "
        "optional extra stops the whole python phase")
    # And the reason for each word is written down where the list is.
    preamble = text[:text.index("EXTRAS=(")]
    block = []
    for line in reversed(preamble.splitlines()):
        if not line.startswith("#"):
            break
        block.append(line)
    block = "\n".join(block)
    for word in ("required", "optional"):
        assert word in block, (
            "the comment block above EXTRAS does not explain what %r costs" % word)


def test_the_python_phase_survives_an_optional_extra():
    """tari.bash must not fail its python phase for an optional extra, or the
    distinction the installer draws has no effect on a bootstrap."""
    path = os.path.join(ROOT, "tari.bash")
    if not os.path.exists(path):
        pytest.skip("tari.bash is not checked out")
    text = read(path)
    match = re.search(r"^phase_python\(\)\s*\{(.*?)^\}", text, re.M | re.S)
    assert match, "tari.bash has no phase_python"
    body = match.group(1)
    assert "dgpy_install.sh" in body, "phase_python no longer runs the installer"
    assert re.search(r"rc\s*-eq\s*2|rc\s*==\s*2|\b2\)", body), (
        "phase_python treats every non-zero exit from dgpy_install.sh as a "
        "failure, so an optional extra that cannot build on this machine makes "
        "the phase impossible to complete. Exit status 2 means every package "
        "and every required extra installed.")


# ---------------------------------------------------------------------------
# The real compile
# ---------------------------------------------------------------------------

def test_every_cythonizing_extra_has_its_build_environment():
    """An extra whose setup.py calls cythonize() needs
    SETUPTOOLS_USE_DISTUTILS=stdlib, because `from Cython.Build import cythonize`
    imports numpy.distutils, which patches new_compiler with a signature current
    setuptools no longer has. The failure is a TypeError from inside numpy and
    says nothing about Cython, and it appears only on a machine whose setuptools
    is new enough -- which is why the calibration extra reported itself
    unbuildable on Ubuntu 22.04 after its setup.py had been fixed and proven on
    another host."""
    for entry in extras():
        directory = entry[0]
        setup = os.path.join(ROOT, directory, "setup.py")
        if not os.path.exists(setup):
            continue
        if "cythonize" not in read(setup):
            continue
        env = build_env(directory)
        assert env.get("SETUPTOOLS_USE_DISTUTILS") == "stdlib", (
            "%s/setup.py calls cythonize(), so dgpy_install.sh's BUILD_ENV must "
            "give %r SETUPTOOLS_USE_DISTUTILS=stdlib; it gives %r"
            % (directory, directory, env))


def opencv_is_available():
    """Can this machine compile against OpenCV?"""
    if os.environ.get("SNDE_OPENCV_CFLAGS", "").strip():
        return True
    pkg_config = os.environ.get("PKG_CONFIG", "pkg-config")
    if shutil.which(pkg_config) is None:
        return False
    for name in OPENCV_PKG_CONFIG_NAMES:
        if subprocess.run([pkg_config, "--exists", name]).returncode == 0:
            return True
    return False


def spatialnde2_is_importable():
    return subprocess.run(
        [sys.executable, "-c", "import spatialnde2"],
        cwd="/", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def test_the_calibration_extension_compiles(tmp_path):
    """Build a wheel, which is the only thing that proves the flags are right.

    Nothing is installed: `pip wheel` compiles and writes a .whl. The source is
    copied into a temporary directory first, so the build leaves no build/ tree
    or generated .cpp in the repository.

    Skipped when this machine has no OpenCV development package or no installed
    spatialnde2 -- the extension links both, and a skip is the honest answer
    there. The static tests above run everywhere.
    """
    package = os.path.join(ROOT, CALIBRATION_EXTRA)
    if not os.path.isdir(package):
        pytest.skip("dgpython-opencv-camera is not checked out")
    if not spatialnde2_is_importable():
        pytest.skip("spatialnde2 is not installed for this interpreter")
    if not opencv_is_available():
        pytest.skip("no OpenCV development package on this machine")
    try:
        import Cython  # noqa: F401
    except ImportError:
        pytest.skip("Cython is not installed")

    source = tmp_path / "src"
    shutil.copytree(package, source,
                    ignore=shutil.ignore_patterns("build", "*.egg-info",
                                                  "__pycache__", "*.so"))
    # The same variables the installer sets for this directory, or this builds
    # something the installer does not.
    env = dict(os.environ)
    env.update(build_env_for_this_interpreter(CALIBRATION_EXTRA))
    result = subprocess.run(
        [sys.executable, "-m", "pip", "wheel", "--no-deps",
         "--no-build-isolation", "-w", str(tmp_path / "wheels"), "."],
        cwd=str(source), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env=env)
    output = result.stdout.decode("utf-8", "replace")
    assert result.returncode == 0, output[-8000:]
    assert list((tmp_path / "wheels").glob("*.whl")), output[-2000:]


if __name__ == "__main__":
    sys.exit(pytest.main([os.path.abspath(__file__), "-v"]))
