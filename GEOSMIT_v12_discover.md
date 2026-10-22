<div align="center">

<sub>NCCS DISCOVER · BUILD &amp; EXPERIMENT GUIDE</sub>
<h1>GEOS–MITgcm v12</h1>
<p><strong>C180 atmosphere · LLC270 ocean · CICE4</strong></p>
<p><code>tcsh / csh</code> &nbsp;·&nbsp; <code>Intel / MPI</code> &nbsp;·&nbsp; <code>c180_llc270_01</code></p>

</div>

Build the coupled model from a clean HTTPS checkout, install the custom MIT configuration, and create a Discover experiment.

> [!TIP]
> Use the **Copy** button at the upper-right of each command block. All commands are visible and use **tcsh/csh** syntax. Run each step only after the previous step succeeds.

## Workflow

| **01–03 · Prepare** | **04 · Build** | **05–07 · Set up and run** |
| :--- | :--- | :--- |
| Clone the source and apply custom files on a **login node**. | Configure and compile in an **allocated compute-node session**. | Create the experiment, stage initial conditions, and submit with **Slurm**. |

## On this page

1. [Load the tools and clone GEOSgcm](#1-load-the-tools-and-clone-geosgcm)
2. [Clone the component repositories](#2-clone-the-component-repositories)
3. [Select the updated setup script and install custom source files](#3-select-the-updated-setup-script-and-install-custom-source-files)
4. [Configure and build on a compute node](#4-configure-and-build-on-a-compute-node)
5. [Create the experiment](#5-create-the-experiment)
6. [Stage the supplied resources and initial conditions](#6-stage-the-supplied-resources-and-initial-conditions)
7. [Submit the experiment](#7-submit-the-experiment)

## Configuration

| Setting | Value |
| --- | --- |
| GEOSgcm branch | `feature/rc31_coupled_dev` |
| GEOSgcm_App branch | `feature/update-mit-setup` |
| Atmosphere | C180, 91 vertical levels |
| Ocean | MITgcm LLC270, 50 vertical levels |
| Sea ice | CICE4 |
| MIT configuration | `c180_llc270_01` |
| Custom files | `/gpfsm/dnb10/projects/p118/afahad/GEOSv12/files` |
| Example experiment ID | `test_GEOSMITv12` |

**Before you begin:** start with a new `GEOSgcm` directory. If that directory already exists, preserve it under another name before cloning.

---

## 1. Load the tools and clone GEOSgcm

<sub>LOGIN NODE · SOURCE CHECKOUT</sub>

Run on a Discover login node with internet access:

```tcsh
module use -a /discover/swdev/gmao_SIteam/modulefiles-SLES15
module load GEOSenv

cd /discover/nobackup/projects/GEOS_MITgcm/afahad/GEOSv12/GEOS_test

git clone --filter=blob:none --branch feature/rc31_coupled_dev \
  https://github.com/GEOS-ESM/GEOSgcm.git GEOSgcm

cd GEOSgcm
set geos_root = "$cwd"
git remote -v
```

**Check:** both `origin` entries should use `https://github.com/GEOS-ESM/GEOSgcm.git`.

---

## 2. Clone the component repositories

<sub>LOGIN NODE · DEPENDENCIES</sub>

```tcsh
mepo config set clone.partial blobless
env PYTHONUNBUFFERED=1 GIT_TRACE="$geos_root/mepo-clone.trace" mepo clone
mepo status
```

Wait for `mepo clone` to finish before running `mepo status`. Tagged components normally appear with `(DH)`, meaning detached HEAD. The untracked `mepo-clone.trace` file is a diagnostic log.

If cloning fails, resolve that failure before continuing. A partially cloned component may have a `.git` directory without a valid `HEAD`.

---

## 3. Select the updated setup script and install custom source files

<sub>LOGIN NODE · CUSTOM SOURCE FILES</sub>

### Select the application branch

Switch the application repository to the updated MIT setup branch:

```tcsh
cd "$geos_root/src/Applications/@GEOSgcm_App"
git checkout feature/update-mit-setup
cd "$geos_root"
```

### Define the source paths

Define the custom-file location and MIT plugin directory:

```tcsh
set geos_files = "/gpfsm/dnb10/projects/p118/afahad/GEOSv12/files"
set mit_plugin = "$geos_root/src/Components/@GEOSgcm_GridComp/GEOSogcm_GridComp/@GEOS_OceanGridComp/MIT_GEOS5PlugMod"
```

### Apply the custom configuration and source files

> [!IMPORTANT]
> Copy all supplied files **before running CMake or compiling**. This includes both `GEOS_OgcmGridComp.F90` and `GEOS_OceanGridComp.F90`.

Run the following copy commands:

```tcsh
\cp -R "$geos_files/c180_llc270_01" "$mit_plugin/configs/"

\cp "$geos_files/CMakeLists.txt" "$mit_plugin/CMakeLists.txt"
\cp "$geos_files/build_options.intel" "$mit_plugin/mitgcm_setup/build_options.intel"

\cp "$geos_files/GEOS_OgcmGridComp.F90" \
  "$geos_root/src/Components/@GEOSgcm_GridComp/GEOSogcm_GridComp/GEOS_OgcmGridComp.F90"

\cp "$geos_files/GEOS_OceanGridComp.F90" \
  "$geos_root/src/Components/@GEOSgcm_GridComp/GEOSogcm_GridComp/@GEOS_OceanGridComp/GEOS_OceanGridComp.F90"

\cp "$geos_files/gc2gc.F90" \
  "$geos_root/src/Components/@GEOSgcm_GridComp/gc2gc.F90"

\cp "$geos_files/xmakedepend" "$mit_plugin/@mit/tools/xmakedepend"
chmod u+x "$mit_plugin/@mit/tools/xmakedepend"
```

### Check the MIT dimensions

Confirm that the supplied `configs/c180_llc270_01/code/SIZE.h` uses the intended dimensions:

```text
sNx = 30     sNy = 30
nSx = 1      nSy = 1
nPx = 768    nPy = 1
Nr  = 50
```

---

## 4. Configure and build on a compute node

<sub>COMPUTE NODE · COMPILE &amp; INSTALL</sub>

### Load the build environment

Continue in an allocated Discover compute-node session. Re-establish the paths and load the compiler, MPI, and Baselibs environment in that session:

```tcsh
module use -a /discover/swdev/gmao_SIteam/modulefiles-SLES15
module load GEOSenv

cd /discover/nobackup/projects/GEOS_MITgcm/afahad/GEOSv12/GEOS_test/GEOSgcm
set geos_root = "$cwd"

source "$geos_root/@env/g5_modules"
setenv BASELIBS "$BASEDIR"

which ifort icc mpif90
printenv BASEDIR BASELIBS MPIHOME
```

Check that the required compilers and library paths are available. If a compiler or a path required by the supplied `build_options.intel` is missing, resolve the environment before building.

### Configure MITgcm

Configure a new build directory:

```tcsh
mkdir -p "$geos_root/build"
cd "$geos_root/build"

cmake .. \
  -DBASEDIR="$BASEDIR/Linux" \
  -DCMAKE_INSTALL_PREFIX="$geos_root/install" \
  -DBUILD_MIT_OCEAN=ON \
  -DMIT_CONFIG_ID=c180_llc270_01 \
  -DCMAKE_Fortran_COMPILER=ifort
```

### Compile and install

After CMake completes successfully, compile and install using an allocation with at least 12 CPUs:

```tcsh
make -j 12 install
```

### Verify the installation

Verify the selected configuration and installed executable:

```tcsh
grep -E '^(BUILD_MIT_OCEAN|MIT_CONFIG_ID):' CMakeCache.txt
ls -lh "$geos_root/install/bin/GEOSgcm.x"
```

**Expected result:** the cache reports `BUILD_MIT_OCEAN=ON` and `MIT_CONFIG_ID=c180_llc270_01`, and `install/bin/GEOSgcm.x` exists.

---

## 5. Create the experiment

<sub>INSTALLED MODEL · EXPERIMENT SETUP</sub>

Run the installed setup script:

```tcsh
cd "$geos_root/install/bin"
./gcm_setup
```

Use the following answers for the example experiment. **Enter** means accept the displayed default; confirm that it matches the value shown here.

### Experiment and atmosphere

| Prompt | Answer |
| --- | --- |
| Experiment ID | `test_GEOSMITv12` |
| One-line description | `GEOS v12 C180 / MITgcm LLC270 with CICE4` |
| Clone an old experiment | `NO` |
| Atmospheric horizontal resolution | `c180` |
| Atmospheric vertical resolution | `91` |
| Microphysics | `BACM_1M` |
| IOSERVER | Enter: `YES` |
| Processor type | Enter: `mil` |

### Ocean and sea ice

| Prompt | Answer |
| --- | --- |
| Coupled ocean/sea-ice model | `YES` |
| Ocean model | `MIT` |
| MITgcm LLC ocean resolution | `llc270` |
| Sea-ice model | `CICE4` |
| Ocean vertical resolution | `50` |
| Data atmosphere | Enter: `NO` |

### Boundary conditions and experiment paths

| Prompt | Answer |
| --- | --- |
| Land surface boundary conditions | Enter: `v14` |
| Land surface model | Enter: `1` — Catchment |
| Actual or climatological aerosols | Enter: `A` — actual |
| GOCART emissions | Enter: `AMIP` |
| Heartbeat | Enter: `450` seconds |
| HISTORY template | Enter: `HISTORY.AOGCM_MITgcm.rc.tmpl` |
| HOME directory | `/discover/nobackup/projects/GEOS_MITgcm/afahad/g12exp/test_GEOSMITv12` |
| EXPERIMENT directory | Same as HOME for this example |
| Build/install directory containing `bin/`, `etc/`, and `include/` | The full path to `GEOSgcm/install` |
| Group ID | `s2826`, if this is the authorized account for the experiment |

The recorded setup uses boundary-condition profile `G12_t4_MITC4`; confirm that the updated setup script displays this profile for the intended experiment.

The microphysics choice above intentionally follows the supplied transcript: `BACM_1M` is explicitly selected even though the displayed default for 91 levels is `GFDL_1M`.

**Check:** setup reports `Done!` and copies `GEOSgcm.x` into the experiment directory.

---

## 6. Stage the supplied resources and initial conditions

<sub>EXPERIMENT DIRECTORY · RESOURCES &amp; RESTARTS</sub>

```tcsh
cd /discover/nobackup/projects/GEOS_MITgcm/afahad/g12exp/test_GEOSMITv12
set geos_files = "/gpfsm/dnb10/projects/p118/afahad/GEOSv12/files"

if ( -e AGCM.rc ) \cp -p AGCM.rc AGCM.rc.setup-original
if ( -e linkbcs ) \cp -p linkbcs linkbcs.setup-original

\cp "$geos_files/AGCM.rc" .
\cp "$geos_files/linkbcs" .
\cp -R "$geos_files/mit_input" .
\cp "$geos_files"/GEOS_IC/* .
```

Confirm that these supplied resources and initial conditions match C180, LLC270, 91 atmosphere levels, 50 ocean levels, and CICE4. The supplied `AGCM.rc` replaces the generated settings, so verify its processor layout and physics selections before launching.

For this configuration, the expected atmosphere layout is `NX=8`, `NY=96`; the ocean layout is `768 × 1`. Both correspond to 768 model MPI ranks. Account for any additional IOSERVER ranks in the generated job script rather than assuming the total allocation is exactly 768.

---

## 7. Submit the experiment

<sub>SLURM · LAUNCH &amp; MONITOR</sub>

Review `gcm_run.j` for the intended project account, processor constraint, processor count, walltime, and experiment paths. Then submit:

```tcsh
sbatch gcm_run.j
squeue -u "$USER"
```

Inspect the job output and model logs after startup to confirm that the executable, resources, boundary conditions, and initial conditions were loaded successfully.

---

## Build and experiment locations

| Artifact | Location |
| --- | --- |
| CMake configuration | `$geos_root/build/CMakeCache.txt` |
| Installed executable | `$geos_root/install/bin/GEOSgcm.x` |
| Experiment scripts, resources, and output | `/discover/nobackup/projects/GEOS_MITgcm/afahad/g12exp/test_GEOSMITv12` |

[Back to the workflow](#workflow)
