# GEOS v12 C180 + MITgcm LLC270 Tile Generator

Generate a GEOS v12 C180 atmosphere + MITgcm LLC270 ocean coupling tile file (`tile.data`) for Earth System Model experiments.

## Overview

This repository provides a bash script and supporting utilities to construct an ASCII tile exchange grid between the GEOS v12 C180 cubed-sphere atmosphere model and the MITgcm LLC270 ocean model. The output is a single `tile.data` file containing:

- **Geometry**: 180°×180° atmosphere grid cells intersected with LLC270 ocean domain
- **Land coupling**: GEOS v12 Pfafstetter catchment-based land geometry (291,284 catchments + global lake and land-ice tiles)
- **Exchange records**: ~2M rows encoding overlap polygons, areas, fractions, and indices for each atmosphere–land–ocean triple

## Problem Solved

The v12 land mask was built to be consistent with the MOM6 tripolar ocean grid (¼° resolution), not LLC270 (⅓° resolution). Where GEOS calls water but LLC270 has no ocean cell—semi-enclosed estuaries, fjords, gulfs behind blanked tiles—`mkMITAquaRaster.x` leaves raster pixels undefined. `CombineRasters.x` cannot represent "water with no ocean cell," so it emits spurious ocean exchange records with compact index (0, 0).

**Solution**: `fill_llc_raster.py` reads both rasters together and identifies the intersection — LLC undefined AND land says ocean, typically ~30,000 pixels. Each mismatched pixel is then resolved **by distance**, because not all of them should become ocean:

| Distance to nearest wet LLC cell | Treatment |
|---|---|
| within `--max-distance` (default 32 px ≈ 30 km) | assign that LLC compact index — the pixel is a sub-grid coastline sliver belonging to that cell |
| beyond it | reclassify to **lake** in the land raster |

The second case matters. Pixels in the Meghna estuary sit more than 100 pixels from any wet LLC cell, and forcing them into the nearest ocean cell would inject a whole grid cell's worth of estuarine freshwater into open ocean. Measured on a real run, blanket nearest-ocean assignment put 2,867 pixels (~1,175 km²) onto a single ~1,400 km² LLC cell. The established GEOS v11.7 LLC270 tile file treats the same water as lake, and this reproduces that.

Both repaired rasters are written to the run directory, and `CombineRasters` then derives every area and fraction itself — no post-hoc renormalization of the tile file.

## Files

- **`generate_geosv12_c180_llc270_tile.sh`** — Main orchestration script
  - Calls `mkCubeFVRaster.x`, `mkMITAquaRaster.x`, and `CombineRasters.x` in sequence
  - Validates output tile file
  - Auto-derives LLC ocean marker from `Pfafstetter.til` header
  - Calls `fill_llc_raster.py` to repair coastline mismatches
  
- **`fill_llc_raster.py`** — Land/ocean mask reconciliation
  - Scans LLC and land rasters together to locate mask mismatches
  - Resolves each by distance: nearby pixels join an LLC cell, distant ones become lake
  - Writes both a repaired LLC raster and a repaired land raster
  - `--inspect` for a cheap scan, `--dry-run` for a full decision pass without writing
  - Refuses to act on more than `--max-fill-fraction` of the raster (default 1%)
  
- **`run_tile_nccs.sh`** — SLURM batch job template for NCCS Discover
  - Pre-configured paths and environment
  - Edit account number and mount points, then `sbatch run_tile_nccs.sh`

## Prerequisites

### Executables
- `mkCubeFVRaster.x` (GEOS make-BC)
- `mkLandRaster.x` or `mkMITAquaRaster.x` (from GEOS install)
- `CombineRasters.x` (GEOS make-BC)

### Data Files
- `Pfafstetter.til` and `Pfafstetter.rst` (GEOS v12 land geometry)
- `tile001.mitgrid` through `tile005.mitgrid` (LLC270 grid definition)
- `data.exch2` (LLC270 decomposition for the target MIT configuration)

### Python Environment
- Python 3.7+
- `numpy` (required by `fill_llc_raster.py`)

## Usage

### Interactive (on a compute node)

