"""The `sources` phase: throttled, retried, resumable, and fast-forwarding.

A clean-machine bootstrap failed here in a way nothing could recover from. The
fetch ran `vcs import`, which clones its repositories concurrently; github
throttled the connections and eight of hw.repos' nine failed at once with

    kex_exchange_identification: read: Connection reset by peer
    Connection reset by 140.82.112.3 port 22
    fatal: Could not read from remote repository.

Re-running did not help, because every repository was attempted again at the
same concurrency -- and because `vcs import` never fast-forwards a checkout it
already finds, a repository that DID clone, months ago, stays silently at an
old commit.

Everything here runs against git repositories created in a temporary directory.
No network, no ROS, nothing installed. The one thing that is stubbed is `git`
itself, in the retry test, so that a transient failure can be made to happen on
demand.

    python3 -m pytest test/test_sources_resume.py
"""

import os
import re
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
        ("git",) + args, cwd=cwd, check=True,
        capture_output=True, text=True,
    ).stdout.strip()


def make_origin(path, branch="iron"):
    """A bare-ish repository that can be cloned from a local path."""
    os.makedirs(path)
    git(path, "init", "--quiet", "--initial-branch", branch)
    git(path, "config", "user.email", "test@example.invalid")
    git(path, "config", "user.name", "Test")
    with open(os.path.join(path, "README"), "w", encoding="utf-8") as handle:
        handle.write("one\n")
    git(path, "add", "README")
    git(path, "commit", "--quiet", "-m", "one")
    return git(path, "rev-parse", "HEAD")


def commit_more(path, text):
    with open(os.path.join(path, "README"), "a", encoding="utf-8") as handle:
        handle.write(text + "\n")
    git(path, "add", "README")
    git(path, "commit", "--quiet", "-m", text)
    return git(path, "rev-parse", "HEAD")


def workspace(tmp_path, repos):
    """A workspace root holding a copy of tari.bash and a container.repos.

    tari.bash takes its ROOT from its own location, so the script has to be
    copied rather than run in place -- otherwise the test would clone into the
    real workspace.

    The `container` layer is used because its chain is exactly one manifest, so
    one file describes the whole fetch.
    """
    root = tmp_path / "ws"
    root.mkdir()
    shutil.copy(TARI, root / "tari.bash")
    lines = ["repositories:"]
    for path, (url, version) in repos.items():
        lines += ["  %s:" % path, "    type: git",
                  "    url: %s" % url, "    version: %s" % version]
    (root / "container.repos").write_text("\n".join(lines) + "\n",
                                          encoding="utf-8")
    return root


def run_sources(root, extra_env=None, expect_ok=True, args=()):
    env = dict(os.environ)
    # No real waiting: the backoff is what is being exercised, not the clock.
    env["TARI_FETCH_BACKOFF"] = "0"
    env.update(extra_env or {})
    result = subprocess.run(
        [str(root / "tari.bash"), "--layer", "container", "--phase", "sources",
         *args],
        cwd=str(root), capture_output=True, text=True, env=env, timeout=300,
    )
    if expect_ok:
        assert result.returncode == 0, result.stdout + result.stderr
    return result


# ---------------------------------------------------------------------------
# 1. Resume. The defect: a failed fetch could not be recovered by re-running.
# ---------------------------------------------------------------------------
def test_a_second_run_refetches_nothing(tmp_path):
    """Everything already at the manifest's version is skipped.

    A repository pinned to a commit it is already sitting on must not be
    contacted at all -- that is what makes a resumed fetch cheap rather than
    merely correct, and it is checked by DELETING THE ORIGIN before the second
    run. If the second run touched the network it could not succeed.
    """
    origin_branch = tmp_path / "origin-branch"
    origin_pinned = tmp_path / "origin-pinned"
    make_origin(str(origin_branch))
    pinned_sha = make_origin(str(origin_pinned))

    root = workspace(tmp_path, {
        "onbranch": (str(origin_branch), "iron"),
        "pinned": (str(origin_pinned), pinned_sha),
    })

    first = run_sources(root)
    assert "onbranch cloned at iron" in first.stdout, first.stdout
    assert "pinned cloned at %s" % pinned_sha in first.stdout, first.stdout
    assert (root / "onbranch" / ".git").is_dir()
    assert (root / "pinned" / ".git").is_dir()

    # The pinned repository's origin is now gone. A fetch would fail.
    shutil.rmtree(str(origin_pinned))

    second = run_sources(root)
    assert "pinned at %s already" % pinned_sha in second.stdout, second.stdout
    assert "0 cloned, 0 updated, 2 already current" in second.stdout, second.stdout


