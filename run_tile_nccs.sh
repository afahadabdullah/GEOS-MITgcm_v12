#!/bin/bash
#SBATCH --job-name=c180_llc270_tile
#SBATCH --account=CHANGE_ME              # e.g. s1234 -- see `id -Gn` or your project PI
#SBATCH --constraint=mil                 # mil (Milan) or cas (Cascade Lake)
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=8:00:00
#SBATCH --output=%x.%j.out
#SBATCH --error=%x.%j.err
#
# Generate a GEOS v12 C180 + MITgcm LLC270 tile.data on NCCS Discover.
#
# Submit:   sbatch run_tile_nccs.sh
# Watch:    squeue -u $USER  /  tail -f c180_llc270_tile.<jobid>.out
#
# CombineRasters.x is serial but memory-hungry at -t 5000000, and the raster
# repair copies two 3.7 GB rasters, so this wants a whole node and real scratch
# space -- do not run it on a login node.

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Paths -- edit these
# ---------------------------------------------------------------------------
PROJECT=/gpfsm/dnb10/projects/p118/afahad

# All three scripts live in the work directory alongside each other.
WORK_ROOT=$PROJECT/GEOSv12/v12mit_tile_work
SCRIPT_DIR=$WORK_ROOT

GEOSDIR=$PROJECT/GEOSv12/GEOSgcm/install
BIN_DIR=$GEOSDIR/bin
OUTPUT_FILE=$WORK_ROOT/tile_out/tile.data                # must NOT already exist

# Land geometry. Note the directory name: this bundle was built for the C180 +
# MOM6 tripolar 1440x1080 pairing, which is exactly why its water mask
# disagrees with LLC270 at estuaries and fjords. That mismatch is what leaves
# undefined pixels in the LLC raster; fill_llc_raster.py resolves them.
LAND_GEOM=/discover/nobackup/projects/gmao/geos_itv/skhani/Ocean_Bathymetry/NEW_LAND_BC_TEST/v13/geometry/CF0180x6C_M6TP1440x1080
LAND_TIL=$LAND_GEOM/til/Pfafstetter.til
LAND_RST=$LAND_GEOM/rst/Pfafstetter.rst

# LLC270 MIT inputs.
LLC270_INPUT=$PROJECT/exp/GEOSMIT_v117/mit_input
DATA_EXCH2=$LLC270_INPUT/data.exch2
LLC_GRID_DIR=$LLC270_INPUT                               # must hold tile001..005.mitgrid

MODULE_INIT=""                                           # optional GEOS env script

# ---------------------------------------------------------------------------
# 2. Environment
# ---------------------------------------------------------------------------
source /usr/share/modules/init/bash 2>/dev/null || true

# numpy is required by fill_llc_raster.py. GEOSpyD ships it; run
#   module avail python
# once to find the exact version string available to you.
module load python/GEOSpyD 2>/dev/null || \
    echo "WARNING: could not module load python/GEOSpyD -- relying on PATH python3"

export PYTHON_BIN=${PYTHON_BIN:-python3}
"$PYTHON_BIN" -c 'import numpy; print("numpy", numpy.__version__)'

export OMP_NUM_THREADS=1

# ---------------------------------------------------------------------------
# 3. Preflight
# ---------------------------------------------------------------------------
mkdir -p "$WORK_ROOT" "$(dirname "$OUTPUT_FILE")"

echo "=== free space on work root ==="
df -h "$WORK_ROOT"
echo "(the run needs roughly 25 GB: four 3.7 GB rasters plus tile files)"

[[ -e "$OUTPUT_FILE" ]] && {
    echo "ERROR: $OUTPUT_FILE exists; the generator refuses to overwrite." >&2
    exit 1
}

# ---------------------------------------------------------------------------
# 4. Generate
# ---------------------------------------------------------------------------
cmd=(
    bash "$SCRIPT_DIR/generate_geosv12_c180_llc270_tile.sh"
    --bin-dir      "$BIN_DIR"
    --land-til     "$LAND_TIL"
    --land-rst     "$LAND_RST"
    --llc-grid-dir "$LLC_GRID_DIR"
    --data-exch2   "$DATA_EXCH2"
    --work-root    "$WORK_ROOT"
    --output       "$OUTPUT_FILE"
    --raster-filler "$SCRIPT_DIR/fill_llc_raster.py"
)
[[ -n "$MODULE_INIT" ]] && cmd+=(--module-init "$MODULE_INIT")

echo "=== running ==="
printf ' %q' "${cmd[@]}"; echo
time "${cmd[@]}"

echo "=== done: $OUTPUT_FILE ==="
ls -l "$OUTPUT_FILE"
