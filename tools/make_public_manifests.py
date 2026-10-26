#!/usr/bin/env python3
"""Derive the public workspace manifests from the private ones.

WHY THIS EXISTS. The canonical manifests in the repository root name private
repositories over SSH, which is right for the team and useless to anybody else:
a reader with no account cannot clone even the repositories that ARE public,
because `git@github.com:` needs a key. This writes `public/*.repos`, which
name the public mirrors over HTTPS and need no credentials at all.

ONE SOURCE OF TRUTH. The root manifests are it. These outputs are generated and
committed so that a public user can run plain `vcs import < public/sim.repos`
without this script or any other tooling, exactly as the manifest headers have
always documented. `--check` fails if the committed outputs have drifted, which
is what the test suite runs.

HOW IT TRANSFORMS. Line by line, so every comment in the source manifest
survives into the public one -- those comments are most of the value of these
files, and regenerating from parsed YAML would throw them all away.

  * `git@github.com:ORG/NAME<suffix>.git` -> `https://github.com/ORG/NAME.git`
    where the suffix is `_staging`, the private side of the mirror pipeline;
    dropping it is the same rule the publish workflow uses to find its
    destination.
  * `git@github.com:ORG/NAME.git` -> `https://github.com/ORG/NAME.git`
    Already public; it only needs a scheme a stranger can use.
  * `https://...` -> unchanged. Third-party upstreams.
  * A repository with NO public counterpart is COMMENTED OUT rather than
    deleted, with the reason. A public reader then learns that the piece exists
    and why they cannot have it, instead of silently getting a workspace that
    is missing something and not knowing it.
  * `version:` is mapped where the public branch is named differently.

WHAT IT REFUSES. An entry it cannot classify. A new private repository added to
a manifest without a line in NO_PUBLIC_COUNTERPART below is an error, not a
guess -- the failure mode of guessing is publishing a manifest that points at a
repository that does not exist, or worse, silently dropping a dependency.
"""

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTDIR = os.path.join(ROOT, "public")

#: Private repositories with no public mirror, and why. An entry here is
#: commented out of the public manifest with its reason attached.
NO_PUBLIC_COUNTERPART = {
    "Adaptive-Robotic-NDE/csf_loader_private":
        "restricted loader; not ours to redistribute",
    "Adaptive-Robotic-NDE/dgpython-uniwest_private":
        "vendor instrument driver; not ours to redistribute",
}

#: Private repositories that are REPLACED publicly by something else, rather
#: than withheld: {private owner/name: (public owner/name, version, path, why)}.
#: The site layer is the case this exists for. A real site layer describes one
#: physical cell and cannot be published, but a reader who gets nothing there
#: has no idea what belongs in it -- so the public manifest imports a worked
#: example in its place.
PUBLIC_SUBSTITUTE = {
    "Adaptive-Robotic-NDE/tari_site_private": (
        "Adaptive-Robotic-NDE/site_example",
        "iron",
        "ros_ws/src/site_example",
        "a real site layer describes one physical cell -- its arm's measured "
        "kinematics, the geometry around it, where each sensor sits -- so it "
        "cannot be published. This is a worked EXAMPLE in its place, with every "
        "installation-specific value replaced by a documented nominal and an "
        "instruction for measuring the real one. Read its README before "
        "pointing it at hardware.",
    ),
}

#: (public repo, private version) -> public version, where the branch is named
#: differently on the public side. Anything not listed keeps its version.
VERSION_MAP = {
    # The forks carry local work on tari/iron and publish it as iron.
    ("Adaptive-Robotic-NDE/noether", "tari/iron"): "iron",
    ("Adaptive-Robotic-NDE/moveit_task_constructor", "tari/iron"): "iron",
    ("Adaptive-Robotic-NDE/yolo_ros", "tari/iron"): "iron",
    ("Adaptive-Robotic-NDE/industrial_reconstruction", "tari/iron"): "iron",
    # The workspace tracks a spatialnde2 feature branch that is not published.
    # The public manifest tracks master instead, so a public build does NOT get
    # the fixes on that branch. See PINNED_ELSEWHERE below -- this is reported
    # on every run rather than applied quietly.
    ("isuthermography/spatialnde2", "bug_timedtransactionrace"): "master",
}

