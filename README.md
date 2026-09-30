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

### Repository naming

A repository name and the directory it is checked out into are not the same
string, on purpose.

`_staging` marks a private repository for internal development that is not yet
ready for public release. A CI/CD pipeline will be responsible for promoting to
public; that does not exist yet. `_private` marks something that is not on a
path to public release at all — site data, proprietary formats.

**The manifests always check out into the name without the suffix**, so the
working tree is named for what a package set *is* rather than for its release
state, and nothing has to be renamed when a repository is promoted.

ROS and colcon-managed repositories use underscores throughout, matching ROS
convention. The dataguzzler modules keep the dataguzzler convention instead:
dashes in the repository name, underscores in the package name — so
`dgpython-uniwest` on disk provides `dgpython_uniwest` to Python.

## What you need

Ubuntu 22.04, or WSL2 running Ubuntu 22.04, and `sudo`. Roughly 12 GB of disk
for the simulation layer, plus about 3 GB for ROS itself. No GPU is required —
Gazebo will fall back to software rendering, slowly.

**You do not need to install ROS 2 Iron first.** `tari.bash --phase prereqs`
adds the ROS apt repository and installs it, along with `colcon`, `vcstool` and
`rosdep`. It has to do them in that order: those three are not in Ubuntu
universe, they come only from the ROS repository, so there is no way to install
them on a bare machine before the repository exists.

Two things about Iron are worth knowing before you start.

- **Iron reached end of life in November 2024, but its packages are still
  published.** As of 2026-09-30 the jammy index carries 2164 `ros-iron-*`
  binaries, frozen at their November 2024 builds, including everything here.
  End of life means nothing new will appear, not that the suite has been
  withdrawn. `rosdep` still knows Iron. The move to an LTS distribution is
  nonetheless owed.
- **The apt repository is added by upstream's own package, not by a
  hand-written sources list.** Open Robotics now ship a versioned
  `ros2-apt-source` deb that installs the signing key and the `.list` file
  together, and `tari.bash --phase prereqs` fetches the current release of it
  from GitHub and installs it. The key rotating or the host moving is then
  upstream's problem rather than a fingerprint going stale in this repository.

  It also steps around a live fault: `https://packages.ros.org` is a CNAME to
  `ftp.osuosl.org`, which presents a certificate covering only `osuosl.org` and
  `*.osuosl.org`, so the SNI never matches and every TLS client refuses it, on
  IPv4 and IPv6 alike:

  ```
  curl: (60) SSL: no alternative certificate subject name matches
        target host name 'packages.ros.org'
  ```

  The deb comes from GitHub releases over HTTPS with a valid certificate, and
  apt still authenticates the repository itself by the detached GPG signature on
  `InRelease` — which is why an unsigned or keyless workaround is never
  acceptable here, whatever the transport is doing.

> **On a shared machine, expect to replace an existing install.**
> `spatialnde2` and `dataguzzler-python` are shared upstream projects, and
> `dgpy_install.sh` installs them system-wide. Another project on the same
> machine can perfectly well have its own checkout of either — usually an
> earlier version of the same code. Converging on one version is the point, so
> the installer replaces it and says which tree the previous copy came from:
>
>     warning: spatialnde2 was installed from /usr/local/src/spatialnde2/build,
>              not from /home/you/tari -- replacing it.
>
> That warning is expected and is not a reason to stop. Note also that
> `spatialnde2`, `dataguzzler-python` and several `dgpython-*` modules
> legitimately have `isuthermography` remotes rather than this organisation's —
> a collaboration, not a foreign package.
>
> **Look for a pip-installed Qt before building.** spatialnde2 compiles against
> the system Qt (`qtbase5-dev`, `python3-pyqt5`, both from apt). A pip Qt wheel
> is a second complete Qt inside `site-packages` — `PyQt6-Qt6` alone is 260 MB
> of `libQt6*.so.6` with its own `sip` — and both `dataguzzler_python/Qt.py` and
> spatialnde2's `snde_qt.i` typemaps choose bindings by what is importable or
> already loaded, so a stray one changes which Qt a Qt5-compiled library talks
> to. `tari.bash --phase python` warns about any it finds; clear them first:
>
>     sudo python3 -m pip uninstall PyQt6 PyQt6-Qt6 PyQt6_sip

> You may find Docker tooling (`ros2_docker.sh`, `entrypoint.sh`, `docker/`)
> sitting next to this repository on an existing machine. **It is not part of
> this repository and you do not need it.** It exists because one development
> machine runs Arch, where ROS Iron is not packaged, and it is not how this
> stack is meant to be deployed. Everything below installs natively.

## Quick start — simulation

```bash
git clone git@github.com:Adaptive-Robotic-NDE/tari_workspace_staging.git ~/tari
```

```bash
cd ~/tari && ./tari.bash --layer sim
```

```bash
source ./tari_setup.bash
```

```bash
ros2 launch tari_bringup bringup.launch.py cell:=sim mode:=sim
```

