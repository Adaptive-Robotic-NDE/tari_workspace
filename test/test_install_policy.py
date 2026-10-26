"""Static checks that the workspace scripts install Python packages one way only.

The rule these enforce: every Python package in this workspace is installed with

    sudo pip install --no-deps --no-build-isolation .

and nothing else. Not editable, not per-user, not without sudo. An editable
install makes what runs depend on the state of a working tree rather than on
something deliberately installed; a per-user install lands in ~/.local, which
precedes the system directories on sys.path and silently shadows the real one.

Nothing here installs anything. The one test that runs dgpy_install.sh for real
does so with a recording stub in place of sudo, so pip is never invoked. Run on
any host, no ROS and no target environment needed:

    python3 -m pytest test/
"""

import os
import re
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

INSTALLER = os.path.join(ROOT, "dgpy_install.sh")

# The exact argv every package install is built from, as it appears in
# dgpy_install.sh. Both the dry-run print and the real invocation expand this
# one array, which is what makes the dry run trustworthy.
REQUIRED_PIP_ARRAY = (
    'PIP_INSTALL=("${SUDO[@]}" "$PY" -m pip install '
    '--no-deps --no-build-isolation)'
)

REQUIRED_FLAGS = ("--no-deps", "--no-build-isolation")

# Every file in the workspace that can install a Python package, or that tells a
# reader how to. Paths are relative to the workspace root; a missing one is
# skipped rather than failing, because the container and ROS-Scanning are
# separate repositories that need not be checked out.
AUDITED = (
    "dgpy_install.sh",
    "tari.bash",
    "bootstrap_workspace.sh",
    "ros2_docker.sh",
    "README.md",
    "container/ros2_docker.sh",
    "container/entrypoint.sh",
    "container/README.md",
    "container/images/ros2-iron-jammy/Dockerfile",
    "container/images/kasm-base/Dockerfile",
    "container/images/kasm-base/install-programs.sh",
    "container/images/kasm-base/entrypoint.sh",
)

# Forms that must never appear in a command, anywhere.
FORBIDDEN = (
    (re.compile(r"pip[0-9]*\s+install\b[^\n]*\s-e\b"), "editable install (-e)"),
    (re.compile(r"\bpip[0-9]*\s+install\b[^\n]*--editable"), "editable install"),
    (re.compile(r"\bpip[0-9]*\s+install\b[^\n]*--user"), "per-user install (--user)"),
    (re.compile(r"\bsetup\.py\b[^\n]*\binstall\b"), "setup.py install"),
    (re.compile(r"\bsetup\.py\b[^\n]*\bdevelop\b"), "setup.py develop"),
)

PIP_INSTALL_RE = re.compile(r"\bpip[0-9]*\s+install\b")

# An image build is already root and has no reason to call sudo, so a Dockerfile
# satisfies the privilege half of the rule by construction -- pip there writes to
# the image's system directories. It must still never be editable or per-user, so
# the file has to say so where somebody would otherwise "fix" it back.
DOCKERFILE_POLICY_MARKER = "Install policy: system-wide, never editable, never --user."


def read(rel):
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        pytest.skip(f"{rel} is not checked out")
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def command_lines(rel, text):
    """The parts of a file that are commands rather than prose.

    Markdown: only what is inside a fenced code block, so that prose saying
    "never use --user" is not mistaken for an instruction to do so.

    Shell and Dockerfile: everything that is neither a comment nor inside a
    quoted string. The quoting matters -- these scripts carry multi-line
    diagnostics that talk about pip, and a message explaining that something is
    refused is not an invocation of it.

    Returns (line number, code, raw) triples, where `code` has comments and
    quoted spans blanked out -- use it to decide whether there is a command here
    -- and `raw` is the line as written, which is what to inspect and report.
    """
    if rel.endswith(".md"):
        out, fenced = [], False
        for number, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("```"):
                fenced = not fenced
                continue
            if fenced:
                out.append((number, line, line))
        return out

    out = []
    in_single = in_double = False
    for number, line in enumerate(text.splitlines(), 1):
        if not (in_single or in_double) and line.lstrip().startswith("#"):
            continue
        kept = []
        index = 0
        while index < len(line):
            char = line[index]
            if char == "\\" and not in_single:
                kept.append(" " if (in_single or in_double) else char)
                index += 2
                kept.append(" ")
                continue
            if char == "'" and not in_double:
                in_single = not in_single
                kept.append(" ")
            elif char == '"' and not in_single:
                in_double = not in_double
                kept.append(" ")
            else:
                kept.append(" " if (in_single or in_double) else char)
            index += 1
        out.append((number, "".join(kept), line))
    return out