def test_a_failed_clone_leaves_nothing_behind_and_the_rerun_succeeds(tmp_path):
    """The empty-directory trap, which cost the python phase four packages.

    `vcs import` created the target directory and then failed to clone into it,
    so dgpy_install.sh found a directory with no setup.py and reported

        ERROR: Directory '.' is not installable. Neither 'setup.py' nor
        'pyproject.toml' found.

    for dgpython-azurekinect, dgpython_nidaqmx, dgpython_uniwest and
    dgpython_opencv_camera. A clone that fails must leave the path absent.
    """
    good = tmp_path / "origin-good"
    make_origin(str(good))
    missing = tmp_path / "origin-missing"          # never created

    root = workspace(tmp_path, {
        "good": (str(good), "iron"),
        "bad": (str(missing), "iron"),
    })

    first = run_sources(root, expect_ok=False)
    assert first.returncode != 0
    assert (root / "good" / ".git").is_dir(), "a sibling failure stopped the loop"
    assert not (root / "bad").exists(), "a failed clone left a directory behind"
    assert not list(root.glob("*.tari-incoming")), "staging directory left behind"
    # And the recovery is named, because with vcs import it was not available.
    assert "RUN THIS PHASE AGAIN" in first.stdout + first.stderr

    # Now the repository appears. The re-run fetches only it.
    make_origin(str(missing))
    second = run_sources(root)
    assert "bad cloned at iron" in second.stdout, second.stdout
    assert "good at iron already" in second.stdout, second.stdout


# ---------------------------------------------------------------------------
# 2. Fast-forward. The defect `vcs import` has and cannot be told about.
# ---------------------------------------------------------------------------
def test_an_existing_branch_checkout_is_fast_forwarded(tmp_path):
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)
    before = git(str(root / "repo"), "rev-parse", "HEAD")

    moved = commit_more(str(origin), "two")
    assert moved != before

    second = run_sources(root)
    assert "fast-forwarded" in second.stdout, second.stdout
    assert git(str(root / "repo"), "rev-parse", "HEAD") == moved, (
        "the checkout stayed at the old commit -- this is the vcs import defect"
    )


def test_a_diverged_branch_is_refused_not_reset(tmp_path):
    """--ff-only, so local work is never silently discarded.

    Several of these checkouts carry work in progress at any given time, which
    is why the fix for a stale tree cannot be `git reset --hard`.
    """
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)

    local = str(root / "repo")
    git(local, "config", "user.email", "test@example.invalid")
    git(local, "config", "user.name", "Test")
    mine = commit_more(local, "local work")
    commit_more(str(origin), "upstream work")

    second = run_sources(root)
    assert "diverged" in second.stdout + second.stderr
    assert git(local, "rev-parse", "HEAD") == mine, "local commit was discarded"


def test_an_uncommitted_change_is_not_fetched_over(tmp_path):
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)

    with open(str(root / "repo" / "README"), "a", encoding="utf-8") as handle:
        handle.write("work in progress\n")
    commit_more(str(origin), "two")

    second = run_sources(root)
    assert "uncommitted changes" in second.stdout + second.stderr
    assert "work in progress" in (root / "repo" / "README").read_text()


