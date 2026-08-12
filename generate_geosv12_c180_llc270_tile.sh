#!/usr/bin/env bash
# Generate a GEOS v12 C180 + MITgcm LLC270 ASCII tile.data file.
#
# Geometry used here:
#   GEOS v12 C180 atmosphere raster
# + GEOS v12 Pfafstetter/land-mask raster
# + the established LLC270 MIT grid and data.exch2 decomposition
#
# LAI, vegetation dynamics, soil parameters, and CICE restart data are not
# inputs to this script. They must be prepared separately after the geometry
# bundle has been accepted.

set -euo pipefail

SCRIPT_NAME=${0##*/}

BIN_DIR=""
INPUT_DIR=""
MASK_FILE=""
LAND_TIL=""
LAND_RST=""
LLC_GRID_DIR=""
DATA_EXCH2=""
LLC_SNX=""
LLC_SNY=""
MODULE_INIT=""
WORK_ROOT=""
OUTPUT_FILE=""
VALIDATE_ONLY=""
MAX_TILES=5000000
EXPECTED_PFAF=291284
EXPECTED_RASTER_NX=43200
EXPECTED_RASTER_NY=21600
EXPECTED_ATM_IM=180
EXPECTED_ATM_JM=1080
EXPECTED_OCN_IM=23040
EXPECTED_OCN_JM=30
DEEP_VALIDATION=1

# Exchange fractions are written in ASCII and accumulate round-off.  The
# shipped GEOS v12 C180 tile files carry fractions up to 1.0000070271, so a
# 1e-6 tolerance rejects known-good geometry.  1e-4 is loose enough to pass
# production files and tight enough to catch a real conservation failure.
FRACTION_TOL=1.0001

# mkMITAquaRaster.x can leave raster pixels undefined where the GEOS land mask
# says water but the LLC domain has no wet cell.  CombineRasters then emits a
# degenerate sentinel surface tile and every such pixel becomes an ocean record
# with compact index (0,0).  Repair the raster before combining.
REPAIR_RASTER=1
PYTHON_BIN=${PYTHON_BIN:-python3}
RASTER_FILLER=""

# Value marking ocean in Pfafstetter.rst.  Left empty it is derived from the
# Pfafstetter.til tile count (ocean = N+1).  Only pixels that are RASTERUNDEF in
# the LLC raster AND ocean in the land raster are repaired; the ~183M
# RASTERUNDEF pixels covering the land surface are left alone.  Confirm with
#   fill_llc_raster.py --inspect --llc-raster ... --land-raster ...
LAND_OCEAN_VALUE=""

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME \\
    --bin-dir DIR \\
    --land-til FILE \\
    --land-rst FILE \\
    --llc-grid-dir DIR \\
    --data-exch2 FILE \\
    --work-root DIR \\
    --output FILE [options]

Required generation inputs:
  --bin-dir DIR          Directory containing the GEOS make-BC executables
  --llc-grid-dir DIR     Directory containing tile001.mitgrid ... tile005.mitgrid
  --data-exch2 FILE      LLC270 data.exch2 from the target MIT configuration
  --llc-snx N            MIT LLC sub-tile width; auto-derived when omitted
  --llc-sny N            MIT LLC sub-tile height; auto-derived when omitted
  --work-root DIR        Parent directory for a new, retained work directory
  --output FILE          Destination tile.data path; it must not already exist

Land geometry (select exactly one method):
  --land-til FILE        Existing GEOS v12 Pfafstetter.til
  --land-rst FILE        Existing GEOS v12 Pfafstetter.rst
  or
  --input-dir DIR        GEOS v12 MAKE_BCS_INPUT_DIR
  --mask-file NAME       Mask filename under INPUT_DIR/shared/mask

Options:
  --module-init FILE     Source the GEOS environment/module script first
  --max-tiles N          CombineRasters allocation limit (default: $MAX_TILES)
  --expected-pfaf N      Expected catchment count (default: $EXPECTED_PFAF)
  --skip-deep-validation Skip atmospheric fraction-conservation validation
  --validate-only FILE   Validate an existing C180-LLC270 ASCII tile file
  --fraction-tol X       Exchange fraction upper bound (default: $FRACTION_TOL)
  --skip-raster-repair   Do not fill undefined pixels in the LLC raster
  --raster-filler FILE   Path to fill_llc_raster.py (default: next to this script)
  --land-ocean-value N   Pfafstetter.rst ocean marker (default: tile count + 1)
  -h, --help             Show this help

Example:
  $SCRIPT_NAME \\
    --bin-dir /path/to/install/bin \\
    --land-til /path/to/til/Pfafstetter.til \\
    --land-rst /path/to/rst/Pfafstetter.rst \\
    --llc-grid-dir /path/to/LLC270/mitgrid \\
    --data-exch2 /path/to/LLC270/data.exch2 \\
    --work-root /discover/nobackup/$USER/c180_llc270_tile_work \\
    --output /path/to/experiment/tile.data

Validation-only example:
  $SCRIPT_NAME --validate-only /path/to/tile.data
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

note() {
    printf '\n[%s] %s\n' "$SCRIPT_NAME" "$*"
}

require_file() {
    [[ -f "$1" ]] || die "Required file not found: $1"
}

require_dir() {
    [[ -d "$1" ]] || die "Required directory not found: $1"
}

require_executable() {
    [[ -x "$1" ]] || die "Required executable not found or not executable: $1"
}

canonical_dir() {
    (cd "$1" && pwd -P)
}

canonical_file() {
    local input=$1
    local parent
    local base
    parent=$(dirname "$input")
    base=$(basename "$input")
    parent=$(canonical_dir "$parent")
    printf '%s/%s\n' "$parent" "$base"
}

create_mit_exch2_adapter() {
    local source_file=$1
    local destination_file=$2
    local blank_count
    local candidate_snx=""
    local candidate_count=0
    local sx
    local total_tiles
    local active_tiles

    # mkMITAquaRaster.x understands only sNx, sNy, and blankList. The normal
    # MITgcm data.exch2 also contains topology variables (e.g., W2_mapIO and
    # dimsFacets), so use a minimal, reader-compatible copy in this work dir.
    blank_count=$(awk '
        BEGIN { in_list = 0 }
        /^[[:space:]]*[Bb][Ll][Aa][Nn][Kk][Ll][Ii][Ss][Tt][[:space:]]*=/ { in_list = 1 }
        in_list {
            line = $0
            sub(/#.*/, "", line)
            if (line ~ /\//) exit
            sub(/.*=/, "", line)
            count += gsub(/[0-9]+/, "&", line)
        }
        END { print count + 0 }
    ' "$source_file")
    (( blank_count > 0 )) || die "Could not read blankList entries from $source_file"

    if [[ -n "$LLC_SNX" || -n "$LLC_SNY" ]]; then
        [[ -n "$LLC_SNX" && -n "$LLC_SNY" ]] || \
            die "--llc-snx and --llc-sny must be supplied together"
    else
        # For LLC270, the target compact header fixes nCPU*sNx=23040 and
        # sNy=30. Use the source blankList length to identify sNx uniquely.
        LLC_SNY=$EXPECTED_OCN_JM
        for ((sx=1; sx<=270; sx++)); do
            (( 270 % sx == 0 )) || continue
            (( EXPECTED_OCN_IM % sx == 0 )) || continue
            total_tiles=$(( (2 * (270 / sx) * (810 / LLC_SNY)) + \
                            ((270 / sx) * (270 / LLC_SNY)) + \
                            (2 * (810 / sx) * (270 / LLC_SNY)) ))
            active_tiles=$(( EXPECTED_OCN_IM / sx ))
            if (( total_tiles - active_tiles == blank_count )); then
                candidate_snx=$sx
                ((candidate_count += 1))
            fi
        done
        (( candidate_count == 1 )) || \
            die "Could not uniquely derive LLC sNx from $source_file (blankList=$blank_count); pass --llc-snx and --llc-sny from the MIT build SIZE.h"
        LLC_SNX=$candidate_snx
    fi

    [[ "$LLC_SNX" =~ ^[0-9]+$ && "$LLC_SNY" =~ ^[0-9]+$ ]] || \
        die "LLC sNx/sNy must be positive integers"
    (( LLC_SNX > 0 && LLC_SNY > 0 )) || die "LLC sNx/sNy must be greater than zero"
    (( 270 % LLC_SNX == 0 && 270 % LLC_SNY == 0 )) || \
        die "LLC sNx/sNy must divide 270 exactly; received ${LLC_SNX}x${LLC_SNY}"

    total_tiles=$(( (2 * (270 / LLC_SNX) * (810 / LLC_SNY)) + \
                    ((270 / LLC_SNX) * (270 / LLC_SNY)) + \
                    (2 * (810 / LLC_SNX) * (270 / LLC_SNY)) ))
    active_tiles=$(( total_tiles - blank_count ))
    (( active_tiles > 0 )) || die "data.exch2 blankList leaves no active LLC tiles"
    (( active_tiles * LLC_SNX == EXPECTED_OCN_IM && LLC_SNY == EXPECTED_OCN_JM )) || \
        die "LLC ${LLC_SNX}x${LLC_SNY} with blankList=$blank_count produces compact ${active_tiles}x${LLC_SNX}, not required ${EXPECTED_OCN_IM}x${EXPECTED_OCN_JM}"

    {
        printf '&W2_EXCH2_PARM01\n'
        printf ' sNx = %s,\n' "$LLC_SNX"
        printf ' sNy = %s,\n' "$LLC_SNY"
        printf ' blankList =\n'
        awk '
            BEGIN { in_list = 0 }
            /^[[:space:]]*[Bb][Ll][Aa][Nn][Kk][Ll][Ii][Ss][Tt][[:space:]]*=/ {
                in_list = 1
                line = $0
                sub(/#.*/, "", line)
                sub(/.*=/, "", line)
                if (line ~ /[0-9]/) print "  " line
                next
            }
            in_list {
                line = $0
                sub(/#.*/, "", line)
                if (line ~ /\//) exit
                if (line ~ /[0-9]/) print "  " line
            }
        ' "$source_file"
        printf ' /\n'
    } > "$destination_file"

    note "Created minimal LLC data.exch2 adapter (${LLC_SNX}x${LLC_SNY}; $blank_count blank tiles)"
}

trim_header_line() {
    local file=$1
    local line_number=$2
    awk -v target="$line_number" 'NR == target {$1=$1; print; exit}' "$file"
}

validate_tile() {
    local tile=$1
    local declared_tiles
    local declared_pfaf
    local raster_nx
    local raster_ny
    local grid_count
    local grid1
    local grid1_im
    local grid1_jm
    local grid2
    local grid2_im
    local grid2_jm
    local actual_records

    require_file "$tile"
    tile=$(canonical_file "$tile")

    read -r declared_tiles declared_pfaf raster_nx raster_ny < "$tile"
    grid_count=$(trim_header_line "$tile" 2)
    grid1=$(trim_header_line "$tile" 3)
    grid1_im=$(trim_header_line "$tile" 4)
    grid1_jm=$(trim_header_line "$tile" 5)
    grid2=$(trim_header_line "$tile" 6)
    grid2_im=$(trim_header_line "$tile" 7)
    grid2_jm=$(trim_header_line "$tile" 8)

    [[ "$declared_tiles" =~ ^[0-9]+$ ]] || die "Invalid tile count in $tile"
    [[ "$declared_pfaf" == "$EXPECTED_PFAF" ]] || \
        die "Expected $EXPECTED_PFAF Pfafstetter catchments, found $declared_pfaf"
    [[ "$raster_nx" == "$EXPECTED_RASTER_NX" && "$raster_ny" == "$EXPECTED_RASTER_NY" ]] || \
        die "Expected raster ${EXPECTED_RASTER_NX}x${EXPECTED_RASTER_NY}, found ${raster_nx}x${raster_ny}"
    [[ "$grid_count" == "2" ]] || die "Expected two grids, found: $grid_count"
    [[ "$grid1" == "PE180x1080-CF" ]] || die "Unexpected atmosphere grid label: $grid1"
    [[ "$grid1_im" == "$EXPECTED_ATM_IM" && "$grid1_jm" == "$EXPECTED_ATM_JM" ]] || \
        die "Expected atmosphere ${EXPECTED_ATM_IM}x${EXPECTED_ATM_JM}, found ${grid1_im}x${grid1_jm}"
    [[ "$grid2" == "LL23040x30-LL" ]] || die "Unexpected surface/ocean grid label: $grid2"
    [[ "$grid2_im" == "$EXPECTED_OCN_IM" && "$grid2_jm" == "$EXPECTED_OCN_JM" ]] || \
        die "Expected surface/ocean ${EXPECTED_OCN_IM}x${EXPECTED_OCN_JM}, found ${grid2_im}x${grid2_jm}"

    actual_records=$(awk 'END {print NR-8}' "$tile")
    [[ "$actual_records" == "$declared_tiles" ]] || \
        die "Header declares $declared_tiles records, but file contains $actual_records"

    note "Validating record structure, indices, areas, and fractions"
    awk \
        -v declared="$declared_tiles" \
        -v pfaf="$EXPECTED_PFAF" \
        -v aim="$EXPECTED_ATM_IM" \
        -v ajm="$EXPECTED_ATM_JM" \
        -v oim="$EXPECTED_OCN_IM" \
        -v ojm="$EXPECTED_OCN_JM" \
        -v frac_tol="$FRACTION_TOL" '
        # Every check accumulates a category counter and a representative
        # example instead of printing the first twenty failures and stopping.
        # A truncated log hides the distribution, which is the one thing that
        # distinguishes a systematic defect from scattered roundoff.
        function note_error(category, line, detail) {
            count[category]++
            if (!(category in example)) example[category] = "line " line ": " detail
        }
        BEGIN {
            sphere = 12.566370614359172
            area_tolerance = 1.0e-8
        }
        NR <= 8 {next}
        {
            n++
            type_count[$1]++
            area_sum += $2

            if (NF != 12) {
                note_error("field count", NR, NF " fields")
                next
            }
            if (!($1 == 0 || $1 == 19 || $1 == 20 || $1 == 100))
                note_error("surface type", NR, $1)
            if ($2 <= 0)
                note_error("non-positive area", NR, $2)
            if ($5 < 1 || $5 > aim || $6 < 1 || $6 > ajm)
                note_error("atmosphere index", NR, $5 " " $6)
            if ($7 <= 0 || $7 > frac_tol) {
                note_error("atmosphere fraction", NR, $7)
                if ($7 > max_atm_frac) max_atm_frac = $7
            }
            if ($11 <= 0 || $11 > frac_tol) {
                note_error("surface fraction", NR, $11)
                if ($11 > max_srf_frac) max_srf_frac = $11
            }
            if ($12 < 1)
                note_error("surface internal index", NR, $12)
            if ($1 == 100 && ($9 < 1 || $9 > pfaf))
                note_error("Pfafstetter index", NR, $9)
            if ($1 == 0 && ($9 < 1 || $9 > oim || $10 < 1 || $10 > ojm)) {
                note_error("LLC compact index", NR, $9 " " $10)
                # Undefined ocean records normally all reference one degenerate
                # surface tile.  Reporting that tile identifies the cause as a
                # single upstream defect rather than many independent ones.
                orphan_tile[$12]++
            }
        }
        END {
            relative_error = (area_sum - sphere) / sphere
            if (relative_error < 0) relative_error = -relative_error
            if (relative_error > area_tolerance)
                note_error("global area sum", 0, sprintf("relative error %.3g", relative_error))
            if (n != declared)
                note_error("record count", 0, n " found, " declared " declared")
            if (type_count[0] == 0 || type_count[100] == 0)
                note_error("missing surface class", 0, "need both ocean and land records")

            printf "  records:  %d\n", n
            printf "  land:     %d\n", type_count[100]
            printf "  lake:     %d\n", type_count[19]
            printf "  land ice: %d\n", type_count[20]
            printf "  ocean:    %d\n", type_count[0]
            printf "  area sum: %.15g rad^2 (relative error %.3g)\n", area_sum, relative_error
            if (max_atm_frac) printf "  max atmosphere fraction: %.12f\n", max_atm_frac
            if (max_srf_frac) printf "  max surface fraction:    %.12f\n", max_srf_frac

            total = 0
            for (category in count) total += count[category]
            if (total == 0) exit 0

            print "" > "/dev/stderr"
            print "Validation failures by category:" > "/dev/stderr"
            for (category in count)
                printf "  %-24s %8d   (first: %s)\n", category, count[category], example[category] > "/dev/stderr"
            for (tile_index in orphan_tile)
                printf "  undefined ocean records all reference surface tile %s (%d records)\n", \
                    tile_index, orphan_tile[tile_index] > "/dev/stderr"
            printf "Validation errors: %d\n", total > "/dev/stderr"
            exit 1
        }
    ' "$tile"

    if [[ "$DEEP_VALIDATION" == "1" ]]; then
        note "Checking that exchange fractions cover every C180 atmosphere cell"
        awk -v expected_cells="$((EXPECTED_ATM_IM * EXPECTED_ATM_JM))" '
            NR > 8 {fraction[$5 SUBSEP $6] += $7}
            END {
                tolerance = 1.0e-8
                for (key in fraction) {
                    cells++
                    error = fraction[key] - 1.0
                    if (error < 0) error = -error
                    if (error > max_error) max_error = error
                    if (error > tolerance) bad++
                }
                printf "  atmosphere cells: %d\n", cells
                printf "  maximum fraction-sum error: %.6g\n", max_error
                if (cells != expected_cells || bad != 0) {
                    print "Atmospheric exchange coverage validation failed" > "/dev/stderr"
                    print "Expected cells:", expected_cells, "found:", cells, "bad sums:", bad+0 > "/dev/stderr"
                    exit 1
                }
            }
        ' "$tile"
    fi

    note "Tile validation passed: $tile"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin-dir)
            [[ $# -ge 2 ]] || die "--bin-dir requires a value"
            BIN_DIR=$2
            shift 2
            ;;
        --input-dir)
            [[ $# -ge 2 ]] || die "--input-dir requires a value"
            INPUT_DIR=$2
            shift 2
            ;;
        --mask-file)
            [[ $# -ge 2 ]] || die "--mask-file requires a value"
            MASK_FILE=$2
            shift 2
            ;;
        --land-til)
            [[ $# -ge 2 ]] || die "--land-til requires a value"
            LAND_TIL=$2
            shift 2
            ;;
        --land-rst)
            [[ $# -ge 2 ]] || die "--land-rst requires a value"
            LAND_RST=$2
            shift 2
            ;;
        --llc-grid-dir)
            [[ $# -ge 2 ]] || die "--llc-grid-dir requires a value"
            LLC_GRID_DIR=$2
            shift 2
            ;;
        --data-exch2)
            [[ $# -ge 2 ]] || die "--data-exch2 requires a value"
            DATA_EXCH2=$2
            shift 2
            ;;
        --llc-snx)
            [[ $# -ge 2 ]] || die "--llc-snx requires a value"
            LLC_SNX=$2
            shift 2
            ;;
        --llc-sny)
            [[ $# -ge 2 ]] || die "--llc-sny requires a value"
            LLC_SNY=$2
            shift 2
            ;;
        --module-init)
            [[ $# -ge 2 ]] || die "--module-init requires a value"
            MODULE_INIT=$2
            shift 2
            ;;
        --work-root)
            [[ $# -ge 2 ]] || die "--work-root requires a value"
            WORK_ROOT=$2
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || die "--output requires a value"
            OUTPUT_FILE=$2
            shift 2
            ;;
        --max-tiles)
            [[ $# -ge 2 ]] || die "--max-tiles requires a value"
            MAX_TILES=$2
            shift 2
            ;;
        --expected-pfaf)
            [[ $# -ge 2 ]] || die "--expected-pfaf requires a value"
            EXPECTED_PFAF=$2
            shift 2
            ;;
        --skip-deep-validation)
            DEEP_VALIDATION=0
            shift
            ;;
        --validate-only)
            [[ $# -ge 2 ]] || die "--validate-only requires a value"
            VALIDATE_ONLY=$2
            shift 2
            ;;
        --fraction-tol)
            [[ $# -ge 2 ]] || die "--fraction-tol requires a value"
            FRACTION_TOL=$2
            shift 2
            ;;
        --skip-raster-repair)
            REPAIR_RASTER=0
            shift
            ;;
        --land-ocean-value)
            [[ $# -ge 2 ]] || die "--land-ocean-value requires a value"
            LAND_OCEAN_VALUE=$2
            shift 2
            ;;
        --raster-filler)
            [[ $# -ge 2 ]] || die "--raster-filler requires a value"
            RASTER_FILLER=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[[ "$MAX_TILES" =~ ^[0-9]+$ ]] || die "--max-tiles must be a positive integer"
(( MAX_TILES > 0 )) || die "--max-tiles must be greater than zero"
[[ "$EXPECTED_PFAF" =~ ^[0-9]+$ ]] || die "--expected-pfaf must be a positive integer"
(( EXPECTED_PFAF > 0 )) || die "--expected-pfaf must be greater than zero"
[[ "$FRACTION_TOL" =~ ^[0-9]*\.?[0-9]+$ ]] || die "--fraction-tol must be a number"

if [[ -z "$RASTER_FILLER" ]]; then
    RASTER_FILLER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/fill_llc_raster.py"
fi

if [[ -n "$VALIDATE_ONLY" ]]; then
    validate_tile "$VALIDATE_ONLY"
    exit 0
fi

[[ -n "$BIN_DIR" ]] || die "Missing --bin-dir"
[[ -n "$LLC_GRID_DIR" ]] || die "Missing --llc-grid-dir"
[[ -n "$DATA_EXCH2" ]] || die "Missing --data-exch2"
[[ -n "$WORK_ROOT" ]] || die "Missing --work-root"
[[ -n "$OUTPUT_FILE" ]] || die "Missing --output"

if [[ -n "$LAND_TIL" || -n "$LAND_RST" ]]; then
    [[ -n "$LAND_TIL" && -n "$LAND_RST" ]] || \
        die "--land-til and --land-rst must be supplied together"
    [[ -z "$INPUT_DIR" && -z "$MASK_FILE" ]] || \
        die "Use either --land-til/--land-rst or --input-dir/--mask-file, not both"
    LAND_MODE=prebuilt
else
    [[ -n "$INPUT_DIR" ]] || \
        die "Missing land source: supply --land-til/--land-rst or --input-dir"
    [[ -n "$MASK_FILE" ]] || die "--mask-file is required with --input-dir"
    LAND_MODE=generate
fi

if [[ -n "$MODULE_INIT" ]]; then
    require_file "$MODULE_INIT"
    MODULE_INIT=$(canonical_file "$MODULE_INIT")
    note "Sourcing GEOS environment: $MODULE_INIT"
    set +u
    # shellcheck source=/dev/null
    source "$MODULE_INIT"
    set -u
fi

require_dir "$BIN_DIR"
require_dir "$LLC_GRID_DIR"
require_file "$DATA_EXCH2"

BIN_DIR=$(canonical_dir "$BIN_DIR")
LLC_GRID_DIR=$(canonical_dir "$LLC_GRID_DIR")
DATA_EXCH2=$(canonical_file "$DATA_EXCH2")

if [[ "$LAND_MODE" == "prebuilt" ]]; then
    require_file "$LAND_TIL"
    require_file "$LAND_RST"
    LAND_TIL=$(canonical_file "$LAND_TIL")
    LAND_RST=$(canonical_file "$LAND_RST")

    read -r _ land_pfaf land_nx land_ny < "$LAND_TIL"
    [[ "$land_pfaf" == "$EXPECTED_PFAF" ]] || \
        die "Land tile declares $land_pfaf catchments; expected $EXPECTED_PFAF"
    [[ "$land_nx" == "$EXPECTED_RASTER_NX" && "$land_ny" == "$EXPECTED_RASTER_NY" ]] || \
        die "Land raster is ${land_nx}x${land_ny}; expected ${EXPECTED_RASTER_NX}x${EXPECTED_RASTER_NY}"
else
    require_dir "$INPUT_DIR"
    INPUT_DIR=$(canonical_dir "$INPUT_DIR")

    # mkLandRaster.x constructs the mask path as
    # MAKE_BCS_INPUT_DIR/shared/mask/MASKFILE, so export only the filename.
    MASK_NAME=$(basename "$MASK_FILE")
    MASK_PATH="$INPUT_DIR/shared/mask/$MASK_NAME"
    require_file "$MASK_PATH"
    MASK_PATH=$(canonical_file "$MASK_PATH")
fi

for face in 001 002 003 004 005; do
    require_file "$LLC_GRID_DIR/tile${face}.mitgrid"
done

MK_CUBE="$BIN_DIR/mkCubeFVRaster.x"
MK_LAND="$BIN_DIR/mkLandRaster.x"
MK_MIT="$BIN_DIR/mkMITAquaRaster.x"
COMBINE="$BIN_DIR/CombineRasters.x"

require_executable "$MK_CUBE"
require_executable "$MK_MIT"
require_executable "$COMBINE"
if [[ "$LAND_MODE" == "generate" ]]; then
    require_executable "$MK_LAND"
fi

mkdir -p "$WORK_ROOT"
WORK_ROOT=$(canonical_dir "$WORK_ROOT")

output_parent=$(dirname "$OUTPUT_FILE")
mkdir -p "$output_parent"
OUTPUT_FILE=$(canonical_file "$OUTPUT_FILE")
[[ ! -e "$OUTPUT_FILE" ]] || die "Output already exists; refusing to overwrite: $OUTPUT_FILE"

RUN_DIR=$(mktemp -d "$WORK_ROOT/c180_llc270.XXXXXX")
mkdir -p "$RUN_DIR/til" "$RUN_DIR/rst" "$RUN_DIR/log"
create_mit_exch2_adapter "$DATA_EXCH2" "$RUN_DIR/data.exch2"

if [[ "$LAND_MODE" == "prebuilt" ]]; then
    ln -s "$LAND_TIL" "$RUN_DIR/til/Pfafstetter.til"
    ln -s "$LAND_RST" "$RUN_DIR/rst/Pfafstetter.rst"
else
    export MAKE_BCS_INPUT_DIR="$INPUT_DIR"
    export MASKFILE="$MASK_NAME"
fi
export OMP_NUM_THREADS=${OMP_NUM_THREADS:-1}

run_logged() {
    local label=$1
    shift
    note "Running $label"
    printf '  command:'
    printf ' %q' "$@"
    printf '\n'
    (
        cd "$RUN_DIR"
        "$@"
    ) 2>&1 | tee "$RUN_DIR/log/${label}.log"
}

note "Work directory: $RUN_DIR"
if [[ "$LAND_MODE" == "prebuilt" ]]; then
    note "Using retained GEOS v12 land tile: $LAND_TIL"
    note "Using retained GEOS v12 land raster: $LAND_RST"
else
    note "Generating GEOS v12 land geometry from: $MAKE_BCS_INPUT_DIR"
    note "Using GEOS v12 land mask: $MASK_PATH"
fi
note "Using LLC270 decomposition: $DATA_EXCH2"

run_logged c180_raster \
    "$MK_CUBE" -x "$EXPECTED_RASTER_NX" -y "$EXPECTED_RASTER_NY" 180

if [[ "$LAND_MODE" == "generate" ]]; then
    run_logged v12_land_raster \
        "$MK_LAND" -x "$EXPECTED_RASTER_NX" -y "$EXPECTED_RASTER_NY" -v -t "$MAX_TILES"
fi

# mkMITAquaRaster.x reads data.exch2 from its working directory. Some GEOS
# versions also concatenate GridDir and tileNNN.mitgrid without inserting a
# slash, so deliberately pass a trailing slash.
run_logged llc270_raster \
    "$MK_MIT" -x "$EXPECTED_RASTER_NX" -y "$EXPECTED_RASTER_NY" -v "${LLC_GRID_DIR}/"

require_file "$RUN_DIR/til/CF0180x6C.til"
require_file "$RUN_DIR/rst/CF0180x6C.rst"
require_file "$RUN_DIR/til/Pfafstetter.til"
require_file "$RUN_DIR/rst/Pfafstetter.rst"

llc_candidates=()
while IFS= read -r -d '' candidate; do
    llc_candidates+=("$candidate")
done < <(find "$RUN_DIR/til" "$RUN_DIR" -maxdepth 1 -type f -name 'LL*.til' -print0)

(( ${#llc_candidates[@]} == 1 )) || \
    die "Expected exactly one generated LLC .til file, found ${#llc_candidates[@]} in $RUN_DIR or $RUN_DIR/til"

raw_llc_til=${llc_candidates[0]}
raw_llc_base=$(basename "$raw_llc_til" .til)
raw_llc_dir=$(dirname "$raw_llc_til")
raw_llc_rst="$raw_llc_dir/${raw_llc_base}.rst"
if [[ ! -f "$raw_llc_rst" && -f "$RUN_DIR/rst/${raw_llc_base}.rst" ]]; then
    raw_llc_rst="$RUN_DIR/rst/${raw_llc_base}.rst"
fi
require_file "$raw_llc_rst"

raw_llc_grids=$(trim_header_line "$raw_llc_til" 2)
raw_llc_im=$(trim_header_line "$raw_llc_til" 4)
raw_llc_jm=$(trim_header_line "$raw_llc_til" 5)
read -r _ _ raw_raster_nx raw_raster_ny < "$raw_llc_til"

[[ "$raw_llc_grids" == "1" ]] || die "Generated LLC raster should contain one grid, found $raw_llc_grids"
[[ "$raw_llc_im" == "$EXPECTED_OCN_IM" && "$raw_llc_jm" == "$EXPECTED_OCN_JM" ]] || \
    die "LLC decomposition produced ${raw_llc_im}x${raw_llc_jm}; expected ${EXPECTED_OCN_IM}x${EXPECTED_OCN_JM}. Check data.exch2."
[[ "$raw_raster_nx" == "$EXPECTED_RASTER_NX" && "$raw_raster_ny" == "$EXPECTED_RASTER_NY" ]] || \
    die "LLC raster has base dimensions ${raw_raster_nx}x${raw_raster_ny}; expected ${EXPECTED_RASTER_NX}x${EXPECTED_RASTER_NY}"

# mkMITAquaRaster.F90 commonly formats both compact dimensions with I4.4.
# LLC270's 23040-point compact X dimension overflows that field, producing a
# literal filename such as LL****xLL0030.  Give the validated pair a stable,
# shell-safe internal name before passing it to CombineRasters.  This also
# presents root-level output where CombineRasters expects til/ and rst/ files.
generated_llc_base=$raw_llc_base
raw_llc_base=LLC23040xLLC0030
if [[ "$raw_llc_til" != "$RUN_DIR/til/${raw_llc_base}.til" ]]; then
    ln -s "$raw_llc_til" "$RUN_DIR/til/${raw_llc_base}.til"
fi

# mkMITAquaRaster.x fills pixels that no LLC tile claims by nearest-neighbour
# search, but that pass does not always converge: pixels the GEOS v12 land mask
# calls water while the LLC domain has no wet cell there are left at zero.
# CombineRasters cannot express "water with no ocean cell", so it emits one
# degenerate sentinel surface tile and attributes every such pixel to it, which
# becomes a spray of (0,0) ocean records in the final exchange grid.  Complete
# the fill here so CombineRasters derives every tile area and fraction from a
# fully defined raster and no post-hoc renormalisation is needed.
if [[ "$REPAIR_RASTER" == "1" ]]; then
    require_file "$RASTER_FILLER"
    command -v "$PYTHON_BIN" >/dev/null 2>&1 || \
        die "$PYTHON_BIN not found; set PYTHON_BIN or pass --skip-raster-repair"

    # Pfafstetter.til ends with three placeholder tiles -- ocean, lake and land
    # ice -- after the land catchments, and Pfafstetter.rst stores each pixel's
    # record number.  The ocean placeholder is NOT the last record, so derive it
    # by finding the type-0 record rather than assuming a position: for the v13
    # C180 bundle that is 289836, with lake 289837 and land ice 289838.
    if [[ -z "$LAND_OCEAN_VALUE" ]]; then
        LAND_OCEAN_VALUE=$(awk 'NR > 5 && $1 == 0 {print NR - 5; exit}' \
            "$RUN_DIR/til/Pfafstetter.til")
        [[ "$LAND_OCEAN_VALUE" =~ ^[0-9]+$ ]] || \
            die "Could not locate the ocean placeholder record in $RUN_DIR/til/Pfafstetter.til"
        note "Derived Pfafstetter ocean marker: $LAND_OCEAN_VALUE"
    fi

    note "Repairing LLC/Pfafstetter coastline mismatches"
    "$PYTHON_BIN" "$RASTER_FILLER" \
        --llc-raster "$raw_llc_rst" \
        --land-raster "$RUN_DIR/rst/Pfafstetter.rst" \
        --output "$RUN_DIR/rst/${raw_llc_base}.rst" \
        --nx "$EXPECTED_RASTER_NX" \
        --ny "$EXPECTED_RASTER_NY" \
        --valid-min 1 \
        --valid-max "$(( EXPECTED_OCN_IM * EXPECTED_OCN_JM ))" \
        --land-ocean "$LAND_OCEAN_VALUE" \
        --report "$RUN_DIR/log/llc270_raster_fill.txt" \
        2>&1 | tee "$RUN_DIR/log/llc270_raster_fill.log"
    [[ "${PIPESTATUS[0]}" == "0" ]] || die "LLC raster repair failed; see $RUN_DIR/log/llc270_raster_fill.log"
    require_file "$RUN_DIR/rst/${raw_llc_base}.rst"
elif [[ "$raw_llc_rst" != "$RUN_DIR/rst/${raw_llc_base}.rst" ]]; then
    ln -s "$raw_llc_rst" "$RUN_DIR/rst/${raw_llc_base}.rst"
fi

note "Detected LLC270 compact raster: $generated_llc_base (${raw_llc_im}x${raw_llc_jm})"
note "Normalized LLC270 raster name: $raw_llc_base"

# Give the two final parent grids exactly the labels used by the established
# C180-LLC270 tile file. CombineRasters writes its input names into the final
# tile header. A symlink alone is insufficient because CombineRasters reads
# the grid label from line 3 of the input .til file.
awk 'NR == 3 {$0=" PE180x1080-CF"} {print}' \
    "$RUN_DIR/til/CF0180x6C.til" > "$RUN_DIR/til/PE180x1080-CF.til"
ln -s CF0180x6C.rst "$RUN_DIR/rst/PE180x1080-CF.rst"

[[ "$(trim_header_line "$RUN_DIR/til/PE180x1080-CF.til" 3)" == "PE180x1080-CF" ]] || \
    die "Failed to normalize the C180 atmosphere grid label"

SURFACE_GRID=LL23040x30-LL
FINAL_GRID=GEOSv12-C180_LLC270

run_logged llc270_plus_v12_land \
    "$COMBINE" -f 0 -t "$MAX_TILES" -g "$SURFACE_GRID" "$raw_llc_base" Pfafstetter

require_file "$RUN_DIR/til/${SURFACE_GRID}.til"
require_file "$RUN_DIR/rst/${SURFACE_GRID}.rst"

# CombineRasters assumes that the LLC raster is defined anywhere retained as
# ocean by Pfafstetter.  A coastline mismatch otherwise indexes the LLC table
# with RASTERUNDEF (-999) and can silently emit one zero-area, (0,0) ocean
# record.  Stop here before that corrupt surface record is split over C180.
awk -v oim="$EXPECTED_OCN_IM" -v ojm="$EXPECTED_OCN_JM" '
    NR <= 5 { next }
    $1 == 0 && ($2 <= 0 || $5 < 1 || $5 > oim || $6 < 1 || $6 > ojm) {
        if (++bad <= 20) {
            printf "Invalid merged LLC surface record at line %d: type=%s area=%s I=%s J=%s\n", \
                   NR, $1, $2, $5, $6 > "/dev/stderr"
        }
    }
    END {
        if (bad) {
            printf "ERROR: LLC/Pfafstetter coastline mismatch produced %d invalid surface record(s)\n", bad > "/dev/stderr"
            exit 1
        }
    }
' "$RUN_DIR/til/${SURFACE_GRID}.til"

run_logged c180_plus_llc270_surface \
    "$COMBINE" -t "$MAX_TILES" -g "$FINAL_GRID" PE180x1080-CF "$SURFACE_GRID"

FINAL_TILE="$RUN_DIR/til/${FINAL_GRID}.til"
require_file "$FINAL_TILE"

validate_tile "$FINAL_TILE"

cp "$FINAL_TILE" "$OUTPUT_FILE"

if command -v sha256sum >/dev/null 2>&1; then
    checksum=$(sha256sum "$OUTPUT_FILE")
else
    checksum=$(shasum -a 256 "$OUTPUT_FILE")
fi

note "Generation completed successfully"
printf '  tile.data: %s\n' "$OUTPUT_FILE"
printf '  work data: %s\n' "$RUN_DIR"
printf '  SHA-256:   %s\n' "$checksum"
printf '\nKeep the work directory until tile.data, runoff routing, MIT, and CICE geometry have all been validated together.\n'