def violations(rel, text):
    """Every forbidden install form in a file, as human-readable strings."""
    found = []
    for number, code, raw in command_lines(rel, text):
        for pattern, what in FORBIDDEN:
            if pattern.search(code):
                found.append(f"{rel}:{number}: {what}: {raw.strip()}")
    return found


def unprivileged_pip_installs(rel, text):
    """pip installs that would not run as root.

    A Dockerfile is exempt from needing sudo -- an image build is already root,
    and pip there writes to the image's system directories -- but only if the
    file states that policy, so nobody "fixes" one into --user or -e.
    """
    if os.path.basename(rel).startswith("Dockerfile"):
        if PIP_INSTALL_RE.search(text) and DOCKERFILE_POLICY_MARKER not in text:
            return [f"{rel}: installs with pip but states no install policy"]
        return []
    found = []
    for number, code, raw in command_lines(rel, text):
        if not PIP_INSTALL_RE.search(code):
            continue
        if not ("sudo" in raw or "${SUDO[@]}" in raw or "${PIP_INSTALL" in raw):
            found.append(f"{rel}:{number}: pip install without sudo: {raw.strip()}")
    return found


@pytest.mark.parametrize("rel", AUDITED)
def test_no_forbidden_install_form(rel):
    found = violations(rel, read(rel))
    assert not found, "\n".join(found)


@pytest.mark.parametrize("rel", AUDITED)
def test_every_pip_install_is_privileged(rel):
    found = unprivileged_pip_installs(rel, read(rel))
    assert not found, "\n".join(found)


def test_the_checks_above_actually_catch_something():
    """Guards the two checks against quietly degrading into ones that pass all.

    Every line below is a form the rule forbids, and each must be reported.
    """
    bad = {
        "pip install -e .": "editable install (-e)",
        "pip3 install --editable /src": "editable install",
        "sudo pip install --user foo": "per-user install (--user)",
        "python3 setup.py install": "setup.py install",
        "python3 setup.py develop": "setup.py develop",
    }
    for command, expected in bad.items():
        found = violations("fake.sh", command + "\n")
        assert found, f"not reported at all: {command}"
        assert expected in found[0], f"{command} reported as {found[0]}"

    assert unprivileged_pip_installs("fake.sh", "pip install .\n")
    assert not unprivileged_pip_installs("fake.sh", "sudo pip install .\n")
    # A comment, and a diagnostic that merely mentions pip, are not commands.
    assert not violations("fake.sh", "# pip install -e . would be wrong\n")
    assert not unprivileged_pip_installs(
        "fake.sh", 'die "refusing to pip install a ROS package"\n'
    )
    # A Dockerfile needs no sudo, but does need to say why.
    assert unprivileged_pip_installs("Dockerfile", "RUN pip3 install foo\n")
    assert not unprivileged_pip_installs(
        "Dockerfile", f"# {DOCKERFILE_POLICY_MARKER}\nRUN pip3 install foo\n"
    )