def test_a_foreign_origin_is_reported_and_left_alone(tmp_path):
    """Never change a remote. The manifests' remotes are correct as written."""
    origin = tmp_path / "origin"
    other = tmp_path / "other"
    make_origin(str(origin))
    make_origin(str(other))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)
    git(str(root / "repo"), "remote", "set-url", "origin", str(other))

    second = run_sources(root)
    assert "does not move a remote" in second.stdout + second.stderr
    assert git(str(root / "repo"), "remote", "get-url", "origin") == str(other)


# ---------------------------------------------------------------------------
# 3. Retry, with the exact failure text github produced.
# ---------------------------------------------------------------------------
# Verbatim from the clean-machine log, including the two misleading closing
# lines -- a credential failure ends with exactly the same ones, which is why
# the classification cannot be made on them.
GITHUB_THROTTLE = [
    "kex_exchange_identification: read: Connection reset by peer",
    "Connection reset by 140.82.112.3 port 22",
    "fatal: Could not read from remote repository.",
    "",
    "Please make sure you have the correct access rights",
    "and the repository exists.",
]

CREDENTIAL_FAILURE = [
    "git@github.com: Permission denied (publickey).",
    "fatal: Could not read from remote repository.",
    "",
    "Please make sure you have the correct access rights",
    "and the repository exists.",
]


def failing_clone_stub(counter, message, fail_times=None):
    """A `git` that fails `clone` with `message`, counting its attempts.

    No heredoc: the stub is written through textwrap.dedent and a heredoc
    delimiter cannot survive being indented.
    """
    emit = "\n".join('    echo %s >&2' % shell_quote(line) for line in message)
    gate = ("    if [[ $n -lt %d ]]; then\n" % fail_times) if fail_times else ""
    close = "    fi\n" if fail_times else ""
    body = emit + "\n" + "    exit 128\n"
    if fail_times:
        body = gate + "\n".join("    " + line for line in body.splitlines()) \
               + "\n" + close
    return (
        "#!/bin/bash\n"
        'if [[ "$1" == clone ]]; then\n'
        '    n=$(cat %s 2>/dev/null || echo 0)\n'
        '    echo $((n + 1)) > %s\n'
        % (shell_quote(str(counter)), shell_quote(str(counter)))
        + body
        + "fi\n"
        'exec @REALGIT@ "$@"\n'
    )


def shell_quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


def stub_git(tmp_path, script):
    """A `git` earlier on PATH than the real one, plus that PATH."""
    bindir = tmp_path / "stubbin"
    bindir.mkdir()
    real = shutil.which("git")
    path = bindir / "git"
    path.write_text(script.replace("@REALGIT@", real), encoding="utf-8")
    path.chmod(0o755)
    return str(bindir) + os.pathsep + os.environ["PATH"]


def test_a_transient_clone_failure_is_retried(tmp_path):
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    counter = tmp_path / "attempts"

    # Fail the first two clones the way github's connection throttle does,
    # then get out of the way.
    path = stub_git(tmp_path,
                    failing_clone_stub(counter, GITHUB_THROTTLE, fail_times=2))

    result = run_sources(root, {"PATH": path})
    assert int(counter.read_text()) == 3, "did not retry exactly twice"
    assert "transient" in result.stdout + result.stderr
    assert "repo cloned at iron" in result.stdout, result.stdout
    assert (root / "repo" / ".git").is_dir()


def test_a_credential_failure_is_not_retried(tmp_path):
    """`Permission denied (publickey)` is an answer, not a dropped connection.

    Retrying it would turn a clear error into a long pause and then the same
    clear error.
    """
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    counter = tmp_path / "attempts"

    path = stub_git(tmp_path, failing_clone_stub(counter, CREDENTIAL_FAILURE))

    result = run_sources(root, {"PATH": path}, expect_ok=False)
    assert result.returncode != 0
    assert int(counter.read_text()) == 1, (
        "a credential failure was retried; it must fail immediately. Both "
        "failures end with 'Could not read from remote repository', so the "
        "classification has to be made on the specific line."
    )


