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

Ubuntu 22.04, or WSL2 running Ubuntu 22.04, with [ROS 2
Iron](https://docs.ros.org/en/iron/Installation.html) installed from the
official apt repository. Roughly 12 GB of disk for the simulation layer. No GPU
is required — Gazebo will fall back to software rendering, slowly.

> You may find Docker tooling (`ros2_docker.sh`, `entrypoint.sh`, `docker/`)
> sitting next to this repository on an existing machine. **It is not part of
> this repository and you do not need it.** It exists because one development
> machine runs Arch, where ROS Iron is not packaged, and it is not how this
> stack is meant to be deployed. Everything below installs natively.

> Iron reached end of life in December 2024. Nothing here depends on Iron
> specifically, but the move to an LTS distribution is owed.

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

### Installs are not editable

Every Python package is installed with `pip install --no-deps
--no-build-isolation`. Editing a source file therefore changes nothing until you
reinstall, and nothing tells you so. Two things make that manageable:

```bash
./dgpy_install.sh --check
```

Every package carries a `setuptools_scm` version embedding the commit it was
built from, so this reports exactly which installed copies no longer match the
source you have checked out — including copies built from a dirty tree, which
match no commit at all.

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
   22.04 the packages come from the 18.04 pool. It requires accepting a licence,
   so it cannot be automated.
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
failing is expected; anything else failing is a real fault.
