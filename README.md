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
| within `--max-distance` | assign that LLC compact index — the pixel is a sub-grid coastline sliver belonging to that cell |
| beyond it (**the default: always**) | reclassify to **lake** in the land raster |

`--max-distance` defaults to **0**, so every mismatched pixel becomes lake. That is deliberate. LLC cell areas in the `.til` come from the mitgrid files, not from the raster, so moving raster pixels into a cell grows its exchange area while its declared area stays fixed — and the surface fractions for that cell then sum above 1. Measured at distance 32 on a real run:

```
assigned to a nearby LLC cell: 14679
reclassified to lake:          15324
receiving cells: 48, largest gain 1277 pixels (compact index 9275)
max surface fraction:    1.932630504330     <- should be ~1.0000070
```

All 11 failing records were type 0 on receiving cells. Correcting the `.til` areas instead would desynchronise them from MIT's own `rA` and break flux conservation, so the raster assignment is what has to give.

Lake carries no such constraint: every lake record shares one global tile, so the same ~12,300 km² is a sub-percent perturbation. This also reproduces the established GEOS v11.7 LLC270 tile file, whose land mask never called this water ocean — which is why it carries 562 more lake records than the MOM6 file.

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
| `--max-ocean-distance` | `0` | Pixel radius within which a mismatch joins an LLC cell; 0 sends all to lake |
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
| `--max-distance` | `0` | Assign to an LLC cell within this many pixels; beyond it, make lake. 0 = always lake |
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

An ASCII exchange-grid file: an 8-line header followed by one record per intersection polygon between an atmosphere cell and a surface element.

Authoritative column ordering comes from the GEOS reader, `GEOSgcm_GridComp/GEOSagcm_GridComp/GEOSphysics_GridComp/GEOSsurface_GridComp/Utils/Raster/makebcs/TileFile_ASCII_to_nc4.F90`.

#### Header (lines 1–8)

```
   2007319    291284     43200     21600
         2
 PE180x1080-CF
       180
      1080
 LL23040x30-LL
     23040
        30
```

| Line | Field(s) | Meaning |
|---|---|---|
| 1 | `2007319` | number of exchange tiles = number of records after the header |
| 1 | `291284` | number of Pfafstetter catchments |
| 1 | `43200 21600` | raster dimensions — 30 arc-second global grid (360/43200 = 0.008333°) |
| 2 | `2` | number of grids |
| 3–5 | `PE180x1080-CF`, `180`, `1080` | grid 1: C180 cubed-sphere atmosphere, IM × JM |
| 6–8 | `LL23040x30-LL`, `23040`, `30` | grid 2: LLC270 ocean in compact layout, IM × JM |

The LLC270 compact shape follows from the decomposition: with `sNx=sNy=30` there are 1053 tiles, 285 of them blank per `data.exch2`, leaving 768 active × 30 = 23040 wide by 30 tall = 691,200 cells.

#### Record columns (1–12)

| Col | Name | Meaning |
|---:|---|---|
| 1 | `typ` | surface type — see table below |
| 2 | `area` | exchange-tile area, **steradians** |
| 3 | `com_lon` | tile centre longitude, degrees |
| 4 | `com_lat` | tile centre latitude, degrees |
| 5 | `i_indg` | grid-1 (atmosphere) I index, 1-based |
| 6 | `j_indg` | grid-1 (atmosphere) J index, 1-based |
| 7 | `frac_cell` | fraction of the **atmosphere** cell this tile occupies |
| 8 | `dummy_index` | grid-1 internal tile index |
| 9 | `i_indg_ocn` | grid-2 I index — **meaning depends on type** |
| 10 | `j_indg_ocn` | grid-2 J index — **meaning depends on type** |
| 11 | `frac_cell_ocn` | fraction of the **surface** tile this exchange tile represents |
| 12 | `dummy_index_ocn` | grid-2 internal tile index |

#### Surface types, and what columns 9–12 mean for each

| `typ` | Surface | Col 9 | Col 10 | Col 12 |
|---:|---|---|---|---|
| `0` | ocean | LLC compact I, 1–23040 | LLC compact J, 1–30 | ocean tile internal index |
| `19` | lake | `190000000` (sentinel) | `1` | index of the **single global lake tile** |
| `20` | land ice | `200000000` (sentinel) | `1` | index of the **single global land-ice tile** |
| `100` | land | Pfafstetter catchment index, 1–291284 | `1` | land tile internal index |

Only ocean records carry a genuine `(I, J)` pair. For land, column 9 is the catchment ID and column 10 is always 1. For lake and land ice, columns 9–10 are fixed sentinels and **every** such record in the file points at one shared tile via column 12 — which is why a file with 32,729 lake records still has exactly one lake surface tile.