#: Entries whose public version differs for a reason a reader must be told
#: about, keyed the same way as VERSION_MAP.
PINNED_ELSEWHERE = {
    ("isuthermography/spatialnde2", "bug_timedtransactionrace"):
        "the workspace tracks the feature branch bug_timedtransactionrace, "
        "which is not published; the public manifest tracks master, so a "
        "public build does not include the fixes on that branch",
}

SSH_RE = re.compile(r"^git@github\.com:(?P<owner>[^/]+)/(?P<name>[^/\s]+?)(?:\.git)?$")
URL_LINE = re.compile(r"^(?P<indent>\s*)url:\s*(?P<url>\S+)\s*$")
VER_LINE = re.compile(r"^(?P<indent>\s*)version:\s*(?P<ver>\S+)\s*$")
ENTRY_LINE = re.compile(r"^  (?!#)(?P<path>\S[^:]*):\s*$")


class Unmappable(Exception):
    pass


def public_repo(url):
    """-> 'owner/name' of the public counterpart, or None if there is none."""
    m = SSH_RE.match(url)
    if not m:
        if url.startswith("https://github.com/"):
            return url[len("https://github.com/"):].removesuffix(".git")
        raise Unmappable("unrecognised URL %r" % (url,))
    owner, name = m.group("owner"), m.group("name")
    full = "%s/%s" % (owner, name)
    if full in NO_PUBLIC_COUNTERPART:
        return None
    if name.endswith("_private"):
        raise Unmappable(
            "%s is private and has no entry in NO_PUBLIC_COUNTERPART. Add one "
            "saying why it cannot be published, or point it at a mirror." % (full,))
    return "%s/%s" % (owner, name.removesuffix("_staging"))


