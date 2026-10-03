"""CRLF: 224 files that looked like eleven people's work in progress.

The first run of tari.bash on the cell warned that eleven checkouts under
ros_ws/src had uncommitted changes and printed 224 `M <path>` lines. Every one
of those paths ends in `.py`, across eleven unrelated repositories, including
generated files nobody edits -- test_copyright.py, test_flake8.py,
test_pep257.py, setup.py -- and there is not one .xml, .yaml, .xacro or .cmake
among them. That is not work in progress; it is a mechanical rewrite of one
file type, which is what a Windows SFTP client in automatic/text transfer mode
does to the extensions on its text list. These trees reach the cell by hand
copy from a Windows workstation, so that is the route.

What it cost: the operator could not tell line-ending noise from real edits, so
`--discard-local-changes` was the only way past the warning, and it threw away
both kinds. Every assertion here is about keeping those two things apart.

The mechanism, measured on a scratch repository:

    worktree CRLF, index LF, core.autocrlf unset
    $ git status --porcelain                        M a.py
    $ git diff HEAD --numstat                      2  2  a.py
    $ git diff HEAD --ignore-cr-at-eol --numstat   (nothing at all)

so `--ignore-cr-at-eol --numstat` is the discriminator, and a file that
survives it with a nonzero count is a real change.

Nothing here runs a build, installs anything or touches the network.

    python3 -m pytest test/test_line_endings.py
"""

import os
import shutil
import subprocess

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARI = os.path.join(ROOT, "tari.bash")

pytestmark = pytest.mark.skipif(
    shutil.which("git") is None, reason="git is required"
)


def git(cwd, *args):
    return subprocess.run(
        ("git",) + args, cwd=cwd, check=True, capture_output=True, text=True,
    ).stdout.strip()


# ---------------------------------------------------------------------------
# 1. Nothing in this repository is CRLF, and nothing can become CRLF.
#
# The script itself is the sharpest case: bash does not tolerate CRLF at all.
# `set -euo pipefail\r` is an invalid option and the shell exits before a single
# line of the script has run, so there is no place inside tari.bash where a
# self-check could live -- the guard has to be here and in .gitattributes.
# ---------------------------------------------------------------------------
def tracked_files():
    """Tracked files, plus untracked ones this repository's .gitignore allows.

    --others --exclude-standard is the half that matters in practice: the
    .gitignore here is a whitelist, so a new file is invisible to `git ls-files`
    until it is both written and whitelisted, and a check that only looked at
    tracked files would pass on the very commit that introduces a CRLF file.
    """
    out = subprocess.run(
        ("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"),
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout
    return [p for p in out.split("\0") if p]


def test_no_tracked_file_has_crlf():
    offenders = []
    for rel in tracked_files():
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            continue
        with open(path, "rb") as handle:
            if b"\r\n" in handle.read():
                offenders.append(rel)
    assert not offenders, (
        "CRLF in a tracked file. In a shell script it is fatal before the first "
        "line runs; in a checkout it makes every file read as modified. "
        "Convert with `sed -i 's/\\r$//'` and commit: " + ", ".join(offenders))


def test_gitattributes_pins_the_line_endings():
    """So a checkout on a Windows client cannot reintroduce what 1 forbids.

    Without this the next person with core.autocrlf=true gets a CRLF working
    tree, every file reads as modified, and we are back at 224 diffs.
    """
    path = os.path.join(ROOT, ".gitattributes")
    assert os.path.exists(path), (
        ".gitattributes is missing. `* text=auto eol=lf` is what stops a "
        "checkout under core.autocrlf=true producing a CRLF working tree.")
    text = open(path, encoding="utf-8").read()
    assert "eol=lf" in text, ".gitattributes does not pin eol=lf"
    for ext in (".bash", ".sh", ".repos"):
        assert ext in text, (
            "%s is not named in .gitattributes. The shell scripts and the "
            "manifests are the files where CRLF is fatal rather than untidy."
            % ext)


# ---------------------------------------------------------------------------
# 2. A CRLF manifest still parses.
#
# A .repos edited on Windows arrives with CRLF and possibly a byte-order mark.
# PyYAML copes with both -- \r\n is a YAML line break and the reader consumes
# the BOM, checked against 22.04's python3-yaml 5.4.1 -- so this is a
# regression test rather than a repair: it holds the script to parsing a
# manifest the operator will certainly produce sooner or later. The strip() in
# manifest_entries covers the one case PyYAML would pass through, a stray \r
# inside a scalar, which would otherwise be appended to a branch name and
# produce `no such version 'iron'`.
# ---------------------------------------------------------------------------
def make_origin(path, branch="iron"):
    os.makedirs(path)
    git(path, "init", "--quiet", "--initial-branch", branch)
    git(path, "config", "user.email", "test@example.invalid")
    git(path, "config", "user.name", "Test")
    with open(os.path.join(path, "README"), "w", encoding="utf-8") as handle:
        handle.write("one\n")
    git(path, "add", "README")
    git(path, "commit", "--quiet", "-m", "one")
    return git(path, "rev-parse", "HEAD")


def workspace(tmp_path, repos, newline="\n", bom=False):
    """A workspace root with a copy of tari.bash and a container.repos.

    `newline` is the point of this helper: the same manifest is written with LF
    or CRLF so the two can be compared.
    """
    root = tmp_path / "ws"
    root.mkdir()
    shutil.copy(TARI, root / "tari.bash")
    lines = ["repositories:"]
    for path, (url, version) in repos.items():
        lines += ["  %s:" % path, "    type: git",
                  "    url: %s" % url, "    version: %s" % version]
    text = newline.join(lines) + newline
    if bom:
        text = "﻿" + text
    (root / "container.repos").write_bytes(text.encode("utf-8"))
    return root


def run_sources(root, args=(), expect_ok=True):
    env = dict(os.environ)
    env["TARI_FETCH_BACKOFF"] = "0"
    result = subprocess.run(
        [str(root / "tari.bash"), "--layer", "container", "--phase", "sources",
         *args],
        cwd=str(root), capture_output=True, text=True, env=env, timeout=300,
    )
    if expect_ok:
        assert result.returncode == 0, result.stdout + result.stderr
    return result


def test_a_crlf_manifest_imports(tmp_path):
    origin = tmp_path / "origin"
    head = make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")},
                     newline="\r\n", bom=True)
    assert b"\r\n" in (root / "container.repos").read_bytes(), "bad fixture"

    out = run_sources(root)
    assert "cloned at iron" in out.stdout, out.stdout + out.stderr
    assert git(str(root / "repo"), "rev-parse", "HEAD") == head