def test_installer_builds_the_one_required_command():
    """dgpy_install.sh has exactly one place that spells out an install."""
    text = read("dgpy_install.sh")
    assert REQUIRED_PIP_ARRAY in text, (
        "dgpy_install.sh no longer builds its install command as:\n  "
        + REQUIRED_PIP_ARRAY
    )
    # And nothing else in the script assembles a second one.
    others = [
        raw for _, code, raw in command_lines("dgpy_install.sh", text)
        if PIP_INSTALL_RE.search(code) and "PIP_INSTALL=" not in code
    ]
    for line in others:
        # The build-tool bootstrap is the one other install: third-party tools,
        # upgraded on purpose, and still under sudo.
        assert "${SUDO[@]}" in line, f"unreviewed install command: {line.strip()}"
        for flag in ("-e", "--editable", "--user"):
            assert f" {flag}" not in line, f"{flag} in: {line.strip()}"


def test_syntax_of_every_shell_script():
    for rel in AUDITED:
        if not rel.endswith((".sh", ".bash")):
            continue
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        assert subprocess.run(["bash", "-n", path]).returncode == 0, f"{rel}"


def parse_dry_run(text):
    """The install commands dgpy_install.sh --dry-run says it would run."""
    pattern = re.compile(r"^\s*\(\s*cd\s+(\S+)\s+&&\s+(.*?)\s*\)\s*$")
    found = []
    for line in text.splitlines():
        match = pattern.match(line)
        if match:
            found.append((match.group(1), match.group(2).split()))
    return found


# When these tests run as root the installer correctly omits the sudo prefix --
# it is already root -- so the two tests that assert on it have nothing to check.
skip_if_root = pytest.mark.skipif(
    os.geteuid() == 0,
    reason="already root, so the sudo prefix is deliberately absent",
)


def strip_env_prefix(argv):
    """argv with a `sudo` and any `env NAME=VALUE ...` prefix removed.

    One package's build needs an environment variable, and sudo runs with
    env_reset, so it is passed as `sudo env NAME=VALUE python3 -m pip ...`. That
    changes nothing about the install -- still system-wide, still no deps, no
    build isolation, still `.` -- so the prefix is allowed and then ignored. What
    follows it must be the one required form, which is what the caller checks.
    """
    rest = list(argv)
    assert rest and rest[0] == "sudo", f"not privileged: {argv}"
    rest = rest[1:]
    if rest and rest[0] == "env":
        rest = rest[1:]
        while rest and re.match(r"^[A-Za-z_][A-Za-z_0-9]*=", rest[0]):
            rest = rest[1:]
        assert rest, f"env prefix with no command: {argv}"
    return rest


def assert_required_form(directory, argv):
    pip = strip_env_prefix(argv)
    # `<interpreter> -m pip`, never bare `pip`: pip has to run under the
    # interpreter the script chose, not whichever one root's PATH finds.
    assert pip[1:4] == ["-m", "pip", "install"], (
        f"pip must be run as a module of the chosen interpreter: {argv}"
    )
    for flag in REQUIRED_FLAGS:
        assert flag in pip, f"{flag} missing from: {argv}"
    assert pip[-1] == ".", f"must install the current directory: {argv}"
    for flag in ("-e", "--editable", "--user"):
        assert flag not in pip, f"{flag} in: {argv}"
    # A package that needs a cmake build is installed from its build directory,
    # which the install creates -- so before the first build that path
    # legitimately does not exist yet. Its parent must, which is what catches a
    # typo or a package that was never checked out.
    assert os.path.isdir(directory) or os.path.isdir(os.path.dirname(directory)), (
        f"would cd into a missing directory: {directory}"
    )