def test_the_retry_budget_is_bounded(tmp_path):
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    counter = tmp_path / "attempts"

    path = stub_git(tmp_path, failing_clone_stub(counter, GITHUB_THROTTLE))

    result = run_sources(root, {"PATH": path, "TARI_FETCH_ATTEMPTS": "3"},
                         expect_ok=False)
    assert result.returncode != 0
    assert int(counter.read_text()) == 3, counter.read_text()


# ---------------------------------------------------------------------------
# 4. Static: the concurrency that caused this is gone and must stay gone.
# ---------------------------------------------------------------------------
def code_lines(text):
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        yield number, line


def test_the_fetch_does_not_run_vcs_import():
    """`vcs import` fans out over its repositories; that is the whole defect.

    Mentioning vcstool is fine -- prereqs still installs it and the manifest
    headers document it for use by hand. RUNNING `vcs import` is not.
    """
    text = open(TARI, encoding="utf-8").read()
    offenders = [
        "tari.bash:%d: %s" % (number, line.strip())
        for number, line in code_lines(text)
        if re.search(r"\bvcs\s+import\b", line)
    ]
    assert not offenders, "\n".join(offenders)


def test_the_fetch_loop_is_sequential():
    """No background jobs in the fetch: one connection to github at a time."""
    text = open(TARI, encoding="utf-8").read()
    start = text.index("sync_one_repo() {")
    end = text.index("phase_sources() {")
    offenders = [
        "tari.bash: %s" % line.strip()
        for _number, line in code_lines(text[start:end])
        # A trailing `&` backgrounds; `&&`, `2>&1` and `$(...)` do not.
        if re.search(r"(?<![&>|])&\s*$", line)
    ]
    assert not offenders, "\n".join(offenders)


def test_a_detached_head_with_a_stale_local_branch_is_brought_current(tmp_path):
    """`git checkout iron` prefers a stale LOCAL iron over what was fetched.

    This is how a tree can end up reported as "checked out at iron" while
    sitting months behind it -- the same stale-tree lie as vcs import's, from
    the other direction.
    """
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)

    local = str(root / "repo")
    old = git(local, "rev-parse", "HEAD")
    # A detached HEAD, with the local branch left behind where it was -- which
    # is what an earlier `vcs import` of a pinned version leaves.
    git(local, "checkout", "--quiet", "--detach", old)

    moved = commit_more(str(origin), "two")
    second = run_sources(root)
    assert git(local, "rev-parse", "HEAD") == moved, second.stdout + second.stderr


# ---------------------------------------------------------------------------
# 4. --resync. The defect it answers: "report and leave alone" is right on a
#    development machine and wrong on a cell that just needs to match the
#    manifest -- and the way it is wrong is silent. A manifest that moves a
#    repository to a new url and branch, which is what happens the first time a
#    third-party checkout acquires a local patch and becomes our fork, leaves
#    every existing checkout quietly running the unpatched code.
# ---------------------------------------------------------------------------
def test_resync_moves_a_foreign_origin(tmp_path):
    origin = tmp_path / "origin"
    other = tmp_path / "other"
    make_origin(str(origin))
    make_origin(str(other))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)
    git(str(root / "repo"), "remote", "set-url", "origin", str(other))

    second = run_sources(root, args=("--resync",))
    assert git(str(root / "repo"), "remote", "get-url", "origin") == str(origin)
    assert "force-resynced" in second.stdout + second.stderr \
        or "already" in second.stdout + second.stderr


