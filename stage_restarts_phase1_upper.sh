#!/bin/bash
# ---------------------------------------------------------------------------
# Phase 1 of the GEOS v12 MOM6+CICE4 -> MITgcm+CICE4 restart migration.
#
# Copies ONLY the restarts that need no regrid and no vertical remap: the
# upper-air / AGCM-grid files. Both experiments are c180 x 91L, and these
# files live on the cubed sphere and never reference tile space, so they
# transfer byte-for-byte.
#
# Everything tile-space (land, saltwater, sea ice) is deliberately left for
# phase 2, which needs the target CF0180x6C_MITLLC23040x0030 tile file.
#
# Usage:  ./stage_restarts_phase1_upper.sh SRC_DIR DST_DIR
#         ./stage_restarts_phase1_upper.sh --check-only SRC_DIR
# ---------------------------------------------------------------------------
set -u

CHECK_ONLY=0
if [[ "${1:-}" == "--check-only" ]]; then
    CHECK_ONLY=1
    shift
fi

SRC="${1:?usage: $0 [--check-only] SRC_DIR [DST_DIR]}"
DST="${2:-}"
if [[ $CHECK_ONLY -eq 0 && -z "$DST" ]]; then
    echo "usage: $0 SRC_DIR DST_DIR" >&2
    exit 1
fi

# --- The 24 AGCM-grid restarts -------------------------------------------
UPPER="
achem_internal
aiau_import
cabc_internal
cabr_internal
caoc_internal
du_internal
fvcore_internal
gocart_import
gocart_internal
gwd_import
hemco_import
hemco_internal
irrad_internal
moist_import
moist_internal
ni_internal
pchem_internal
solar_internal
ss_internal
su_internal
surf_import
tr_import
tr_internal
turb_import
turb_internal
"

# --- Files intentionally excluded, with the reason ------------------------
# Verified against G12_t3_MOM6C4 dimensions.
declare -A EXCLUDED=(
  [ocean_internal]="ocean grid 1440x1080; MITgcm uses pickups in mitocean_run/"
  [seaice_import]="ocean grid 1440x1080; take from v11.7 MIT (already LLC270)"
  [catch_internal]="tile 684752  - regrid from MOM6 .til"
  [lake_internal]="tile 32725   - regrid from MOM6 .til"
  [landice_internal]="tile 6836    - regrid from MOM6 .til"
  [openwater_internal]="tile 1893385 - regrid from v11.7 MIT .til"
  [seaicethermo_internal]="tile 1893385 - regrid from v11.7 MIT .til"
  [saltwater_import]="tile 1893385 - regrid from v11.7 MIT .til"
)

hr() { printf '%.0s-' {1..72}; echo; }

# --- Pre-flight: verify each file really is AGCM grid ---------------------
echo "Pre-flight: dimensions of candidate upper-air restarts in"
echo "  $SRC"
hr
suspect=0
missing=0
for f in $UPPER; do
    file="$SRC/${f}_rst"
    if [[ ! -f "$file" ]]; then
        printf "%-24s *** MISSING ***\n" "$f"
        missing=$((missing + 1))
        continue
    fi
    dims=$(ncdump -h "$file" 2>/dev/null \
           | sed -n '/^dimensions:/,/^variables:/p' \
           | grep -E '\b(tile|Xdim|Ydim|lev|edge|nf|lon|lat)\b' \
           | tr -d '\t' | tr '\n' ' ')
    printf "%-24s %s\n" "$f" "${dims:-<ncdump unavailable>}"
    if [[ "$dims" == *"tile "* || "$dims" == *"tile="* ]]; then
        echo "    ^^ WARNING: tile dimension found - this is NOT upper air."
        suspect=$((suspect + 1))
    elif [[ "$dims" == *"lon = 1440"* ]]; then
        echo "    ^^ WARNING: lon=1440 is the MOM6 ocean grid, not the AGCM grid."
        suspect=$((suspect + 1))
    fi
done
hr

if [[ $missing -gt 0 ]]; then
    echo "ERROR: $missing expected restart(s) not found in $SRC" >&2
    exit 1
fi
if [[ $suspect -gt 0 ]]; then
    echo "ERROR: $suspect file(s) carry a tile dimension. Move them to the" >&2
    echo "       phase-2 regrid list before proceeding." >&2
    exit 1
fi
echo "All $(echo $UPPER | wc -w) files look like AGCM-grid restarts."
echo

if [[ $CHECK_ONLY -eq 1 ]]; then
    echo "--check-only given; nothing copied."
    exit 0
fi

# --- Copy -----------------------------------------------------------------
mkdir -p "$DST"
echo "Copying to $DST"
hr
for f in $UPPER; do
    cp -a "$SRC/${f}_rst" "$DST/${f}_rst"
done

# --- Verify sizes match ---------------------------------------------------
fail=0
for f in $UPPER; do
    s=$(stat -c%s "$SRC/${f}_rst")
    d=$(stat -c%s "$DST/${f}_rst")
    if [[ "$s" == "$d" ]]; then
        printf "OK    %-24s %12s bytes\n" "$f" "$s"
    else
        printf "FAIL  %-24s %s != %s\n" "$f" "$s" "$d"
        fail=$((fail + 1))
    fi
done
hr

if [[ $fail -gt 0 ]]; then
    echo "ERROR: $fail file(s) failed the size check." >&2
    exit 1
fi
echo "Phase 1 complete: $(echo $UPPER | wc -w) restarts staged."
echo

# --- Remind what still has to happen --------------------------------------
echo "Still outstanding (phase 2, needs the target tile file):"
hr
for f in "${!EXCLUDED[@]}"; do
    printf "  %-24s %s\n" "$f" "${EXCLUDED[$f]}"
done | sort
echo
echo "  geosgcm_*_rst, tavg*_rst   HISTORY collection restarts - do not copy,"
echo "                             HISTORY regenerates them on segment 1."
