# TARI robotic NDE scanning workspace

Robotic nondestructive evaluation: a UR10e carries an eddy-current or ultrasound
probe over a specimen, a toolpath is planned from a mesh the cell reconstructed
itself, and the measurements are projected back onto the surface as an image.

This repository is the **bootstrap**. It contains no application code — only the
manifests that say which repositories make up the workspace, and the two scripts
that turn them into a working system.

    tari.bash            bootstrap: sources, dependencies, build, environment
    dgpy_install.sh      build and install the dataguzzler-python side
    sim.repos            the shareable simulation layer
    acq.repos            + the acquisition stack
    hw.repos             + instrument drivers
    site.repos           + our cells and calibration (private)
    test/                suites that check the two scripts; no ROS, no build

**Every command below was run, in the order given, on an Ubuntu 22.04.5 machine
on 2026-09-30, starting from `git clone`** — with one stated exception: the
vendor-SDK block in [step 4](#4-vendor-sdks--the-one-manual-step) was verified on
that machine earlier in the month and was already satisfied this time, so it is
reproduced rather than re-run. Nothing else here is described from intent. Where
something could not be automated it says so and gives the exact commands; where
something is still missing it is under [Known limits](#known-limits).

---

## What you need before you start

| | |
|---|---|
| **OS** | Ubuntu 22.04 (jammy) specifically, or WSL2 running it. Not 24.04: ROS 2 Iron has no noble packages. |
| **Python** | The system `python3`, which on 22.04 is **3.10.12**. `bpy` publishes CPython 3.10 wheels only (`Requires-Python: ==3.10.*`), so on any other interpreter two mesh nodes cannot run. Never a venv — see [the install rule](#one-install-command-and-it-is-never-editable). |
| **sudo** | Required. Everything Python here is installed system-wide. |
| **GitHub SSH** | Most manifests point at private repositories over `git@github.com:`. Check with `ssh -T git@github.com` first; `./tari.bash --check-remotes` then tests all of them at once. |
| **Disk** | About **9 GB** for the full `site` layer with SOFA — 4.9 GB under `~/tari` and the rest in `/usr` — on top of a machine that already has ROS Iron. Add ~3 GB if it does not, and another ~2 GB of logs and Gazebo caches once you start running cells. |
| **Time** | **23 minutes** for the whole `site` layer on 16 cores when ROS and the vendor SDKs are already installed; see [Measured cost](#measured-cost). Add roughly 20 minutes for a first ROS install. |
| **GPU** | Not required. Gazebo falls back to software rendering, slowly, and OpenCL runs on PoCL/CPU. |

**You do not need to install ROS 2 Iron first.** `--phase prereqs` adds the ROS
apt repository and installs it, along with `colcon`, `vcstool` and `rosdep`. It
has to do them in that order: those three are not in Ubuntu universe, they come
only from the ROS repository, so there is no way to install them on a bare
machine before the repository exists.

Two things about Iron are worth knowing before you start.

- **Iron reached end of life in November 2024, but its packages are still
  published.** As of 2026-09-30 the jammy index carries 2164 `ros-iron-*`
  binaries, frozen at their November 2024 builds, including everything here. End
  of life means nothing new will appear, not that the suite has been withdrawn.
  `rosdep` still knows Iron. The move to an LTS distribution is nonetheless owed.
- **The apt repository is added by upstream's own package, not by a hand-written
  sources list.** Open Robotics now ship a versioned `ros2-apt-source` deb that
  installs the signing key and the `.list` file together, and `--phase prereqs`
  fetches the current release of it from GitHub and installs it. The key rotating
  or the host moving is then upstream's problem rather than a fingerprint going
  stale in this repository.

  It also steps around a live fault: `https://packages.ros.org` is a CNAME to
  `ftp.osuosl.org`, which presents a certificate covering only `osuosl.org` and
  `*.osuosl.org`, so the SNI never matches and every TLS client refuses it, on
  IPv4 and IPv6 alike:

  ```
  curl: (60) SSL: no alternative certificate subject name matches
        target host name 'packages.ros.org'
  ```

  The deb comes from GitHub releases over HTTPS with a valid certificate, and apt
  still authenticates the repository itself by the detached GPG signature on
  `InRelease` — which is why an unsigned or keyless workaround is never
  acceptable here, whatever the transport is doing.

### Repository naming

A repository name and the directory it is checked out into are not the same
string, on purpose.

`_staging` marks a private repository for internal development that is not yet
ready for public release. A CI/CD pipeline will be responsible for promoting to
public; that does not exist yet. `_private` marks something that is not on a path
to public release at all — site data, proprietary formats.

**The manifests always check out into the name without the suffix**, so the
working tree is named for what a package set *is* rather than for its release
state, and nothing has to be renamed when a repository is promoted.

ROS and colcon-managed repositories use underscores throughout, matching ROS
convention. The dataguzzler modules keep the dataguzzler convention instead:
dashes in the repository name, underscores in the package name — so
`dgpython-uniwest` on disk provides `dgpython_uniwest` to Python.

---

## The layers

Layers are additive and each is a strict superset of the one before, so
`--layer hw` imports `sim`, then `acq`, then `hw`.

| layer | adds | needs |
|---|---|---|
| `sim` | Gazebo, MoveIt/MTC, Noether, reconstruction, mesh filtering, YOLO, **and both motion action servers** | nothing private, no hardware |
| `acq` | spatialnde2, dataguzzler-python, the scan configurations | a C++17/SWIG/Qt/OSG build |
| `hw` | Azure, Keyence, NI-DAQmx and Uniwest drivers | the devices, and two vendor SDKs installed by hand |
| `site` | our cell manifests and calibration | org credentials |

There is a fifth layer, `container`. **Ignore it.** It builds a Docker image and
exists only because one development machine runs Arch, where ROS Iron is not
packaged. It is a local convenience, not how this stack is deployed, and nothing
below needs it.

The line that matters is between `hw` and `site`. Everything up to and including
`hw` can be given to a collaborator; `site` cannot. The only real proof of that is
to clone and build `sim.repos` from an account with no access to org-private
repositories — not a code review.

### Seven phases

Each is idempotent — re-run it after a pull and it does the work that is now
missing and nothing else — and any one can be run on its own with `--phase`:

| phase | |
|---|---|
| `prereqs` | apt packages, `rosdep init`/`update`, vcstool, colcon, and the Python modules apt cannot supply |
| `sources` | fetches the layer chain's manifests, in order, one repository at a time; `--with-sofa` fetches SOFA here, not in `build` |
| `rosdep` | `rosdep install` over `ros_ws/src`; checks the vendor SDKs on `hw` |
| `python` | runs `dgpy_install.sh --with-extras` (a no-op below `acq`) |
| `build` | one `colcon build --symlink-install` over all of `ros_ws` |
| `env` | writes `tari_setup.bash` — the same environment the `build` phase itself used, so building by hand and building through the script are one build |
| `verify` | checks the layer's packages resolve through the ament index, and reports install drift |

`./tari.bash --layer site` runs all seven for the whole chain in one command.
**On a machine that has never built this, run them one at a time anyway** — the
combined run buries the first failure under a thousand lines of build output, and
each step below is separately checkable.

Note that **`--phase build` always builds all of `ros_ws/src`**, whatever
`--layer` says. The layer only decides what `sources` imports and what `python`
installs. So "do the sim layer first" means: import sim only, build what that
gave you, then import hw and build again.

Two more flags worth knowing before the first run: `-n` / `--dry-run` prints the
whole plan without running any of it, and `--check-remotes` tests every manifest
URL and exits.

**If `--phase sources` fails, run it again.** It fetches one repository at a
time, with retries on transient network errors, and skips anything already
cloned — a repository pinned to a commit it is already sitting on is not even
contacted. So a re-run only retries what failed. This matters because github
throttles concurrent SSH connections per address, and the failure it produces
names neither throttling nor the real cause:

```
kex_exchange_identification: read: Connection reset by peer
Connection reset by 140.82.112.3 port 22
fatal: Could not read from remote repository.

Please make sure you have the correct access rights
and the repository exists.
```

The last two lines are wrong — the key is fine. Waiting a minute and re-running
the phase is the whole fix. A failure that says `Permission denied (publickey)`
*is* about the key, is not retried, and `./tari.bash --check-remotes` will say
which repositories it cannot read.

The same phase also **fast-forwards a checkout that already exists**, which
`vcs import` does not do: a repository cloned last month at `iron` stays at last
month's commit under `vcs import`, and it reports success. A checkout with
uncommitted changes, a diverged branch, or an origin that is not the manifest's
is reported and left exactly as it was.

### A shared machine: the workspace is one account's, the sudo is another's

On the cell the robot runs as an unprivileged shared account, `labuser`, which
everybody uses and which has no sudo. Almost every phase here needs sudo, so the
workspace lives in `labuser`'s home and a **named account with sudo** runs the
script against it. Everybody is in the group `labusers` and the directories
carry the setgid bit, so new files inherit that group.

Three things have to be true together, and the cell had two of them:

1. one group everybody is in — `labusers`;
2. **setgid** on the directories, so a new file inherits it;
3. a **umask that leaves group write on** — because setgid gives the group, not
   the permission. Under the default 022 a file comes out
   `-rw-r--r-- lesthatj labusers`, which nobody else in the group can write,
   truncate, or `chmod` — only its owner can `chmod` it, so after the fact
   nothing short of root repairs it.

`tari.bash` sets `umask 0002` for itself (override with `TARI_UMASK`), warns
when it finds a workspace with several owners and an incomplete arrangement,
and **refuses to start a build** when anything under `ros_ws/build`,
`ros_ws/install` or `ros_ws/log` is not writable by the account running it.
That last one is worth the refusal: colcon reports somebody else's 0644 files
as

```
CMake Error at .../CMakePackageConfigHelpers.cmake:344 (configure_file):
  Operation not permitted
PermissionError: [Errno 13] ... install/csf_loader_msgs/.../package.dsv
```

— two hundred lines naming neither ownership nor an account. Recover with
either a clean rebuild or a one-off repair:

```bash
rm -rf ros_ws/build ros_ws/install ros_ws/log          # or
sudo chgrp -R labusers ~labuser/tari
sudo find ~labuser/tari -type d -exec chmod g+rwxs {} +
sudo find ~labuser/tari -type f -exec chmod g+rw {} +
```

and put `umask 0002` in the shell startup file of every account that drives
this, or the next 022 build recreates it.

Two more consequences of the split, both handled but worth knowing:

- **git refuses a repository it does not own** (`fatal: detected dubious
  ownership`), and the sharpest case is `sudo pip install .`, where
  `setuptools_scm` runs git as root over `labuser`'s checkout and the package
  build dies with `metadata-generation-failed`. Both scripts now pass
  `safe.directory` for the workspace's own checkouts through `GIT_CONFIG_COUNT`
  / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n`, which applies to that process
  only. Do **not** `sudo git config --global --add safe.directory "*"`: it is
  permanent, machine-wide, applies to root, and trusts every repository on the
  box to get past one bootstrap.
- **a per-user `setuptools` wins over anything `sudo pip` installs.**
  `~/.local/lib/python3.10/site-packages` precedes every system directory on
  `sys.path`, so a `setuptools` 84 in one human's home cannot be displaced by
  the python phase and the build breaks for that person and nobody else. The
  prereqs phase now prints where `setuptools` was found and, when it is in your
  own home, the unprivileged command that removes it.

### Bringing an existing machine up to the manifest: `--resync`

"Reported and left alone" is right on a development machine, where those
checkouts carry work in progress, and wrong on a cell that simply needs to match
what the manifests now say. To force it:

```bash
git pull --ff-only          # the manifests live here, so this comes first
./tari.bash --layer site --resync
```

That is the whole update. `--resync` moves a remote that points somewhere else,
switches branch, and hard-resets a branch that has diverged; the other phases
are idempotent, so the same command then reinstalls whatever the python layer is
missing and runs one colcon build over what changed.

**It is needed whenever a manifest changes a repository's `url` or `version`**,
and without it nothing goes wrong loudly. That case is real: a third-party
repository that acquires a local patch moves to our own fork on a `tari/iron`
branch — `industrial_reconstruction`, `yolo_ros`, and `noether` since the
`getDistancesToMinMaxCuts` fix — and every machine that cloned it beforehand is
pointing at the upstream it came from. A plain `--phase sources` reports that and
keeps the unpatched code.

**`--resync` does not discard uncommitted changes.** It stops at them and says
so. The asymmetry is deliberate: a moved remote costs nothing to redo, a
discarded commit stays in that repository's reflog for ninety days and its hash
is printed so it can be recovered, and an uncommitted edit is recoverable from
nowhere at all. To override that as well:

```bash
./tari.bash --layer site --resync --discard-local-changes
```

which adds `reset --hard` and `clean -fd` per repository, printing the file list
first. Ignored files are kept, so build products survive and the rebuild stays
incremental. `--discard-local-changes` implies `--resync`.

**Not all "uncommitted changes" are changes.** The first cell run reported 224
modified files across eleven checkouts, and every one of them was a `.py` file —
including generated ones nobody edits — because the trees had arrived from a
Windows workstation through an SFTP client in text mode and were CRLF on disk
against an LF index. The sources phase now classifies the dirt before it says
anything about it:

| what it says | what it means | what clears it |
|---|---|---|
| `ONLY in line endings` | identical with `--ignore-cr-at-eol`; CRLF or a mode bit | `--discard-local-changes` |
| `only a submodule pointer` | a submodule HEAD is not the recorded commit — `reset --hard` does not fix this, so it reports itself for ever | `--discard-local-changes` (it runs `submodule update`) |
| `REAL content changes` | a real edit, listed as `+added/-removed path` | `--discard-local-changes --yes` |

So cosmetic dirt costs no decision, and a real edit cannot be thrown away
hidden among two hundred line-ending diffs. Fix the cause of the CRLF too:

```bash
git config --global core.autocrlf false
```

`.gitattributes` pins `eol=lf` for this repository, so a checkout here cannot
acquire CRLF from a global git config — but the checkouts under `ros_ws/src` are
other projects' and carry their own.

Read the one-line summary either way:

```
26 cloned, 3 updated, 21 already current, 1 force-resynced, 0 left alone
```

Anything in **left alone** did not update. Without `--resync` that line is
followed by a warning saying so, because a skipped repository must not read as
success.

---

## Copy-paste bootstrap

### 1. Clone

```bash
git clone --branch iron git@github.com:Adaptive-Robotic-NDE/tari_workspace_staging.git ~/tari
cd ~/tari
./tari.bash --check-remotes
```

Do the `--check-remotes` first: it is two seconds, and it tells you about a
credential problem before you spend twenty minutes on a build that will stop at a
repository you cannot read. Every URL in every manifest resolves as of
2026-09-30.

### 2. Layer `sim` — Gazebo, MoveIt, Noether, reconstruction

```bash
cd ~/tari
./tari.bash --layer sim --phase prereqs
./tari.bash --layer sim --phase sources --with-sofa
./tari.bash --layer sim --phase rosdep
./tari.bash --layer sim --phase python          # a no-op below the acq layer
./tari.bash --layer sim --phase build
./tari.bash --layer sim --phase env
./tari.bash --layer sim --phase verify
```

Drop `--with-sofa` unless you need the soft-robotics plugin; see
[Optional extras](#optional-extras-and-what-they-cost). The build ends with
`Summary: 36 packages finished` and `verify` exits 0.

### 3. Layer `acq` — spatialnde2 and dataguzzler-python

```bash
cd ~/tari
./tari.bash --layer acq --phase prereqs
./tari.bash --layer acq --phase sources
./tari.bash --layer acq --phase rosdep
./tari.bash --layer acq --phase python
./tari.bash --layer acq --phase build
./tari.bash --layer acq --phase env
./tari.bash --layer acq --phase verify
```

`acq.repos` adds **no colcon packages at all** — spatialnde2, dataguzzler-python,
the two instrument-independent dgpython modules and the `.dgp`/`.dpi` scan
configurations all live at the workspace root and are installed by
`dgpy_install.sh`, which `--phase python` runs. The `build` phase is still worth
running: `acq`'s prereqs add the C++/SWIG/Qt/OSG toolchain, so it confirms nothing
in `ros_ws` regressed. The package count does not change.

`--phase python` is the long one: it configures and compiles spatialnde2 with
cmake, installs it, then installs the rest of the stack.

### 4. Vendor SDKs — the one manual step

**Only needed for `--layer hw`.** `--phase rosdep` stops and prints this
procedure if either is missing, rather than building a driver without its SDK.
Both are reproduced here because neither can be automated.

#### Azure Kinect Sensor SDK (`libk4a`)

`azure_kinect_ros_driver` links it, and without it CMake fails with "could not
find `k4aConfig.cmake`" — an error that says nothing about a camera.

**Not automated on purpose, for three reasons**: it needs Microsoft's licence
accepted, it temporarily adds a *different Ubuntu release's* archive to the
machine, and it is only ever needed by one layer. Run it yourself and watch it.

`libk4a1.4` hard-depends on `libsoundio1`, which jammy does not carry, so that one
package comes from focal. Pin focal *below* jammy so nothing else can ever be
satisfied from it, and use your own file so `/etc/apt/sources.list` is never
edited:

```bash
sudo tee /etc/apt/sources.list.d/zz-focal-temp.list <<<'deb http://us.archive.ubuntu.com/ubuntu focal main universe'
printf 'Package: *\nPin: release n=focal\nPin-Priority: 100\n' \
    | sudo tee /etc/apt/preferences.d/zz-focal-temp
sudo apt-get update && sudo apt-get install -y --no-remove libsoundio1
sudo rm /etc/apt/sources.list.d/zz-focal-temp.list /etc/apt/preferences.d/zz-focal-temp
sudo apt-get update
```

Then Microsoft's 18.04 pool, as a keyring plus a source file. Do **not** install
`packages-microsoft-prod.deb`: removing its source file afterwards leaves dpkg
owning files that are not there.

```bash
curl -sSL https://packages.microsoft.com/keys/microsoft.asc \
    | sudo gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/18.04/prod bionic main" \
    | sudo tee /etc/apt/sources.list.d/microsoft-prod.list
sudo apt-get update
```

Then the SDK. **`ACCEPT_EULA=Y` accepts Microsoft's licence — read it first if
you have not.** It is the only non-interactive route, and the reason is specific:
`libk4a1.4`'s `preinst` presents the EULA through debconf and calls
`db_fset accept-eula seen false` *before* asking, so under
`DEBIAN_FRONTEND=noninteractive` the question cannot be asked at all and the
install dies with

```
eula agree question could not be asked
libk4a1.4 will not be installed
dpkg: error processing archive .../libk4a1.4_1.4.2_amd64.deb (--unpack)
```

Preseeding `accept-eula` fails for the same reason. The `preinst`'s first check
is the environment variable:

```bash
sudo DEBIAN_FRONTEND=noninteractive ACCEPT_EULA=Y \
    apt-get install -y --no-remove 'libk4a1.4*' k4a-tools
```

Banish the repository again and check the thing the build actually needs:

```bash
sudo rm /etc/apt/sources.list.d/microsoft-prod.list /usr/share/keyrings/microsoft.gpg
sudo apt-get update
ldconfig -p | grep libk4a
ls /usr/lib/x86_64-linux-gnu/cmake/k4a/k4aConfig.cmake
```

Do not check it by running `k4aviewer`, which needs a camera and a display. The
`k4aConfig.cmake` above is the real test.

#### NI-DAQmx

For `dgpython-nidaqmx`, which imports it at module load. Proprietary, x86-64
only. Install National Instruments' driver from their own installer, then the
Python bindings the same way as everything else here — system-wide, never
per-user:

```bash
sudo python3 -m pip install nidaqmx
```

### 5. Layer `hw` — instrument drivers

```bash
cd ~/tari
./tari.bash --layer hw --phase prereqs
./tari.bash --layer hw --phase sources
./tari.bash --layer hw --phase rosdep
./tari.bash --layer hw --phase python
./tari.bash --layer hw --phase build
./tari.bash --layer hw --phase env
./tari.bash --layer hw --phase verify
```

`--phase rosdep` ends with `Azure Kinect SDK (libk4a) found` and `NI-DAQmx Python
bindings found`; the build ends with `Summary: 41 packages finished`.

> **On a shared machine, `--phase python` replaces the instrument modules that
> are already there.** `dgpython_nidaqmx`, `dgpython_uniwest` and the rest are
> single distribution names: two projects cannot share one. If another project on
> the machine has its own checkout, diff the installed tree against yours and
> keep a copy before converging:
>
>     diff -ru /usr/local/lib/python3.10/dist-packages/dgpython_nidaqmx \
>              ~/tari/dgpython-nidaqmx/dgpython_nidaqmx
>
> To prove such a module *builds* without installing it:
>
>     cd ~/tari/dgpython-nidaqmx && SETUPTOOLS_USE_DISTUTILS=stdlib \
>         python3 -m pip wheel --no-deps --no-build-isolation -w /tmp/wheelcheck .

### 6. Layer `site` — our cells and calibration

```bash
cd ~/tari
./tari.bash --layer site --phase prereqs
./tari.bash --layer site --phase sources
./tari.bash --layer site --phase rosdep
./tari.bash --layer site --phase python
./tari.bash --layer site --phase build
./tari.bash --layer site --phase env
./tari.bash --layer site --phase verify
```

The build ends with `Summary: 47 packages finished` — every package in the tree,
`ros2plugin` included. `--phase env` writes `TARI_CELL_PATH` into
`tari_setup.bash` for this layer only, because `tari_cell_configs` only exists
from here up.

### 7. Use it

```bash
cd ~/tari
source ./tari_setup.bash
ros2 run tari_bringup tari_cell_info --list
ros2 launch tari_bringup bringup.launch.py cell:=ex-ur10e-1 mode:=sim
```

**Source `tari_setup.bash` in every shell, including shells that run
dataguzzler-python.** `dgpython_rosmotion` is a colcon package, so
`import dgpython_rosmotion` inside a `.dgp` resolves through the ROS overlay
rather than through pip. There is one environment here and it always has ROS in
it.

**That includes a shell that runs `colcon build` by hand**, which is not just a
tidiness rule. `tari_setup.bash` carries the two variables the build phase
itself uses, and without them a hand-run build differs from the scripted one in
ways nothing reports:

- `COLCON_DEFAULTS_FILE` — colcon's defaults extension looks for
  `colcon_defaults.yaml` at a path relative to the current directory, and a
  build runs from `ros_ws` while the file is in the workspace root. Unset, the
  whole workspace compiles with an empty `CMAKE_BUILD_TYPE`: no `-O` flags at
  all, and no error.
- `TARI_COLCON_SKIP` (or `SOFA_INSTALL_DIR`, when SOFA is checked out) — the
  package that needs SOFA does a hard `CMake Error ... Please specify variable
  SOFA_INSTALL_DIR in your environnement` when the variable is unset, and one
  failing package aborts the rest of the build. With SOFA absent the script
  skips it; so must you:

  ```bash
  source ./tari_setup.bash
  cd ros_ws && colcon build --symlink-install \
      ${TARI_COLCON_SKIP:+--packages-skip $TARI_COLCON_SKIP}
  ```

Keep `--symlink-install` in that command. A workspace built once with it and
once without ends up with packages that have an `install/` tree and no ament
index marker, which fail every `ros2 run` silently.

---

## Proving it worked

A green exit from `--phase build` is not the deliverable. Things that have built
cleanly here and still not worked include a plugin named only in a YAML string, a
library with a build-tree RPATH, a SWIG wrapper generated with no directors, and
a wheel built from a stale object file. Run these.

**Every package built is reachable through the ament index.** `--phase verify`
spot-checks six; this checks the lot:

```bash
cd ~/tari && source ./tari_setup.bash
ls ros_ws/install | grep -vE '^(setup|local_setup|_local_setup|COLCON_IGNORE)' | wc -l
for p in $(ls ros_ws/install | grep -vE '^(setup|local_setup|_local_setup|COLCON_IGNORE)'); do
    ros2 pkg prefix "$p" >/dev/null 2>&1 || echo "NOT ON THE AMENT INDEX: $p"
done
```

47 packages, and exactly one of them — `libsocket` — is not on the ament index.
That is correct: it is a third-party plain-CMake library with a ROS 1 manifest, so
colcon writes no ament marker for it, and `keyence_experimental` finds it through
`CMAKE_PREFIX_PATH` at build time rather than through `ros2 pkg`. Anything *else*
in that list is a real fault.

**Everything built Release.** `colcon_defaults.yaml` is read from the *current
directory*, and the build runs from `ros_ws` while the file sits one level up —
`tari.bash` passes `COLCON_DEFAULTS_FILE` for exactly that reason, and for as long
as that went unnoticed nothing was built Release at all. Check, do not assume:

```bash
grep -h '^CMAKE_BUILD_TYPE' ~/tari/ros_ws/build/*/CMakeCache.txt | sort | uniq -c
```

Expect `31 CMAKE_BUILD_TYPE:STRING=Release` for the full 47 — the rest are
`ament_python` packages, which have no CMake cache.

**Every dataguzzler package matches its source.** Not `STALE`, `EDITABLE`,
`USER-SITE`, `LEGACY`, `BROKEN` or `UNVERSIONED`:

```bash
cd ~/tari && ./dgpy_install.sh --check
```

**Both Cython extras are registered, not merely importable.** An import proves
nothing about a compiled spatialnde2 math function:

```bash
python3 -c 'import spatialnde2 as snde, spatialnde2_ec_functions, spatialnde2_cpp_calibration_function
print(sorted(k for k in snde.math_function_registry().keys()
             if "ec_condition" in k or "cpp_calibration" in k))'
# ['spatialnde2_cpp_calibration_function.calibration_function',
#  'spatialnde2_ec_functions.ec_condition_function']
```

`ldd -r` on either extension reports a few dozen undefined `snde::` symbols and
that is normal: each carries `NEEDED libspatialnde2.so` with no RUNPATH, and the
`.pyx`'s own `import spatialnde2` has already loaded the library by the time
anything calls in. Compare the two against each other rather than treating the
count as a fault.

**`bpy` imports, so the two nodes that need it can run.**
`tari_mesh_filter_srv` and `x3d_converter` do `import bpy` at the top:

```bash
python3 -c 'import bpy; print(bpy.app.version_string)'    # 4.0.0
```

**The scripts' own suites pass.** No ROS, no build, source tree only:

```bash
cd ~/tari && python3 -m pytest test/ -q
# 46 passed, 3 skipped
```

Two of those skips are `bootstrap_workspace.sh is not checked out`, which is
correct — it is a development-host leftover that no manifest provides.

**The layer verifies, exit 0:**

```bash
cd ~/tari && ./tari.bash --layer site --phase verify; echo "exit $?"
```

**A cell actually comes up.** `tari_cell_info` answers without starting anything,
and is the right first question — it prints every node that would start and the
reason for each that would not:

```bash
cd ~/tari && source ./tari_setup.bash
ros2 run tari_bringup tari_cell_info --list
ros2 run tari_bringup tari_cell_info --cell ex-ur10e-1 --mode sim
```

For a real bring-up on a machine with no display, `Xvfb` plus software GL is
enough for `gzclient` and `rviz2` to have a screen to open on; the graph is what
is being tested, not the rendering. **Isolate the domain first** — these machines
are shared and other projects run ROS on them:

```bash
export ROS_DOMAIN_ID=42
export ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST
Xvfb :99 -screen 0 1600x1200x24 -nolisten tcp &
export DISPLAY=:99 LIBGL_ALWAYS_SOFTWARE=1
ros2 launch tari_bringup bringup.launch.py cell:=ex-ur10e-1 mode:=sim
```

Give it about three minutes to settle, then in another shell with the same
environment:

```bash
ros2 topic list | wc -l         # 66
ros2 node list                  # 30, including tari_mesh_filter_srv and x3d_converter
ros2 control list_controllers   # joint_state_broadcaster and
                                # joint_trajectory_controller, both active
ros2 topic hz /clock            # 9.96 Hz
ros2 topic echo --once /joint_states
ros2 service type /compute_ik   # moveit_msgs/srv/GetPositionIK
```

**`ros2 node list` under-reports, and silently.** Its discovery window is about
two seconds; on this same healthy cell three calls minutes apart returned 30, 19
and 11 names. The topic count was 66 every time. Grade a bring-up by the topic
and service lists, or by `pgrep -a -f 'gzserver|move_group|mtc_node|…'`; never
read a short node list as nodes having died.

**Then exercise it, because a graph snapshot only says the nodes exist.** Move
the arm. This asks ros2_control, Gazebo's physics step and the trajectory
controller all at once, and it is the check that would have caught a missing
`pick_ik` in the days when the symptom was "every scan pass moves 0 mm":

```bash
ros2 topic echo --once /joint_states     # read the current positions
# then send the first joint 0.25 rad away from where it is:
ros2 action send_goal /joint_trajectory_controller/follow_joint_trajectory \
  control_msgs/action/FollowJointTrajectory \
  "{trajectory: {joint_names: [shoulder_pan_joint, shoulder_lift_joint, elbow_joint,
                               wrist_1_joint, wrist_2_joint, wrist_3_joint],
                 points: [{positions: [-1.84, -1.40, 0.96, -1.15, -1.57, 2.67],
                           time_from_start: {sec: 5}}]}}"
ros2 topic echo --once /joint_states     # shoulder_pan has moved
```

Those numbers are the `ex-ur10e-1` sim start pose with `shoulder_pan_joint`
changed from −2.09 to −1.84; read your own first rather than pasting them blind.

MoveIt itself is worth one more question, and **not with a Cartesian pose you
picked yourself** — a plausible-looking target inside the declared work volume
answered `error_code: -31` (`NO_IK_SOLUTION`), because reachability depends on
the tooling and the wrist branch and says nothing about whether an IK solver is
loaded. Ask `/compute_fk` for the tool pose of the *current* joint state and feed
that to `/compute_ik`: a pose the arm is demonstrably already in must solve, so a
failure is the solver and not the geometry.

Two things mislead when reading the launch log afterwards.

- **Everything at the very end is the teardown, not a crash.** `move_group` and
  `mtc_node` exiting `-11`, `rviz2` `-11`, `gzserver` `-6` with
  `failed to call rcl_logging_rosout_remove_sublogger`, any rclpy node raising
  `ExternalShutdownException` — the `signal_handler(signum=2)` lines come first,
  and a graph snapshot taken earlier shows those nodes alive.
- **Bring-up's own `OK`/`SKIP` table is a graph check made before a node can die
  on an import.** A node it calls `OK` may already have exited 1. Grep for
  `ModuleNotFoundError` and `process has died` every time, and check where the
  first `signal_handler(signum=2)` line falls — on a healthy run every
  `process has died` is after it.

---

## Two build systems, one rule

**colcon owns `ros_ws/src` and nothing else. `dgpy_install.sh` owns the workspace
root.**

spatialnde2, dataguzzler-python and the `dgpython-*` instrument modules are
ordinary Python distributions, not ROS packages, and colcon never touches them.
The one exception is `dgpython-ros2motion`, which *is* a set of ROS packages,
lives in `ros_ws/src`, and is built by colcon — do not pip install any part of
it. A package built by both ends up on `PYTHONPATH` twice with the colcon copy
shadowing the other, so you edit one and run the other. That has cost this
project real time, twice.

`dgpy_install.sh` refuses to install anything carrying a `package.xml`, which
makes the mistake impossible rather than merely documented.

### One install command, and it is never editable

Every Python package here — `spatialnde2`, `dataguzzler-python`, every
`dgpython-*` module, the optional extras — is installed with exactly this, and
nothing else:

```bash
sudo pip install --no-deps --no-build-isolation .
```

Not `-e`. Not `--user`. Not a venv. Not a bare `pip install .`. Each part earns
its place:

| | |
|---|---|
| `sudo` | System-wide, so one deliberate install is what every shell and every service runs. An unprivileged install lands in `~/.local`, which precedes the system directories on `sys.path` — it silently shadows the real install, and then which shell installed a package decides what the next one runs. |
| `--no-deps` | pip resolves nothing, so it cannot substitute a version nobody chose for one this stack was built against. |
| `--no-build-isolation` | The compiled parts build against the interpreter and headers actually present, rather than against a throwaway environment pip assembles. |
| never `-e` | An editable install makes what runs depend on the state of a working tree rather than on something deliberately installed, so a stale or half-finished checkout becomes the running code with nothing to say so. |

`dgpy_install.sh` runs precisely that command for every package, and `--dry-run`
prints it verbatim before running anything.

**Editing a source file therefore changes nothing until you reinstall, and
nothing tells you so.** That is the intended behaviour, not a problem to work
around: what runs is what was installed. Two things make it manageable:

```bash
./dgpy_install.sh --check
```

Every package carries a `setuptools_scm` version embedding the commit it was built
from, so this reports exactly which installed copies no longer match the source
you have checked out — including copies built from a dirty tree, which match no
commit at all. It also reports the two ways the install itself can be wrong rather
than merely out of date: `EDITABLE`, and `USER-SITE` for a per-user copy shadowing
the system one. Remove that copy (`pip uninstall <name>`) before reinstalling — a
reinstall alone would not change what runs.

`LEGACY` is the third, and it is the one that used to be unrecoverable. It means
the installed copy came from `python3 setup.py install` — typically an older
install out of `/usr/local/src` — which leaves `<name>.egg-info` metadata and no
file list. pip will not replace one of those, and says so:

```
error: uninstall-distutils-installed-package
× Cannot uninstall dgpython_nidaqmx 0.0.0
╰─> It is a distutils installed project and thus we cannot accurately determine
    which files belong to it which would lead to only a partial uninstall.
```

Re-running changed nothing, because nothing about a re-run moved the thing in the
way; on one clean-machine bootstrap two modules failed this way on four
consecutive runs. An install now removes that metadata first, naming the path it
removed, and then installs normally. Nothing has to be done by hand.

Two more states matter. `ABSENT` means the source is not checked out at all, which
on a machine that imported only `acq.repos` is the ordinary state of the instrument
drivers and is not a finding. `BROKEN` means the installed copy carries exactly the
right version and still does not load — the two compiled packages are import-tested
rather than only version-compared, because a matching version string is not
evidence that the shared libraries next to it resolve.

```bash
./dgpy_install.sh --only spatialnde2
```

Reinstall one package, or `--from <name>` for that one and everything after it in
dependency order. A plain `./dgpy_install.sh` reinstalls only what is stale, and
`--force` reinstalls regardless.

**A green "Successfully built" can be a stale object file.** `dgpy_install.sh`
runs pip from inside the package's source directory, so `build/temp.../*.o`
survives between runs and `build_ext` skips work whose output is newer than its
input — a deliberately broken link line has been observed to report
"Successfully built" and install a wheel of exactly the previous size. Before
believing a compile *fix*, delete the build tree:

```bash
cd ~/tari/spatialnde2-ec-functions && sudo rm -rf build *.egg-info
```

The corollary is that a green `--with-extras` on a machine that has built before
is not evidence about the source in front of you. It is on a fresh clone.

> **On a shared machine, expect to replace an existing install.** `spatialnde2`
> and `dataguzzler-python` are shared upstream projects, and `dgpy_install.sh`
> installs them system-wide. Another project on the same machine can perfectly
> well have its own checkout of either — usually an earlier version of the same
> code. Converging on one version is the point, so the installer replaces it and
> says which tree the previous copy came from:
>
>     warning: spatialnde2 was installed from /usr/local/src/spatialnde2/build,
>              not from /home/you/tari -- replacing it.
>
> That warning is expected and is not a reason to stop. Note also that
> `spatialnde2`, `dataguzzler-python` and several `dgpython-*` modules
> legitimately have `isuthermography` remotes rather than this organisation's — a
> collaboration, not a foreign package.
>
> **Look for a pip-installed Qt before building.** spatialnde2 compiles against
> the system Qt (`qtbase5-dev`, `python3-pyqt5`, both from apt). A pip Qt wheel is
> a second complete Qt inside `site-packages` — `PyQt6-Qt6` alone is 260 MB of
> `libQt6*.so.6` with its own `sip` — and both `dataguzzler_python/Qt.py` and
> spatialnde2's `snde_qt.i` typemaps choose bindings by what is importable or
> already loaded, so a stray one changes which Qt a Qt5-compiled library talks to.
> `--phase python` warns about any it finds; clear them first:
>
>     sudo python3 -m pip uninstall PyQt6 PyQt6-Qt6 PyQt6_sip

---

## Optional extras, and what they cost

| flag | cost | what you lose without it |
|---|---|---|
| `--with-sofa` | 1.3 GB download and disk, about a minute on a gigabit LAN, plus ~3 min of build | `sofaros2plugin` (colcon package `ros2plugin`) is `--packages-skip`ped, because its `CMakeLists.txt` does a hard `message(FATAL_ERROR "Please specify variable SOFA_INSTALL_DIR")` and one failing package stops the whole build. It is the only package in the tree not built by default; nothing else depends on it. **Fetch it in `--phase sources`, not `build`.** |
| `--with-test-data` | ~95 MB over git-lfs, and `git-lfs` must be installed | The recorded-scan fixtures. Sections of the suites skip rather than fail. |
| `--with-extras` | a compile each | Nothing — **it is not a flag you pass to `tari.bash`**. `--phase python` always passes it to `dgpy_install.sh`, because `acq.repos` declares `spatialnde2-ec-functions` and an eddy-current scan does not start without it. Pass it yourself only when running `dgpy_install.sh` directly. |

Three spellings are in play around SOFA and confusing them is most of the
difficulty: the directory is `sofaros2plugin`, the CMake project and the library
are `ros2plugin` / `libros2plugin.so`, and `getModuleName()` inside the source
returns a third, `ROS2Plugin`. colcon goes by `package.xml`; SOFA goes by the
library file name.

**Do not grade that plugin by SOFA's factory listing.** SOFA 24.12 deprecated
`RegisterObject` and cannot attribute implicitly-registered classes to a target,
so `RequiredPlugin` prints `Plugin not found in loaded plugins: ros2plugin` and
`No component has been registered from ros2plugin` *immediately after a
successful* `Loaded plugin:` line, and the components are in the factory anyway.
Grade it by creating the objects and watching the topics — and note that its
publishers are `BEST_EFFORT`, `VOLATILE`, `KEEP_LAST(1)`, lifespan 1 s, so a
default `RELIABLE` subscription never matches and a plain `ros2 topic echo` says
the topic is not published while it is publishing at 170 Hz. Use
`--qos-reliability best_effort`. Verified on a fresh build 2026-09-30: an
independent rclpy observer received 4133 messages each on `/sofa/point`
(`sensor_msgs/PointCloud`) and `/sofa/double` (`std_msgs/Float64`). Also expect a
SIGSEGV in FastDDS teardown at exit, every run, *after* the work is done —
`ROS2Context::cleanup()` calls `rclcpp::shutdown()` while its detached executor
threads are still spinning. Check for the completion line before believing a
crash. The shipped `scenes/*.scn` do not load on SOFA 25.12 and `runSofa` exits 0
regardless; treat them as documentation of intent.

There are two extras and their failures cost different things, which is why
`dgpy_install.sh` distinguishes them:

- `spatialnde2_ec_functions` is **required**. `ec_acquisition.dpi` imports it at
  its top, so a failure exits 1 rather than moving a compiler error into the
  middle of a scan config.
- `spatialnde2_cpp_calibration_function` is **optional** — only
  `dgpython-opencv-camera/demos/camera.dgp` imports it. Its failure warns and
  exits **2**, and `--phase python` carries on for exit 2 and stops for anything
  else. Otherwise one unbuildable optional extra would make a bootstrap impossible
  to finish on a machine where every instrument module built.

---

## Measured cost

Ubuntu 22.04.5, 16 cores, 28 GB RAM (17 GB free at the time), NVMe, gigabit LAN,
no usable GPU. 2026-09-30, `site` layer with `--with-sofa`, from `git clone` to a
running cell.

ROS Iron, the Azure Kinect SDK and NI-DAQmx were **already installed** on this
machine, so the apt figures below are a top-up. Add roughly 20 minutes and 3 GB
for ROS itself on a machine that has never had it.

| step | wall clock |
|---|---|
| `git clone` this repository | 1 s (480 KB) |
| `sim prereqs` (apt top-up, the `bpy` wheel, `rosdep update`) | 2 min |
| `sim sources --with-sofa` (9 repositories + the 1.3 GB SOFA release) | ~1 min |
| `sim rosdep` | 10 s |
| `sim build` — 36 packages, 8 workers | **5 min 28 s** |
| `acq` sources + rosdep | 15 s |
| `acq python` — spatialnde2 cmake build and install, then the stack | **3 min 10 s** |
| `acq build` — nothing new | 4 s |
| `hw` prereqs + sources + rosdep | 10 s |
| `hw python` — the four instrument modules and both extras | 25 s |
| `hw build` — +5 packages | 15 s |
| `site` all seven phases — +6 packages, **47 total** | 25 s |
| **clone to `--layer site --phase verify` exiting 0** | **23 min** |

That 23 minutes is measured elapsed wall clock and includes one failed phase and
its re-run, plus a deliberate second run of `prereqs` and `sources` to prove they
are idempotent. A straight run is a couple of minutes shorter.

Disk, measured as the difference across the bootstrap: **9 GB**, of which 4.9 GB
is `~/tari` itself. (The verification runs afterwards — two cell bring-ups and
the SOFA harness — added about 2 GB more in `~/.ros`, `~/.gazebo` and `SOFAData`.)

| | |
|---|---|
| `ros_ws/src/sofa` | 1.3 GB |
| `ros_ws/src` (everything else) | 789 MB |
| `ros_ws/build` | 329 MB |
| `ros_ws/install` | 52 MB |
| `spatialnde2` (source plus its cmake build tree) | 2.4 GB |
| `bpy` in `/usr/local/lib/python3.10/dist-packages` | **1.3 GB** (a 390 MB wheel) |

`--phase build` caps its own parallelism at one worker per 2 GB of *available*
RAM, capped at `nproc`, because colcon's default of one per core runs sixteen
simultaneous MoveIt-scale C++ links and OOM-kills a compiler — the build then
fails with a bare `c++: fatal error: Killed signal terminated program`.
`TARI_COLCON_WORKERS` overrides it. On this machine 17 GB free gave 8 workers.

---

## Real hardware

A cell manifest is data: the robot's IP, which sensors are physically present,
which are welded into the robot description, the topic names per mode, and the
work volume. Ours live in `tari_cell_configs` in the private `tari_site`
repository and are found through `TARI_CELL_PATH`, which `--phase env` writes for
the `site` layer only.

```bash
ros2 run tari_bringup tari_cell_info --cell ex-ur10e-1 --mode hardware
ros2 launch tari_bringup bringup.launch.py cell:=ex-ur10e-1 mode:=hardware
```

`work_volume.hardware` ships as `null` deliberately. It has to be measured by
touching the end-of-arm tooling to the corners of the real cell, because a box
copied from the simulation describes a different room and every consumer
downstream crops to it. Bring-up refuses rather than defaulting.

### Adding a work cell

Add a YAML file. `tari_bringup` searches every package named in `TARI_CELL_PATH`
first and its own `config/cells` last, so a site manifest overrides a shipped one
without editing shared code. Nothing forks.

If something about your cell cannot be expressed in the manifest, that is a gap in
`tari_bringup` and worth fixing there — it is not a reason to copy a launch file,
which is how this project ended up with several divergent uncommitted cells in the
first place.

---

## Known limits

These are things a correct, complete bootstrap still does not give you on Ubuntu
22.04. None of them is a build failure, so nothing in a build log mentions them.

- **SWIG 4.0.2 is too old for spatialnde2's Python directors.** jammy ships
  4.0.2; directors need 4.1.0. The cmake configure says so out loud —

  ```
  SWIG 4.0.2 is older than 4.1.0, so Python directors are disabled.
  measurement_clock and measurement_time will not be subclassable from Python
  ```

  — and `--phase python` repeats the warning. The consequence is real and narrow:
  anything that subclasses `measurement_clock` or `measurement_time` from Python
  to correlate sources by measurement timestamp cannot work, and
  `spatialnde2/test/measurement_clock_python.py` skips. `pip install
  'swig>=4.1,<4.6'` ahead of `--phase python` is the documented way out; it is a
  build-time tool, not part of the runtime install policy.

- **`ultralytics` and `lap` are not installed**, so YOLO is skipped in every mode.
  Deliberate: the wheel closure pulls torch, which is gigabytes and its own CUDA
  decision. Bring-up names it as a `SKIP` whose reason starts with `DELIBERATE:`
  and ends with the command that enables it, which is the behaviour to want
  rather than a fault. It is the only `SKIP` a correct `sim`-layer bring-up
  prints, and the summary line counts it: `17 started, 1 skipped`.

- **setuptools must stay below 80 on Ubuntu 22.04, and the bootstrap holds it
  there.** This is not a preference. `apt`'s `colcon-core` 0.21.3 declares
  `setuptools<80,>=30.3.0`; above 80 `setup.py develop --uninstall` is gone,
  which is what colcon runs for every `ament_python` package under
  `--symlink-install`, so the whole Python half of `ros_ws` fails with
  `error: option --uninstall not recognized` and everything downstream of it
  aborts; and `pkg_resources` goes with it, which breaks `/usr/bin/vcs` and
  `apt`'s `pbr` — and `pbr` is reached through a setuptools entry point, so
  *every* package here then fails metadata generation with
  `ModuleNotFoundError: No module named 'pkg_resources'`. `--phase prereqs`
  reports a machine that is above the ceiling and `--phase python` pins it back
  into the 64–79 window. If something else on the machine upgrades it again,
  all of the above returns at once; `sudo python3 -m pip install
  'setuptools>=64,<80'` is the repair.

  **Unless it is in your own home, in which case `sudo` cannot reach it.** The
  first cell run carried `setuptools` 84.0.0 in
  `/home/lesthatj/.local/lib/python3.10/site-packages`. The python phase pinned
  the system copy as designed, the user site directory still precedes it on
  `sys.path`, and the colcon build that followed loaded 84 anyway — visible in
  its own stderr as
  `.local/lib/python3.10/site-packages/setuptools/_distutils`. So the prereqs
  phase now prints **where** `setuptools` was found, and when that is your home
  it prints the unprivileged command instead:

  ```bash
  python3 -m pip uninstall -y setuptools      # no sudo; it is yours
  ```

  On a shared machine this has to be done for every account that runs builds:
  whichever `~/.local` wins is whoever is logged in.

- **`pyquaternion` and `trimesh` come from pip, not apt** — no Ubuntu package and
  no rosdep key exists for either under any spelling, so only `--phase prereqs`
  installs them. `trimesh` is pinned below 4: the current release needs a newer
  numpy than the 1.21.5 that `python3-open3d` 0.14.1 is built against, and fails
  at import with `'numpy._DTypeMeta' object is not subscriptable`. Do not fix that
  by upgrading numpy.

- **`bpy` comes from Blender's own index, not from PyPI.** jammy's `blender` 3.0.1
  installs no Python module (`dpkg -L blender` lists nothing named `bpy`) and PyPI
  has no matching wheel, which is what makes a plain `pip install bpy` fail and
  made this look impossible for a long time. Blender publish
  `--extra-index-url https://download.blender.org/pypi/`, which serves
  `bpy-4.0.0-cp310-cp310-manylinux_2_28_x86_64.whl`; `--phase prereqs` installs it
  from the `sim` layer up. Two consequences: it is a 390 MB wheel that unpacks to
  **1.3 GB** on disk — the largest single thing this bootstrap installs outside
  SOFA — and it declares `Requires-Python: ==3.10.*` exactly, so it resolves on
  jammy and on nothing newer. A machine on a later Python needs Blender's own
  interpreter, and `tari_mesh_filter_srv` and `x3d_converter` do not run there.

  Three of its four dependencies come from apt so that pip cannot choose versions
  on behalf of the whole machine. The fourth, `zstandard`, **has no Ubuntu 22.04
  package**: `python3-zstandard` does not exist, and `python3-zstd` is a different
  binding providing the module `zstd`. It is pip-installed alongside bpy,
  `--no-deps` like everything else. Only bpy's `blend_render_info` imports it, and
  lazily, so the mesh API and `bpy.ops.uv.smart_project` work without it.

- **`rosdep` has blind spots, and `--phase prereqs` covers them by hand.** A
  plugin named only as a string in a YAML file or a launch file appears in no
  `package.xml`, so no `rosdep` run installs it. `pick_ik` is the one that costs
  the most: MoveIt loads it by name out of
  `tari_ur_description/config/kinematics.yaml`, and without it `move_group` comes
  up with no IK solver and every scan pass moves 0 mm — a planning-shaped symptom
  for a packaging fault. It and the others are declared as `exec_depend` and
  checked by `tari_bringup/test/test_plugin_dependencies.py`.

  Do not use `rosdep keys --from-paths src --ignore-src` to audit this.
  `--ignore-src` silently ignores any key that is already an installed ament
  package, so on a machine with the ROS desktop it returns 24 keys rather than 120
  and `pick_ik` is absent whether or not anything declares it. Take the overlay
  out of the question instead:

  ```bash
  ROS_DISTRO=iron env -u AMENT_PREFIX_PATH -u ROS_PACKAGE_PATH -u CMAKE_PREFIX_PATH \
      rosdep keys --from-paths ros_ws/src --ignore-src --rosdistro iron | sort -u
  ```

- **Two rosdep keys are skipped on purpose**, each with its reason written next to
  `ROSDEP_SKIP_KEYS` in `tari.bash`: `libvtk`, whose generic key resolves to
  `libvtk7-dev` on jammy and which apt would satisfy by *removing* the VTK 9 that
  `noether_tpp` requires (`find_package(VTK 9 REQUIRED)`); and `catkin`, from
  third-party `libsocket`'s ROS 1 manifest, which has no rule under a ROS 2
  distribution. A key with no rule makes rosdep drop that package's entire key set
  and exit non-zero, which stops the phase.

- **A cross-layer `$(find …)` in a xacro is a build that works and a cell that
  does not start.** `tari_ur_description`'s Azure macro used to take its meshes
  from `$(find azure_kinect_ros_driver)`, a `hw` package, while the shipped `sim`
  manifest welds the Azure into the URDF — so a sim-only machine died at `xacro`
  with `PackageNotFoundError` and Gazebo, MoveIt and `move_group` never started.
  Fixed: the meshes live in `tari_ur_description` now. The generalisation is what
  matters, because the same fault was fixed once one level up and left at the
  next: **a gate protects an include, not what is inside the file it includes.**
  `tari_bringup/test/test_description_dependencies.py` is the static regression
  test and needs no ROS; `tari_cell_info` answers it at run time.

- **Hardware drivers build and then do nothing without their devices.**
  `azure_kinect_ros_driver` with no camera stays up and publishes nothing;
  `keyence_experimental` reconnects in a loop. That is the drivers behaving
  correctly, not a bootstrap fault.

- **A machine without a working GPU driver runs OpenCL on PoCL/CPU**, which is
  why `pocl-opencl-icd` is in the prereq list rather than left to a driver.
  `ocl-icd-opencl-dev` supplies the `libOpenCL.so` that spatialnde2 links, but no
  driver — and with no working ICD, `clGetPlatformIDs` returns
  `PLATFORM_NOT_FOUND_KHR` and `snde.setup_opencl()` raises, which every `.dgp`
  here calls.

## Current state

```bash
./tari.bash --check-remotes
```

That tests every manifest URL and tells you which resolve. As of 2026-09-30, from
a deleted workspace and a bare clone: every URL resolves, all 47 colcon packages
build, `--layer site --phase verify` exits 0, `dgpy_install.sh --check` reports
every package matching its checked-out commit, both Cython extras are in the math
function registry, and the simulated `ex-ur10e-1` cell comes up — 30 nodes, 66
topics, both controllers active, MoveIt solving IK and planning, and the arm
moving in Gazebo when the trajectory is executed.