def test_resync_switches_to_a_branch_that_does_not_exist_locally(tmp_path):
    """The noether case: the manifest changes BOTH the url and the branch.

    Without --resync this is reported twice over -- foreign origin first, and a
    missing branch after -- and the checkout keeps the code it had.
    """
    upstream = tmp_path / "upstream"
    fork = tmp_path / "fork"
    make_origin(str(upstream), branch="master")
    make_origin(str(fork), branch="master")
    git(str(fork), "checkout", "-b", "tari/iron")
    patched = commit_more(str(fork), "our patch")

    root = workspace(tmp_path, {"repo": (str(upstream), "master")})
    run_sources(root)
    assert git(str(root / "repo"), "rev-parse", "HEAD") != patched

    # The manifest now names the fork and its branch.
    manifest = root / "container.repos"
    manifest.write_text(
        "repositories:\n  repo:\n    type: git\n    url: %s\n    version: tari/iron\n"
        % (str(fork),), encoding="utf-8")

    second = run_sources(root, args=("--resync",))
    assert git(str(root / "repo"), "rev-parse", "HEAD") == patched, \
        "the checkout did not reach the fork's patched branch"
    assert git(str(root / "repo"), "remote", "get-url", "origin") == str(fork)
    assert "force-resynced" in second.stdout + second.stderr


def test_resync_resets_a_diverged_branch_and_names_what_it_discarded(tmp_path):
    """A discarded commit must be printed, because it is recoverable by hash."""
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)

    local = str(root / "repo")
    git(local, "config", "user.email", "test@example.invalid")
    git(local, "config", "user.name", "Test")
    mine = commit_more(local, "local work")
    theirs = commit_more(str(origin), "upstream work")

    second = run_sources(root, args=("--resync",))
    out = second.stdout + second.stderr
    assert git(local, "rev-parse", "HEAD") == theirs
    assert "DISCARDING" in out
    assert mine[:7] in out, "the discarded commit's hash was not printed"
    assert "reflog" in out, "nothing told the operator how to get it back"
    # And it really is recoverable, which is what makes printing it worth it.
    assert mine in git(local, "reflog", "--format=%H")


def test_resync_alone_refuses_to_discard_uncommitted_work(tmp_path):
    """THE ONE ASYMMETRY. A commit survives in the reflog; an edit does not.

    So --resync overrides a moved remote and a diverged branch, and stops at an
    uncommitted change until it is told otherwise in as many words.
    """
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)
    with open(str(root / "repo" / "README"), "a", encoding="utf-8") as handle:
        handle.write("work in progress\n")
    commit_more(str(origin), "two")

    second = run_sources(root, args=("--resync",))
    out = second.stdout + second.stderr
    assert "uncommitted changes" in out
    assert "does NOT discard" in out
    assert "--discard-local-changes" in out, "it did not say what would"
    assert "work in progress" in (root / "repo" / "README").read_text()


def test_discard_local_changes_does_discard_them(tmp_path):
    """...with --yes. A REAL edit takes both flags; see test_line_endings.py.

    The second flag was added after the first cell run, where 224 line-ending
    diffs and whatever real edits were among them were discarded together
    because nothing distinguished them.
    """
    origin = tmp_path / "origin"
    make_origin(str(origin))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)
    with open(str(root / "repo" / "README"), "a", encoding="utf-8") as handle:
        handle.write("work in progress\n")
    (root / "repo" / "untracked.txt").write_text("junk", encoding="utf-8")
    theirs = commit_more(str(origin), "two")

    refused = run_sources(root, args=("--resync", "--discard-local-changes"))
    out = refused.stdout + refused.stderr
    assert "REAL content changes" in out
    assert "--yes" in out, "it did not say what would discard them"
    assert "work in progress" in (root / "repo" / "README").read_text()

    second = run_sources(root,
                         args=("--resync", "--discard-local-changes", "--yes"))
    out = second.stdout + second.stderr
    assert "DISCARDING real uncommitted changes" in out
    assert "work in progress" not in (root / "repo" / "README").read_text()
    assert not (root / "repo" / "untracked.txt").exists()
    assert git(str(root / "repo"), "rev-parse", "HEAD") == theirs