That gives you a UR10e in Gazebo with a simulated Azure Kinect and Keyence
profilometer, MoveIt and the task constructor, Noether toolpath planning, TSDF
reconstruction, mesh filtering and YOLO detection. It needs no hardware and no
access to any private repository.

The bring-up prints every node it started and, for every node it did not, the
reason. That report is the first thing to read when something is missing.

## The four layers

Layers are additive and each is a strict superset of the one before, so
`--layer hw` imports `sim`, then `acq`, then `hw`.

| layer | adds | needs |
|---|---|---|
| `sim` | Gazebo, MoveIt/MTC, Noether, reconstruction, mesh filtering, YOLO, **and both motion action servers** | nothing private, no hardware |
| `acq` | spatialnde2, dataguzzler-python, the scan configurations | a C++17/SWIG/Qt/OSG build, ~20 min |
| `hw` | Azure, Keyence, NI-DAQmx and Uniwest drivers | the devices, and two vendor SDKs |
| `site` | our cell manifests and calibration | org credentials |

`--with-sofa` additionally fetches the 1.3 GB SOFA binary release for the
soft-robotics work. It is off by default and nothing else depends on it.

The line that matters is between `hw` and `site`. Everything up to and including
`hw` can be given to a collaborator; `site` cannot. The only real proof of that
is to clone and build `sim.repos` from an account with no access to org-private
repositories — not a code review.

## What the bootstrap does

Seven phases. Each is idempotent, and any one can be re-run on its own with
`--phase`:

| phase | |
|---|---|
| `prereqs` | apt packages, `rosdep init`/`update`, vcstool, colcon |
| `sources` | `vcs import` of the layer chain, in order |
| `rosdep` | `rosdep install` over `ros_ws/src`; checks vendor SDKs on `hw` |
| `python` | runs `dgpy_install.sh` (acq and above) |
| `build` | one `colcon build --symlink-install` over `ros_ws` |
| `env` | writes `tari_setup.bash` |
| `verify` | checks the layer's packages resolve, and reports install drift |

Use `--dry-run` to see the whole plan without running any of it, and
`--check-remotes` to test that every manifest URL resolves.

### Two build systems, one rule

**colcon owns `ros_ws/src` and nothing else. `dgpy_install.sh` owns the
workspace root.**

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

Not `-e`. Not `--user`. Not a bare `pip install .`. Each part earns its place:

| | |
|---|---|
| `sudo` | System-wide, so one deliberate install is what every shell and every service runs. An unprivileged install lands in `~/.local`, which precedes the system directories on `sys.path` — it silently shadows the real install, and then which shell installed a package decides what the next one runs. |
| `--no-deps` | pip resolves nothing, so it cannot substitute a version nobody chose for one this stack was built against. |
| `--no-build-isolation` | The compiled parts build against the interpreter and headers actually present, rather than against a throwaway environment pip assembles. |
| never `-e` | An editable install makes what runs depend on the state of a working tree rather than on something deliberately installed, so a stale or half-finished checkout becomes the running code with nothing to say so. |

`dgpy_install.sh` runs precisely that command for every package, and
`--dry-run` prints it verbatim before running anything.

**Editing a source file therefore changes nothing until you reinstall, and
nothing tells you so.** That is the intended behaviour, not a problem to work
around: what runs is what was installed. Two things make it manageable:

```bash
./dgpy_install.sh --check
```

Every package carries a `setuptools_scm` version embedding the commit it was
built from, so this reports exactly which installed copies no longer match the
source you have checked out — including copies built from a dirty tree, which
match no commit at all. It also reports the two ways the install itself can be
wrong rather than merely out of date: `EDITABLE`, and `USER-SITE` for a per-user
copy shadowing the system one. Remove that copy (`pip uninstall <name>`) before
reinstalling — a reinstall alone would not change what runs.

Two more states matter. `ABSENT` means the source is not checked out at all,
which on a machine that imported only `acq.repos` is the ordinary state of the
instrument drivers and is not a finding. `BROKEN` means the installed copy
carries exactly the right version and still does not load — the two compiled
packages are import-tested rather than only version-compared, because a matching
version string is not evidence that the shared libraries next to it resolve.

```bash
./dgpy_install.sh --only spatialnde2
```

Reinstall one package, or `--from <name>` for that one and everything after it
in dependency order. A plain `./dgpy_install.sh` reinstalls only what is stale.

### Source `tari_setup.bash` in every shell

Including shells that run dataguzzler-python. `dgpython_rosmotion` is a colcon
package, so `import dgpython_rosmotion` inside a `.dgp` resolves through the ROS
overlay rather than through pip. There is one environment here and it always has
ROS in it.

## Real hardware

Hardware is the `acq` bootstrap plus three things. The first two are vendor SDKs
that `rosdep` structurally cannot supply; `tari.bash --layer hw` checks for both
and stops with instructions rather than building a driver without its SDK.