#### Worked examples

Land, from this file's first record:

```
100  0.249322871779E-05  0.631784207492E+02  0.409292676971E+02   60  354  0.476951026781E-01  63600   1  1  0.100000000000E+01  1
```

- type 100 = land; area 2.4932e-06 sr; centre 63.178°E, 40.929°N
- atmosphere cell (I=60, J=354), occupying 4.7695% of it
- column 8 = `I + (J-1)*IM` = 60 + 353×180 = **63600** ✓
- Pfafstetter catchment 1, surface fraction 1.0 — this catchment lies wholly inside one atmosphere cell

Land split across two atmosphere cells (records 2 and 3 of this file, catchment 2):

```
100  0.432569497567E-06  ...  60  353  0.818435180154E-02  63420   2  1  0.157147498907E+00  2
100  ...                     ...           ...                     2  1  0.842852501095E+00  2
```

`0.157147498907 + 0.842852501095 = 1.000000000002` — column 11 closes over the surface tile to ASCII precision.

Ocean:

```
0  0.148297032643E-05  -0.390297005428E+02  -0.781009701186E+02   80  1009  0.165223907951E-01  181520   31  1  0.528375243367E+00  290189
```

- atmosphere (80, 1009); column 8 = 80 + 1008×180 = **181520** ✓
- LLC compact cell (31, 1), of which this tile is 52.84%

Lake and land ice:

```
19  0.454455860845E-06  ...  175  893  0.104520669177E-01  160735   190000000  1  0.650690048823E-05  1288865
20  0.310530749254E-07  ...  108  176  0.594318218852E-03   31608   200000000  1  0.786490793296E-07  1288866
```

Note columns 12 are consecutive — the two global aggregate tiles sit adjacent at the end of the surface tile list.

#### Index conventions worth knowing

**Column 8 is a flattened atmosphere index**, `I + (J-1)*IM`, and both examples above confirm it. **Column 12 is not** — for LLC it is an opaque internal tile identifier that cannot be recomputed from columns 9 and 10. In the ocean example, `(31, 1)` would flatten to 31, not 290189. Treat column 12 as authoritative and never regenerate it by hand.

#### Fraction semantics

```
column 7  = tile_area / atmosphere_parent_cell_area
column 11 = tile_area / surface_parent_cell_area
```

Parent cell areas can be recovered by division. For the ocean example: 1.48297e-06 / 0.0165224 ≈ 8.97e-05 sr for the atmosphere cell, and 1.48297e-06 / 0.528375 ≈ 2.81e-06 sr for the LLC cell.

Closure rules, both enforced by this repository's validator:

- **Column 7 sums to 1.0** over every atmosphere cell — all 194,400 of them, to within 2.8e-12 in this build.
- **Column 11 sums to at most 1.0** over each surface tile (grouped by column 12). It equals 1 for a tile wholly of its own type, and less when the tile is only partly covered — a coastal LLC cell that is mostly land contributes only its wet fraction. Sums *above* 1 indicate a defect.

#### Record ordering

Records are grouped by surface type, land first. In this file: land occupies records 1–684,752, followed by lake, land ice, and ocean. Total area over all records sums to 4π steradians (12.566370614359172).

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
  records:  2007319
  land:     684752
  lake:     32729
  land ice: 6836
  ocean:    1283002
  area sum: 12.5663706143605 rad^2 (relative error 1.03e-13)
  atmosphere cells: 194400
  maximum fraction-sum error: 2.79998e-12
  surface tiles: 855510
  partially covered (sum < 1, expected): 29418
  maximum overshoot: 0.00437118