```bash
module load python/GEOSpyD
export OMP_NUM_THREADS=1

bash generate_geosv12_c180_llc270_tile.sh \
    --bin-dir       /path/to/GEOSgcm/install/bin \
    --land-til      /path/to/Pfafstetter.til \
    --land-rst      /path/to/Pfafstetter.rst \
    --llc-grid-dir  /path/to/LLC270/mitgrid \
    --data-exch2    /path/to/data.exch2 \
    --work-root     /work/directory \
    --output        /output/tile.data \
    --raster-filler ./fill_llc_raster.py
```

### Batch (NCCS Discover)

1. Edit `run_tile_nccs.sh`:
   - Set `--account` to your SLURM project code
   - Verify or update paths in section 1

2. Submit:
   ```bash
   sbatch run_tile_nccs.sh
   squeue -u $USER
   tail -f c180_llc270_tile.<jobid>.out
   ```

### Inspect a Raster Before Repair

Preview which pixels will be repaired and their distribution:

```bash
python3 fill_llc_raster.py --inspect \
    --llc-raster  raw_LLC270.rst \
    --land-raster Pfafstetter.rst \
    --valid-max 691200 \
    --land-ocean 289836
```

Output includes:
- Number of undefined pixels in the LLC raster (typically 18–20% = the land surface)
- Exact breakdown of land raster values where LLC is undefined
- Mask mismatch count

To see how those mismatches would be split between ocean assignment and lake reclassification without writing anything, use `--dry-run` instead — it runs the full nearest-neighbour pass and reports a distance histogram:

```bash
python3 fill_llc_raster.py --dry-run \
    --llc-raster  raw_LLC270.rst \
    --land-raster Pfafstetter.rst \
    --valid-max 691200 \
    --land-ocean 289836 --land-lake 289837 \
    --report decisions.txt
```

## Key Options

### `generate_geosv12_c180_llc270_tile.sh`

| Option | Default | Description |
|--------|---------|-------------|
| `--bin-dir` | (required) | Directory containing GEOS make-BC executables |
| `--land-til` | (required) | Path to `Pfafstetter.til` |
| `--land-rst` | (required) | Path to `Pfafstetter.rst` |
| `--llc-grid-dir` | (required) | Directory holding `tile001..005.mitgrid` |
| `--data-exch2` | (required) | LLC270 `data.exch2` file |
| `--work-root` | (required) | Parent directory for work subdirectory |
| `--output` | (required) | Output `tile.data` path (must not exist) |
| `--raster-filler` | `./fill_llc_raster.py` | Path to repair script |
| `--max-ocean-distance` | `32` | Pixel radius within which a mismatch joins an LLC cell |
| `--land-ocean-value` | (from the `.til`) | Ocean placeholder index |
| `--land-lake-value` | (from the `.til`) | Lake placeholder index |
| `--skip-raster-repair` | (disabled) | Skip the coastline mismatch repair |
| `--skip-deep-validation` | (disabled) | Skip atmosphere fraction-conservation check |
| `--fraction-tol` | `1.0001` | Exchange fraction upper bound (accounts for ASCII round-off) |
| `--max-tiles` | `5000000` | Tile allocation limit for `CombineRasters` |

### `fill_llc_raster.py`

| Option | Default | Description |
|--------|---------|-------------|
| `--llc-raster` | (required) | Input LLC raster from `mkMITAquaRaster.x` |
| `--land-raster` | (required) | Input `Pfafstetter.rst` |
| `--llc-output` | (required) | Repaired LLC raster |
| `--land-output` | (required) | Repaired land raster |
| `--land-ocean` | (required) | Ocean placeholder index in the land raster |
| `--land-lake` | (required if any reclassification) | Lake placeholder index |
| `--max-distance` | `32` | Assign to an LLC cell within this many pixels; beyond it, make lake |
| `--valid-min` | `1` | Lowest usable compact index |
| `--valid-max` | `0` | Highest usable compact index (0 = none) |
| `--max-radius` | `256` | Hard search limit in pixels |
| `--inspect` | (disabled) | Cheap scan of both rasters, then exit |
| `--dry-run` | (disabled) | Full decision pass, write nothing |
| `--max-fill-fraction` | `0.01` | Refuse to act on more than this fraction of the raster |
| `--report` | (none) | Write decision and distance statistics to file |

The placeholder indices are record positions in `Pfafstetter.til`, found by type:

```bash
awk 'NR > 5 && $1 ==  0 {print NR - 5; exit}' Pfafstetter.til   # ocean
awk 'NR > 5 && $1 == 19 {print NR - 5; exit}' Pfafstetter.til   # lake
```