1. **Azure Kinect Sensor SDK** (`libk4a`) from `packages.microsoft.com`. On
   22.04 the packages come from the 18.04 pool, and `libsoundio1` — which
   `libk4a1.4` hard-depends on and jammy does not carry — has to come from
   focal. `tari.bash --layer hw` prints the whole procedure, command by command,
   and it is worth reading before running: it temporarily adds a *different
   Ubuntu release's* archive to the machine, which is why it is a manual step
   and not automated.

   Two things about it that cost time, both now in the script's printed
   instructions. The focal source must be pinned below jammy
   (`Pin-Priority: 100`) so nothing other than `libsoundio1` can ever be
   satisfied from it. And `libk4a1.4`'s `preinst` calls
   `db_fset accept-eula seen false` *before* asking, so under
   `DEBIAN_FRONTEND=noninteractive` the question cannot be asked at all and the
   install dies with `eula agree question could not be asked`. Preseeding
   `accept-eula` does not help for the same reason; the way through is the
   environment variable the `preinst` checks first, `ACCEPT_EULA=Y`, which
   accepts Microsoft's licence.

   Check it with `find_package(k4a)`, or at least
   `ls /usr/lib/x86_64-linux-gnu/cmake/k4a/k4aConfig.cmake` — a missing
   `k4aConfig.cmake` is exactly how the build fails later, with an error that
   says nothing about a camera. Do not check it by running `k4aviewer`, which
   needs a camera and a display.
2. **NI-DAQmx** from National Instruments, for the eddy-current DAQ.
   Proprietary, x86-64 only.
3. **A cell manifest with measured numbers**, which is not a package install.

A cell manifest is data: the robot's IP, which sensors are physically present,
which are welded into the robot description, the topic names per mode, and the
work volume. Ours live in `tari_cell_configs` in the private `tari_site`
repository and are found through `TARI_CELL_PATH`:

```bash
ros2 launch tari_bringup bringup.launch.py cell:=ex-ur10e-1 mode:=hardware
```

`work_volume.hardware` ships as `null` deliberately. It has to be measured by
touching the end-of-arm tooling to the corners of the real cell, because a box
copied from the simulation describes a different room and every consumer
downstream crops to it. Bring-up refuses rather than defaulting.

To see what a cell will start, without starting it:

```bash
ros2 run tari_bringup tari_cell_info --cell ex-ur10e-1 --mode hardware
```

## Adding a work cell

Add a YAML file. `tari_bringup` searches every package named in
`TARI_CELL_PATH` first and its own `config/cells` last, so a site manifest
overrides a shipped one without editing shared code. Nothing forks.

If something about your cell cannot be expressed in the manifest, that is a gap
in `tari_bringup` and worth fixing there — it is not a reason to copy a launch
file, which is how this project ended up with several divergent uncommitted
cells in the first place.

## Current state

Some repositories referenced by the manifests do not exist yet; each is marked
`PENDING` where it appears, with what it is and why. Until they are created,
`vcs import` reproduces everything except those rows.

```bash
./tari.bash --check-remotes
```

That tests every manifest URL and tells you which resolve. A `PENDING` entry
failing is expected; anything else failing is a real fault. As of 2026-09-30
every URL in every manifest resolves.

### What does not work yet on a clean Ubuntu 22.04

All 47 colcon packages across `sim`, `hw` and `site` build, and the simulated
cell comes up — 26 nodes, MoveIt planning and IK, both controllers active,
Gazebo publishing `/clock` and `/joint_states`. Four things do not, and each is
a missing dependency rather than a build failure, so nothing in a build log
mentions them. Bring-up reports the nodes as started because it checks the graph
before they exit.

- **The `sim` layer alone cannot start the cell.** `tari_ur_description`'s Azure
  macro takes its two meshes from `$(find azure_kinect_ros_driver)`, which is a
  `hw` package, and the shipped `sim` manifest has the Azure welded into the
  URDF — so `xacro` fails with `PackageNotFoundError` and Gazebo, MoveIt and
  `move_group` never start. Import `hw.repos` as well, until the meshes move
  into `tari_ur_description` where the rest of the geometry lives.
- **`bpy` is unobtainable here**, so `tari_mesh_filter_srv` and `x3d_converter`
  cannot run. jammy's `blender` 3.0.1 installs no Python module and PyPI has no
  `bpy` wheel for CPython 3.10 on Linux. They need Blender's own interpreter, or
  a Blender built as a module. Everything that does not do mesh filtering is
  unaffected.
- **`ultralytics` and `lap` are not installed**, so YOLO is skipped. That is
  deliberate: the closure pulls torch. Bring-up names it as a SKIP with the
  reason, which is the behaviour to want.
- **`pyquaternion` and `trimesh` come from pip, not apt** — no Ubuntu package
  and no rosdep key exists for either, so only `tari.bash --phase prereqs`
  installs them. `trimesh` is pinned below 4: the current release needs a newer
  numpy than the 1.21.5 that `python3-open3d` 0.14.1 is built against, and fails
  at import with `'numpy._DTypeMeta' object is not subscriptable`. Do not fix
  that by upgrading numpy.

`ros2plugin` is skipped by every build unless `--with-sofa` was given, and that
is by design; it is the only package in the tree that is not built.