@skip_if_root
def test_dry_run_of_the_extras_prints_the_required_form():
    """The optional Cython extras install the same way as everything else.

    They are not printed by a plain --dry-run, so the test above never sees them,
    and they are where the environment splice is most often needed -- but not the
    only place it is allowed: dgpython-azurekinect is a regular package that also
    has to build with SETUPTOOLS_USE_DISTUTILS=stdlib.
    """
    # --force for the same reason as the two tests below: on a machine where the
    # stack is actually installed and current, a dry run without it prints
    # "X is current" and no command at all, and the assertion below has nothing
    # to look at. The question here is what the command LOOKS like, not whether
    # anything is due.
    result = subprocess.run(
        [INSTALLER, "--with-extras", "--dry-run", "--force"],
        cwd=ROOT, capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    commands = parse_dry_run(result.stdout)
    assert commands, f"--dry-run printed no install commands:\n{result.stdout}"
    for directory, argv in commands:
        assert_required_form(directory, argv)


@skip_if_root
def test_dry_run_prints_the_required_form():
    # --force, or this test asks a question the machine can answer with silence.
    # dgpy_install.sh skips a package whose installed copy already matches the
    # checked-out commit, so on a fully bootstrapped machine a plain --dry-run
    # prints eight "X is current" lines and no install command, and `commands`
    # is empty. That is the state a successful bootstrap LEAVES BEHIND, so the
    # test failed precisely where it should have passed. Measured on a clean
    # jammy bootstrap 2026-09-30.
    result = subprocess.run(
        [INSTALLER, "--dry-run", "--force"], cwd=ROOT, capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    commands = parse_dry_run(result.stdout)
    assert commands, f"--dry-run printed no install commands:\n{result.stdout}"
    for directory, argv in commands:
        assert argv[0] == "sudo", f"not privileged: {argv}"
        # The rest of the required form is one shared assertion, because a
        # regular package may also carry an environment splice -- inlining the
        # argv offsets here instead hard-coded `sudo <python> -m pip` and so
        # failed the moment dgpython-azurekinect needed `sudo env VAR=...`.
        assert_required_form(directory, argv)


@skip_if_root
def test_dry_run_matches_what_is_actually_run(tmp_path):
    """The printed command is the executed command, argument for argument.

    Proved by putting a recording stub on PATH in place of sudo and running a
    real install of one package: the stub logs its working directory and argv and
    exits, so pip is never invoked and nothing is installed.
    """
    package = "dgpython-local"
    log = tmp_path / "invocations"
    stub_dir = tmp_path / "bin"
    stub_dir.mkdir()
    stub = stub_dir / "sudo"
    stub.write_text(
        "#!/bin/sh\n"
        '{ printf "cwd %s\\n" "$PWD"\n'
        '  for arg in "$@"; do printf "arg %s\\n" "$arg"; done\n'
        '  printf "end\\n"; } >> "$SUDO_STUB_LOG"\n'
        "exit 0\n"
    )
    stub.chmod(0o755)

    env = dict(os.environ)
    env["PATH"] = f"{stub_dir}{os.pathsep}{env['PATH']}"
    env["SUDO_STUB_LOG"] = str(log)

    # --force on BOTH sides. Without it the dry run asks a different question
    # from the real one: on a machine where this package is already installed and
    # current the installer prints "dgpython-local is current" and no command at
    # all, so the comparison had nothing to compare and the test failed wherever
    # the stack was actually installed -- which is every machine this is meant to
    # describe.
    dry = subprocess.run(
        [INSTALLER, "--dry-run", "--force", "--only", package],
        cwd=ROOT, capture_output=True, text=True, env=env,
    )
    assert dry.returncode == 0, dry.stderr
    printed = parse_dry_run(dry.stdout)
    assert len(printed) == 1, dry.stdout

    real = subprocess.run(
        [INSTALLER, "--force", "--only", package],
        cwd=ROOT, capture_output=True, text=True, env=env,
    )
    assert real.returncode == 0, real.stderr + real.stdout

    records, current = [], None
    for line in log.read_text().splitlines():
        kind, _, value = line.partition(" ")
        if kind == "cwd":
            current = {"cwd": value, "argv": []}
        elif kind == "arg":
            current["argv"].append(value)
        elif kind == "end":
            records.append(current)

    installs = [r for r in records if "install" in r["argv"]]
    assert len(installs) == 1, f"expected one install, got {records}"

    printed_dir, printed_argv = printed[0]
    assert installs[0]["cwd"] == printed_dir
    # The stub stands in for sudo, so what it saw is the printed argv minus it.
    assert installs[0]["argv"] == printed_argv[1:]


if __name__ == "__main__":
    sys.exit(pytest.main([os.path.abspath(__file__), "-v"]))
