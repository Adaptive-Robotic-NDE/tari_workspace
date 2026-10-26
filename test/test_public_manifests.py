"""The public manifests say exactly what the private ones say, minus the private.

public/*.repos is what somebody outside the organisation builds from. It is
generated from the manifests in the repository root by
tools/make_public_manifests.py and committed, so a public user can run plain
`vcs import < public/sim.repos` without this repository's tooling.

Generated-and-committed is a drift hazard, so the first test here is the
generator's own --check: if anybody edits a root manifest without regenerating,
the suite fails and says so.

The rest are the properties that make a public manifest usable by a stranger:
no SSH URL (which needs a key), no private repository (which they cannot read),
and no repository silently dropped -- a piece that is deliberately absent must
be commented out WITH ITS REASON, not deleted, so the absence is visible.

Nothing here touches the network. Run on any host:

    python3 -m pytest test/
"""

import os
import re
import subprocess
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PUBLIC = os.path.join(ROOT, "public")
GENERATOR = os.path.join(ROOT, "tools", "make_public_manifests.py")

#: An active (not commented out) url or version line.
ACTIVE_URL = re.compile(r"^\s+url:\s*(\S+)\s*$")
ACTIVE_VER = re.compile(r"^\s+version:\s*(\S+)\s*$")


def manifests():
    return sorted(f for f in os.listdir(ROOT) if f.endswith(".repos"))


def active_urls(path):
    out = []
    for line in open(path):
        if line.lstrip().startswith("#"):
            continue
        m = ACTIVE_URL.match(line)
        if m:
            out.append(m.group(1))
    return out


def test_generator_check_passes():
    """The committed public manifests match what the generator would write."""
    r = subprocess.run([sys.executable, GENERATOR, "--check"],
                       capture_output=True, text=True, cwd=ROOT)
    assert r.returncode == 0, (
        "public/*.repos are out of date with the root manifests.\n"
        "Run tools/make_public_manifests.py and commit the result.\n"
        + r.stdout + r.stderr)


@pytest.mark.parametrize("name", manifests())
def test_public_manifest_exists(name):
    assert os.path.exists(os.path.join(PUBLIC, name)), (
        "no public form of %s; run tools/make_public_manifests.py" % (name,))


@pytest.mark.parametrize("name", manifests())
def test_no_ssh_urls(name):
    """A stranger has no key, so git@github.com: cannot be reached."""
    bad = [u for u in active_urls(os.path.join(PUBLIC, name)) if u.startswith("git@")]
    assert not bad, "%s has SSH URLs a public user cannot clone: %s" % (name, bad)


@pytest.mark.parametrize("name", manifests())
def test_no_private_repositories(name):
    """_staging and _private are not readable without membership."""
    bad = [u for u in active_urls(os.path.join(PUBLIC, name))
           if "_staging" in u or "_private" in u]
    assert not bad, "%s names private repositories: %s" % (name, bad)


@pytest.mark.parametrize("name", manifests())
def test_all_urls_are_https(name):
    bad = [u for u in active_urls(os.path.join(PUBLIC, name))
           if not u.startswith("https://")]
    assert not bad, "%s has non-HTTPS URLs: %s" % (name, bad)


@pytest.mark.parametrize("name", manifests())
def test_nothing_is_silently_dropped(name):
    """Every private entry that is absent publicly is commented out, with a reason.

    The count of active entries plus the count of NOT AVAILABLE blocks has to
    equal the private manifest's entry count. A piece that simply vanished
    would leave a public user with a workspace missing something, and no way to
    know.
    """
    priv = len(active_urls(os.path.join(ROOT, name)))
    pub_text = open(os.path.join(PUBLIC, name)).read()
    pub_active = len(active_urls(os.path.join(PUBLIC, name)))
    withheld = pub_text.count("# NOT AVAILABLE PUBLICLY")
    assert pub_active + withheld == priv, (
        "%s: %d private entries, but %d active + %d withheld publicly. "
        "Something was dropped without a reason." % (name, priv, pub_active, withheld))
    for block in re.findall(r"# NOT AVAILABLE PUBLICLY --.*?\n((?:\s*#.*\n)+)", pub_text):
        assert len(block.strip()) > 40, (
            "%s: a withheld entry has no reason attached" % (name,))


#: The two libraries the whole stack is built on. Publicly they must come from
#: the public repository on master -- never the _staging mirror, and never
#: develop, which is spatialnde2's default branch and is not what is released.
CORE_LIBRARIES = {
    "spatialnde2": ("https://github.com/isuthermography/spatialnde2.git", "master"),
    "dataguzzler-python":
        ("https://github.com/isuthermography/dataguzzler-python.git", "master"),
}


def _entries(path):
    """{name: (url, version)} for the active entries of a manifest."""
    out, name, url, ver = {}, None, None, None
    for line in open(path):
        if line.lstrip().startswith("#"):
            continue
        m = re.match(r"^  (\S[^:]*):\s*$", line)
        if m:
            if name and url:
                out[name.split("/")[-1]] = (url, ver)
            name, url, ver = m.group(1), None, None
            continue
        mu, mv = ACTIVE_URL.match(line), ACTIVE_VER.match(line)
        if mu:
            url = mu.group(1)
        if mv:
            ver = mv.group(1)
    if name and url:
        out[name.split("/")[-1]] = (url, ver)
    return out


@pytest.mark.parametrize("name", manifests())
def test_core_libraries_are_public_and_on_master(name):
    """spatialnde2 and dataguzzler-python: public repo, master branch.

    These are the two libraries everything else is built on, so getting them
    from the wrong place or the wrong branch gives a public user a stack that
    is subtly not the one this workspace is developed against.
    """
    got = _entries(os.path.join(PUBLIC, name))
    for lib, (want_url, want_ver) in CORE_LIBRARIES.items():
        if lib not in got:
            continue
        url, ver = got[lib]
        assert url == want_url, "%s: %s points at %s, want %s" % (name, lib, url, want_url)
        assert ver == want_ver, "%s: %s pinned to %r, want %r" % (name, lib, ver, want_ver)
        assert ver != "develop", "%s: %s must not track develop publicly" % (name, lib)


def test_site_layer_is_refused_publicly():
    """Both of site's repositories are private; the layer cannot work."""
    r = subprocess.run(["bash", os.path.join(ROOT, "tari.bash"),
                        "--public", "--layer", "site"],
                       capture_output=True, text=True, cwd=ROOT)
    assert r.returncode != 0, "--public --layer site should refuse"
    assert "not available publicly" in (r.stdout + r.stderr)


def test_public_flag_reads_the_public_directory():
    r = subprocess.run(["bash", os.path.join(ROOT, "tari.bash"), "--public",
                        "--layer", "sim", "--phase", "sources", "--dry-run"],
                       capture_output=True, text=True, cwd=ROOT)
    assert "importing public/sim.repos" in r.stdout, r.stdout + r.stderr