def test_discard_local_changes_implies_resync(tmp_path):
    """Discarding edits to leave the checkout where it was makes no sense."""
    origin = tmp_path / "origin"
    other = tmp_path / "other"
    make_origin(str(origin))
    make_origin(str(other))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)
    git(str(root / "repo"), "remote", "set-url", "origin", str(other))

    run_sources(root, args=("--discard-local-changes",))
    assert git(str(root / "repo"), "remote", "get-url", "origin") == str(origin)


def test_without_resync_a_left_alone_repo_is_summarised_loudly(tmp_path):
    """The silence is the fault. A skipped repository must not read as success."""
    origin = tmp_path / "origin"
    other = tmp_path / "other"
    make_origin(str(origin))
    make_origin(str(other))
    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)
    git(str(root / "repo"), "remote", "set-url", "origin", str(other))

    second = run_sources(root)
    out = second.stdout + second.stderr
    assert "LEFT ALONE" in out
    assert "--resync" in out, "the summary did not say what would fix it"


# ---------------------------------------------------------------------------
# 6. A submodule pointer, which `reset --hard` does not fix.
#
# The cell log shows moveit_task_constructor reported as having uncommitted
# changes, discarded under --discard-local-changes, and then reported again
# with the same single entry on the very next invocation:
#
#     warning: ros_ws/src/moveit_task_constructor: DISCARDING uncommitted
#              changes --
#           M core/python/pybind11
#
# That is a submodule whose HEAD is not the commit the superproject records,
# and `git reset --hard` does not recurse into one -- measured: the pointer is
# still dirty immediately after the reset, and `git submodule update --init
# --recursive` is what clears it. So the old code could never finish: it warned
# about "uncommitted changes" that were not changes, every run, for ever.
# ---------------------------------------------------------------------------
def make_origin_with_submodule(path, inner, branch="iron"):
    """An origin carrying a submodule, plus the submodule's two commits."""
    make_origin(inner, branch=branch)
    first = git(inner, "rev-parse", "HEAD")
    second = commit_more(inner, "inner two")

    make_origin(path, branch=branch)
    git(path, "-c", "protocol.file.allow=always",
        "submodule", "add", "--quiet", inner, "sub")
    git(path, "commit", "--quiet", "-m", "add sub")
    return first, second


def test_a_submodule_pointer_is_named_as_one_and_is_actually_repaired(tmp_path):
    inner = tmp_path / "inner"
    origin = tmp_path / "origin"
    old, _current = make_origin_with_submodule(str(origin), str(inner))

    root = workspace(tmp_path, {"repo": (str(origin), "iron")})
    run_sources(root)
    local = str(root / "repo")
    # A clone does not carry the origin's protocol.file.allow, and the
    # submodule's URL here is a local path. Nothing to do with the behaviour
    # under test; the real manifests use https and ssh.
    git(local, "config", "protocol.file.allow", "always")
    git(local, "-c", "protocol.file.allow=always",
        "submodule", "update", "--init", "--quiet")
    git(os.path.join(local, "sub"), "checkout", "--quiet", old)
    assert git(local, "status", "--porcelain"), "bad fixture"

    reported = run_sources(root, args=("--resync",))
    out = reported.stdout + reported.stderr
    # The warning wraps, so match within one of its lines.
    assert "only a submodule pointer" in out, out
    assert "submodule update --init --recursive" in out, "no remedy offered"
    assert "has uncommitted changes" not in out, (
        "a moved submodule pointer is still being called uncommitted changes")

    fixed = run_sources(root, args=("--resync", "--discard-local-changes"))
    out = fixed.stdout + fixed.stderr
    assert "restoring the recorded submodule pointer" in out, out
    assert not git(local, "status", "--porcelain"), (
        "the checkout is still dirty after the discard, so the next run will "
        "report the same pointer again -- which is the defect")