def test_a_crlf_manifest_does_not_smuggle_a_cr_into_the_version(tmp_path):
    """The one thing PyYAML would pass through, if it ever did.

    A \\r on the end of `version:` becomes part of the branch name, and the
    failure is `no such version 'iron'` -- which reads as a wrong manifest
    rather than as a line ending.
    """
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")}, newline="\r\n")
    out = run_sources(root)
    assert "no such version" not in (out.stdout + out.stderr)


# ---------------------------------------------------------------------------
# 3. A CRLF working tree is named as line endings, not as work in progress.
# ---------------------------------------------------------------------------
def crlf_the_worktree(repo):
    """Rewrite every tracked file with CRLF, exactly as a text-mode copy does.

    Deliberately NOT `git config core.autocrlf true`: that alone leaves the
    tree clean, because the clean filter converts back on the way to the index.
    What dirties a tree is CRLF on disk with an LF index and no filter
    configured -- which is what arrives over SFTP, and what was measured.
    """
    for name in git(repo, "ls-files").splitlines():
        path = os.path.join(repo, name)
        with open(path, "rb") as handle:
            data = handle.read()
        with open(path, "wb") as handle:
            handle.write(data.replace(b"\n", b"\r\n"))


def test_a_crlf_tree_is_reported_as_line_endings_not_as_uncommitted_work(tmp_path):
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)
    crlf_the_worktree(str(root / "repo"))
    assert git(str(root / "repo"), "status", "--porcelain"), "bad fixture"

    out = run_sources(root, args=("--resync",))
    text = out.stdout + out.stderr
    assert "ONLY in line endings" in text, text
    assert "core.autocrlf false" in text, "it did not say what to fix"
    assert "has uncommitted changes" not in text, (
        "a CRLF tree is still being reported as work in progress, which is the "
        "wording that made --discard-local-changes look like the way forward")


def test_line_ending_dirt_is_discarded_without_the_extra_flag(tmp_path):
    """Cosmetic dirt costs no decision; that is the whole point of the split."""
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)
    crlf_the_worktree(str(root / "repo"))
    theirs = commit_more(str(origin), "two")

    out = run_sources(root, args=("--resync", "--discard-local-changes"))
    text = out.stdout + out.stderr
    assert "discarding LINE-ENDING-ONLY" in text, text
    assert b"\r\n" not in (root / "repo" / "README").read_bytes()
    assert git(str(root / "repo"), "rev-parse", "HEAD") == theirs, (
        "the fetch did not proceed after the cosmetic dirt was cleared")


def commit_more(path, text):
    with open(os.path.join(path, "README"), "a", encoding="utf-8") as handle:
        handle.write(text + "\n")
    git(path, "add", "README")
    git(path, "commit", "--quiet", "-m", text)
    return git(path, "rev-parse", "HEAD")


def test_one_real_edit_among_crlf_noise_still_stops_the_run(tmp_path):
    """THE FAULT, exactly. 224 cosmetic diffs must not carry one real edit away.

    The real edit is in a second file so that the first file's CRLF cannot be
    what the refusal is reacting to.
    """
    origin = tmp_path / "origin"
    make_origin(str(origin))
    with open(str(origin / "other.py"), "w", encoding="utf-8") as handle:
        handle.write("x = 1\n")
    git(str(origin), "add", "other.py")
    git(str(origin), "commit", "--quiet", "-m", "other")

    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)
    crlf_the_worktree(str(root / "repo"))
    with open(str(root / "repo" / "other.py"), "w", encoding="utf-8") as handle:
        handle.write("x = 1\r\nREAL WORK\r\n")
    commit_more(str(origin), "two")

    out = run_sources(root, args=("--resync", "--discard-local-changes"))
    text = out.stdout + out.stderr
    assert "REAL content changes" in text, text
    assert "other.py" in text, "it did not say which file"
    assert "README" not in text.split("REAL content changes", 1)[1], (
        "the CRLF-only file is listed alongside the real edit, which is the "
        "noise the operator could not see through")
    assert "REAL WORK" in (root / "repo" / "other.py").read_text()


def test_the_crlf_fixture_is_a_real_fixture(tmp_path):
    """A guard that passes everything is not a guard.

    Both halves of the discriminator are asserted here against plain git, so a
    future git whose --ignore-cr-at-eol stopped working would be caught rather
    than silently reclassifying everything as cosmetic.
    """
    origin = tmp_path / "origin"
    make_origin(str(origin))
    repo = str(origin)
    crlf_the_worktree(repo)
    assert git(repo, "status", "--porcelain"), "CRLF did not dirty the tree"
    assert git(repo, "diff", "HEAD", "--numstat"), "plain diff saw nothing"
    assert not git(repo, "diff", "HEAD", "--ignore-cr-at-eol", "--numstat"), (
        "--ignore-cr-at-eol reported a difference in a CRLF-only tree")
