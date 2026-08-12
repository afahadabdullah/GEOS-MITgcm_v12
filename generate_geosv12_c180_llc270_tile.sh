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
        -v ojm="$EXPECTED_OCN_JM" '
        BEGIN {
            sphere = 12.566370614359172
            tolerance = 1.0e-8
        }
        NR <= 8 {next}
        {
            n++
            type_count[$1]++
            area_sum += $2

            if (NF != 12) {
                if (errors < 20) print "Invalid field count at line", NR, ":", NF > "/dev/stderr"
                errors++
                next
            }
            if (!($1 == 0 || $1 == 19 || $1 == 20 || $1 == 100)) {
                if (errors < 20) print "Unexpected surface type at line", NR, ":", $1 > "/dev/stderr"
                errors++
            }
            if ($2 <= 0) {
                if (errors < 20) print "Non-positive area at line", NR > "/dev/stderr"
                errors++
            }
            if ($5 < 1 || $5 > aim || $6 < 1 || $6 > ajm) {
                if (errors < 20) print "Atmosphere index out of range at line", NR, ":", $5, $6 > "/dev/stderr"
                errors++
            }
            if ($7 <= 0 || $7 > 1.000001) {
                if (errors < 20) print "Atmosphere fraction out of range at line", NR, ":", $7 > "/dev/stderr"
                errors++
            }
            if ($11 <= 0 || $11 > 1.000001) {
                if (errors < 20) print "Surface fraction out of range at line", NR, ":", $11 > "/dev/stderr"
                errors++
            }
            if ($12 < 1) {
                if (errors < 20) print "Invalid surface internal index at line", NR, ":", $12 > "/dev/stderr"
                errors++
            }
            if ($1 == 100 && ($9 < 1 || $9 > pfaf)) {
                if (errors < 20) print "Pfafstetter index out of range at line", NR, ":", $9 > "/dev/stderr"
                errors++
            }
            if ($1 == 0) {
                if ($9 < 1 || $9 > oim || $10 < 1 || $10 > ojm) {
                    if (errors < 20) print "LLC compact index out of range at line", NR, ":", $9, $10 > "/dev/stderr"
                    errors++
                }
            }
        }
        END {
            relative_error = (area_sum - sphere) / sphere
            if (relative_error < 0) relative_error = -relative_error
            if (relative_error > tolerance) {
                print "Global area does not sum to 4*pi; relative error:", relative_error > "/dev/stderr"
                errors++
            }
            if (n != declared) {
                print "Record count changed during validation:", n, declared > "/dev/stderr"
                errors++
            }
            if (type_count[0] == 0 || type_count[100] == 0) {
                print "Tile file must contain both ocean and land records" > "/dev/stderr"
                errors++
            }

            printf "  records:  %d\n", n
            printf "  land:     %d\n", type_count[100]
            printf "  lake:     %d\n", type_count[19]
            printf "  land ice: %d\n", type_count[20]
            printf "  ocean:    %d\n", type_count[0]
            printf "  area sum: %.15g rad^2 (relative error %.3g)\n", area_sum, relative_error

            if (errors) {
                print "Validation errors:", errors > "/dev/stderr"
                exit 1
            }
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
ln -s "$DATA_EXCH2" "$RUN_DIR/data.exch2"

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
done < <(find "$RUN_DIR/til" -maxdepth 1 -type f -name 'LL*.til' -print0)

(( ${#llc_candidates[@]} == 1 )) || \
    die "Expected exactly one generated LLC .til file, found ${#llc_candidates[@]} in $RUN_DIR/til"

raw_llc_til=${llc_candidates[0]}
raw_llc_base=$(basename "$raw_llc_til" .til)
raw_llc_rst="$RUN_DIR/rst/${raw_llc_base}.rst"
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

note "Detected LLC270 compact raster: $raw_llc_base (${raw_llc_im}x${raw_llc_jm})"

# Give the two final parent grids exactly the labels used by the established
# C180-LLC270 tile file. CombineRasters writes its input names into the final
# tile header.
ln -s CF0180x6C.til "$RUN_DIR/til/PE180x1080-CF.til"
ln -s CF0180x6C.rst "$RUN_DIR/rst/PE180x1080-CF.rst"

SURFACE_GRID=LL23040x30-LL
FINAL_GRID=GEOSv12-C180_LLC270

run_logged llc270_plus_v12_land \
    "$COMBINE" -f 0 -t "$MAX_TILES" -g "$SURFACE_GRID" "$raw_llc_base" Pfafstetter

require_file "$RUN_DIR/til/${SURFACE_GRID}.til"
require_file "$RUN_DIR/rst/${SURFACE_GRID}.rst"

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