def transform(text, source_name, notes):
    out = []
    lines = text.splitlines()
    i = 0
    # Everything above `repositories:` is the header; the generated banner goes
    # right after the first line so the file still opens with its own title.
    while i < len(lines):
        line = lines[i]
        m = ENTRY_LINE.match(line)
        if not m:
            out.append(line)
            i += 1
            continue

        # Collect this repository's block: the key line plus its indented body.
        block = [line]
        j = i + 1
        while j < len(lines) and (lines[j].startswith("    ")
                                  or not lines[j].strip()):
            if not lines[j].strip() and j + 1 < len(lines) \
                    and not lines[j + 1].startswith("    "):
                break
            block.append(lines[j])
            j += 1

        url = ver = None
        for b in block:
            um = URL_LINE.match(b)
            if um:
                url = um.group("url")
            vm = VER_LINE.match(b)
            if vm:
                ver = vm.group("ver")
        if url is None:
            raise Unmappable("%s: entry %r has no url" % (source_name, m.group("path")))

        # Substituted before the withheld check: a replacement is not an absence.
        owner_name = None
        m_ssh = SSH_RE.match(url)
        if m_ssh:
            owner_name = "%s/%s" % (m_ssh.group("owner"), m_ssh.group("name"))
        if owner_name in PUBLIC_SUBSTITUTE:
            sub_repo, sub_ver, sub_path, why = PUBLIC_SUBSTITUTE[owner_name]
            out.append("  # SUBSTITUTED -- %s is not published." % (owner_name,))
            for chunk in _wrap(why, 72):
                out.append("  # %s" % (chunk,))
            out.append("  %s:" % (sub_path,))
            for b in block[1:]:
                um, vm = URL_LINE.match(b), VER_LINE.match(b)
                if um:
                    out.append("%surl: https://github.com/%s.git" % (um.group("indent"), sub_repo))
                elif vm:
                    out.append("%sversion: %s" % (vm.group("indent"), sub_ver))
                elif b.strip().startswith("#"):
                    continue          # the private entry's own commentary
                else:
                    out.append(b)
            notes.append("%s: %s -> %s (substituted)"
                         % (source_name, m.group("path"), sub_path))
            i = j
            continue

        pub = public_repo(url)
        if pub is None:
            reason = NO_PUBLIC_COUNTERPART["%s" % SSH_RE.match(url).expand(r"\g<owner>/\g<name>")]
            out.append("  # NOT AVAILABLE PUBLICLY -- %s" % (m.group("path"),))
            for chunk in _wrap(reason, 72):
                out.append("  # %s" % (chunk,))
            out.append("  # The entry is left here, commented out, so it is clear that")
            out.append("  # this piece exists and is deliberately absent.")
            for b in block:
                out.append(("  # " + b.strip()) if b.strip() else "  #")
            notes.append("%s: %s commented out (%s)"
                         % (source_name, m.group("path"), reason.split(";")[0]))
            i = j
            continue

        newver = VERSION_MAP.get((pub, ver), ver)
        if (pub, ver) in PINNED_ELSEWHERE:
            why = PINNED_ELSEWHERE[(pub, ver)]
            out.append("  # NOTE: %s" % (_wrap(why, 70)[0],))
            for chunk in _wrap(why, 70)[1:]:
                out.append("  #       %s" % (chunk,))
            notes.append("%s: %s -> %s (%s)" % (source_name, ver, newver, pub))
        for b in block:
            um, vm = URL_LINE.match(b), VER_LINE.match(b)
            if um:
                out.append("%surl: https://github.com/%s.git" % (um.group("indent"), pub))
            elif vm:
                out.append("%sversion: %s" % (vm.group("indent"), newver))
            else:
                out.append(b)
        i = j

    banner = [
        "#",
        "# GENERATED FILE -- do not edit. Produced from ../%s by" % (source_name,),
        "# tools/make_public_manifests.py. Edit that manifest and regenerate.",
        "#",
        "# This is the public form: it names the public mirrors over HTTPS, so it",
        "# needs no GitHub account, no SSH key and no membership of any",
        "# organisation. Repositories with no public counterpart are commented",
        "# out below, with the reason.",
        "#",
    ]
    # Insert after the source file's own first comment line, if it has one.
    at = 1 if out and out[0].startswith("#") else 0
    return "\n".join(out[:at] + banner + out[at:]) + "\n"


def _wrap(s, width):
    words, line, acc = s.split(), "", []
    for w in words:
        if line and len(line) + 1 + len(w) > width:
            acc.append(line); line = w
        else:
            line = (line + " " + w).strip()
    if line:
        acc.append(line)
    return acc or [""]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true",
                    help="fail if the committed public manifests are out of date")
    args = ap.parse_args()

    sources = sorted(f for f in os.listdir(ROOT) if f.endswith(".repos"))
    if not sources:
        print("no *.repos in %s" % (ROOT,), file=sys.stderr)
        return 1
    os.makedirs(OUTDIR, exist_ok=True)

    notes, stale, failed = [], [], 0
    for src in sources:
        try:
            text = transform(open(os.path.join(ROOT, src)).read(), src, notes)
        except Unmappable as exc:
            print("ERROR %s: %s" % (src, exc), file=sys.stderr)
            failed += 1
            continue
        dest = os.path.join(OUTDIR, src)
        old = open(dest).read() if os.path.exists(dest) else None
        if args.check:
            if old != text:
                stale.append(src)
        elif old != text:
            open(dest, "w").write(text)
            print("wrote    public/%s" % (src,))
        else:
            print("current  public/%s" % (src,))

    for n in notes:
        print("  note: %s" % (n,))
    if failed:
        return 1
    if args.check and stale:
        print("\nOUT OF DATE: %s\nRun tools/make_public_manifests.py."
              % (", ".join(stale),), file=sys.stderr)
        return 1
    if args.check:
        print("public manifests are up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