For the v13 `CF0180x6C_M6TP1440x1080` bundle these are 289836 and 289837. The main script derives both automatically.

## Output

### `tile.data`

ASCII file with 8-line header followed by exchange records:

```
   2007368    291284     43200     21600
         2
 PE180x1080-CF
       180
      1080
 LL23040x30-LL
     23040
        30
type  area  lon  lat  atm_i  atm_j  atm_frac  atm_index  surf_i  surf_j  surf_frac  surf_index
   0  1.2e-05  -0.125  89.875  1  1080  0.5  1  1  1  0.5  2
 ...
```

**Record fields** (one per exchange cell):
1. Surface type: 0 (ocean), 19 (lake), 20 (land ice), 100 (land)
2. Overlap area (steradians)
3–4. Centroid lon/lat (degrees)
5–6. Atmosphere grid indices (1-indexed, i/j)
7. Atmosphere fraction of that cell
8. Atmosphere internal tile index
9–10. Surface grid indices (1-indexed, compact i/j for ocean; catchment/1 for land)
11. Surface fraction of that cell
12. Surface internal tile index

### Intermediate Files (in work directory)

- `til/`, `rst/` — Component raster and header files
- `log/` — Execution logs, including `llc270_raster_fill.txt` with repair statistics
- `c180_llc270.XXXXXX/` — Timestamped run directory retained for inspection

## Validation

The script performs several checks:

1. **Raster consistency** — LLC and Pfafstetter dimensions, grid labels, tile counts
2. **Record structure** — Field count, index ranges, non-negative areas
3. **Fractions** — Exchange fractions in [0, 1.0001] (tolerance accounts for ASCII round-off)
4. **Global area** — Sum of all areas ≈ 4π steradians (1.03e-13 relative error typical)
5. **Atmosphere coverage** — Every C180 cell's exchange fractions sum to exactly 1.0
6. **Ocean indices** — No LLC compact indices with value (0, 0)

A summary appears in the final validation output:

```
  records:  2007368
  land:     684752
  lake:     32725
  land ice: 6836
  ocean:    1283055
  area sum: 12.5663706143605 rad^2 (relative error 1.03e-13)
```

## Troubleshooting

### "repair targets" does not match expected ~30,000

The ocean marker may be incorrect. Run `--inspect` on the raw raster and `Pfafstetter.til` to see which land value appears dominant where LLC is undefined. Or check the first line of `Pfafstetter.til` to confirm the tile count:

```bash
head -1 Pfafstetter.til
# For v13/CF0180x6C_M6TP1440x1080: 289838 (ocean marker = 289836)
```

### "Invalid merged LLC surface record at line N"

The intermediate surface tile has a degenerate record. Check the run log:

```bash
grep "Invalid merged" $WORK_ROOT/c180_llc270.*/log/llc270_plus_v12_land.log
```

### Validation errors in fraction or ocean indices

Check `--fraction-tol` — the production MOM6 tile carries fractions up to 1.0000070271. The default 1.0001 should pass. Also verify the reconciliation ran and the log shows both an `assigned to a nearby LLC cell` and a `reclassified to lake` count.

### "N pixels are further than M px from any wet LLC cell"

Expected for the Meghna estuary, Río de la Plata, and the Kara Sea gulfs. They are reclassified to lake automatically once `--land-lake` is supplied; the main script derives it. Raise `--max-ocean-distance` only if you actually want that water in the MIT ocean domain, and check the resulting `largest gain` figure — more than ~3,400 pixels on one cell means it absorbed more area than a whole LLC270 cell.

### Lake and ocean counts differ from the reference tile

Expected, and informative. The v11.7 LLC270 reference has 686,448 land / 33,287 lake / 6,904 land ice, because it was built on v11.7 land geometry. A correct v12 build matches the **v12 MOM6** file instead: 684,752 land / 32,725 lake / 6,836 land ice, plus whatever pixels the reconciliation moved into lake.

## References

- GEOS make-BC documentation: see `generate_geosv12_c180_llc270_tile.sh --help`
- MITgcm LLC270 grid: https://mitgcm.readthedocs.io/
- Example usage on NCCS Discover: see `run_tile_nccs.sh`

## License

These scripts are provided as-is for research use. Adapt and redistribute freely with attribution.

## Contact

For questions about the LLC270 coupling geometry or the repair algorithm, contact the GEOS-MITgcm development team.