```

Cross-checks against the two shipped production files:

| | this build | v12 MOM6 | v11.7 LLC270 |
|---|---|---|---|
| land | **684,752** | 684,752 | 686,448 |
| lake | 32,729 | 32,725 | 33,287 |
| land ice | **6,836** | 6,836 | 6,904 |
| ocean | 1,283,002 | — | 1,279,740 |
| ocean records with index (0,0) | **0** | 0 | 0 |

Land and land ice match the v12 MOM6 file exactly, confirming the land geometry passed through untouched. Lake is +4 from the reclassified estuary area. The v11.7 column differs throughout because it was built on v11.7 land geometry — it is the right reference for *ocean-side* conventions, not for record counts.

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

Expected for the Meghna estuary, Río de la Plata, and the Kara Sea gulfs. They are reclassified to lake automatically once `--land-lake` is supplied; the main script derives it.

Raising `--max-ocean-distance` above 0 is not recommended — it puts that water into the MIT ocean domain, which inflates the affected cells' surface fractions above 1 because the `.til` areas come from the mitgrid and cannot follow. The deep validation now catches this via the surface-closure check.

### "Surface tiles carrying excess exchange area: N"

A surface tile's fractions sum above 1, meaning it carries more exchange area than its declared size accounts for. On surface type 0 this means raster pixels were assigned to LLC cells whose `.til` area comes from the mitgrid and could not follow — set `--max-ocean-distance 0` and rebuild.

Note this check is **one-sided by design**. Sums *below* 1 are normal: a surface tile only partly of its own type, such as a coastal LLC cell that is mostly land, exchanges only over the covered fraction. The shipped v11.7 LLC270 file has 31,961 such tiles with a worst sum of 0.000540689, so a two-sided test would reject known-good geometry. The validator reports the partial count as information.

The 5e-3 tolerance is calibrated against both production files rather than to an ideal:

| file | overshooting tiles | max overshoot | type |
|---|---|---|---|
| v11.7 LLC270 | 1 | 0.004205 | 19 (global lake tile) |
| v12 MOM6 | 9 | 7.0271e-06 | 100 (land catchments) |

A correct v12 + LLC270 build carries the union of both — one lake tile and those same nine catchments. Anything substantially larger indicates real area inflation; the failed ocean-assignment build reached 0.93.

### Lake and ocean counts differ from the reference tile

Expected, and informative. The v11.7 LLC270 reference has 686,448 land / 33,287 lake / 6,904 land ice, because it was built on v11.7 land geometry. A correct v12 build matches the **v12 MOM6** file instead: 684,752 land / 32,725 lake / 6,836 land ice, plus whatever pixels the reconciliation moved into lake.

## Companion files

`tile.data` is one member of a geometry set. When migrating MOM6 → MITgcm, these change too:

| File | Keyed to | Status for a v12 + LLC270 build |
|---|---|---|
| `tile.data` | atmosphere × land × ocean | produced here |
| `runoff.bin` / `*-Pfafstetter.TRN` | **land tiling + ocean cells** | **needs verification** — see below |
| `mit.ascii` | LLC270 grid | reusable from v11.7 |
| `grid_cice.bin`, `kmt_cice.bin` | LLC270 grid + bathymetry | reusable from v11.7 |
| `SEAWIFS_KPAR_mon_clim.data` | LLC270 grid | reusable from v11.7 |
| land BCs (`vegdyn`, `lai`, `green`, `nirdf`/`visdf`, catchment params) | Pfafstetter tiling | reusable from the same land bundle |
| `MAPL_Tripolar.nc` | MOM6 only | not applicable |

**Why the MIT-side files carry over.** The reconciliation adjusts the *GEOS land mask*, never the MIT ocean domain — the wet-cell set, bathymetry and decomposition are untouched. Anything keyed to the LLC270 grid therefore still describes the same geometry. Confirm dimensioning by checking file sizes divide cleanly by 691,200 (23040 × 30), allowing 8 bytes per Fortran record marker. For example, a KPAR climatology of 38,708,208 bytes decomposes as 126 records × (307,200 + 8), giving 14 × 691,200 single-precision values — 12 months plus two wrap-around months. An LLC90 file would instead be a multiple of 81,000.

**Why runoff does not.** River routing maps catchment outflow to ocean cells, so it depends on both the land tiling *and* which ocean cells exist. The pixels reclassified to lake are river mouths — the Meghna, Río de la Plata, the Ob and Yenisei gulfs — precisely where runoff discharges. A routing file built against different land geometry may direct outflow to tiles that no longer exist in this exchange grid.

## References

- ASCII tile format: `GEOSgcm_GridComp/.../Utils/Raster/makebcs/TileFile_ASCII_to_nc4.F90`
- Rasterization and fraction computation: `.../Utils/Raster/makebcs/rasterize.F90`
- Experiment setup and MIT options: `GEOS-ESM/GEOSgcm_App/gcm_setup`
- MIT ocean build flags: `GEOS-ESM/GEOS_OceanGridComp`, `MIT_GEOS5PlugMod/CMakeLists.txt`
- MITgcm LLC grids: https://mitgcm.readthedocs.io/
- Script options: `generate_geosv12_c180_llc270_tile.sh --help`
- NCCS Discover usage: `run_tile_nccs.sh`, and `GEOS_v12_MITgcm_CICE4_tile_handoff.md` in this repository

## License

These scripts are provided as-is for research use. Adapt and redistribute freely with attribution.

## Contact

For questions about the LLC270 coupling geometry or the repair algorithm, contact the GEOS-MITgcm development team.
