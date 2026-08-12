# GEOS v12 + MITgcm + CICE4 Migration — LLM Handoff Notes

## Purpose

This document summarizes an ongoing technical discussion about migrating an existing **GEOS v12 + MOM6 + CICE4** coupled configuration to **GEOS v12 + MITgcm + CICE4**, while retaining the same MITgcm/CICE4 versions used previously in a working GEOS v11.7 setup.

A major focus has been understanding the GEOS/MAPL ASCII `tile.data` file, especially how atmospheric, land, and ocean exchange-grid mappings are encoded and what would need to change when replacing MOM6 with MITgcm/LLC.

---

# 1. User / Project Context

The user is working on NASA GEOS coupled modeling on NCCS/Discover.

Current source tree is under approximately:

```bash
/discover/nobackup/projects/GEOS_MITgcm/afahad/GEOSv12
```

The old working configuration was:

```text
GEOS v11.7 + MITgcm + CICE4
```

The new starting point is:

```text
GEOS v12 + MOM6 + CICE4
```

Desired target:

```text
GEOS v12 + MITgcm + CICE4
```

The goal is to preserve the same MITgcm/CICE4 versions/configuration as much as possible and determine exactly which GEOS build/runtime/BCS files need to change.

---

# 2. GEOS v12 Source Findings Already Verified

## 2.1 MITgcm version

GEOS v11.7 and GEOS v12 both pin MITgcm to:

```text
checkpoint68o
```

Thus, at least for the inspected tags, the MITgcm source version itself did not change.

Relevant repository:

```text
GEOS-ESM/GEOSgcm
```

Relevant component:

```text
GEOS_OceanGridComp / MIT_GEOS5PlugMod
```

---

## 2.2 MITgcm is selected at build time

Current GEOS v12 ocean component has logic equivalent to:

```cmake
option(BUILD_MIT_OCEAN ... OFF)

if(NOT BUILD_MIT_OCEAN)
    # MOM / normal ocean components
else()
    add_compile_definitions(BUILD_MIT_OCEAN)
    # MIT_GEOS5PlugMod
endif()
```

Therefore a GEOS executable built for MOM6 cannot simply be runtime-switched to MITgcm.

A separate build should be made using something like:

```bash
cmake .. \
  -DBASEDIR=$BASEDIR/Linux \
  -DCMAKE_INSTALL_PREFIX=../install \
  -DBUILD_MIT_OCEAN=ON \
  -DMIT_CONFIG_ID=c90_llc90_02
```

The exact `MIT_CONFIG_ID` should match the old working MIT setup if possible.

Known MIT configuration directories in the inspected GEOS v12 source include:

```text
c12_cs32_01
c90_llc90_02
c90_llc90_03
c90_llc90_05
```

---

## 2.3 CICE4 is still supported with MIT in GEOS v12

Although newer GEOS code also contains CICE6 support, the v12 source still contains the MIT + CICE4 pathway.

Conceptually:

```text
GEOSseaice_GridComp
    |
    +-- CICE4 path
    |
    +-- GEOSMITDyna_GridComp when BUILD_MIT_OCEAN is enabled
```

`GEOSMITDyna_GridComp` still depends on CICE4.

Therefore:

```text
GEOS v12 + MITgcm + CICE4
```

is represented in current source and is not merely an old v11.7 architecture.

---

# 3. GEOS v12 `gcm_setup` MIT Behavior

The inspected v12 `gcm_setup` still offers:

```text
Choose Ocean Model
    MOM5
    MOM6
    MIT
```

and sea ice choices:

```text
CICE4
CICE6
```

Important MIT restrictions in the inspected setup:

```text
MIT requires c90 atmosphere
```

MIT setup uses:

```text
OGCM_GRID_TYPE = llc
OGRIDTYP       = MITLLC
OGCM_JM        = 15
OGCM_IM        = 5400
OGCM_NX        = 360
OGCM_NY        = 1
OGCM_GRIDSPEC  = mit.ascii
```

MIT also uses:

```text
OCEAN_DIR = mitocean_run
```

and a MIT-specific HISTORY template:

```text
HISTORY.AOGCM_MITgcm.rc.tmpl
```

Thus, the safest approach is to create a fresh GEOS v12 MIT+CICE4 experiment using `gcm_setup`, rather than editing a working MOM6 experiment in place.

---

# 4. Major Files / Assets That Change Between MOM6 and MITgcm

The following groups are expected to differ:

```text
GEOS executable / build
AGCM.rc ocean settings
ocean grid specification
ocean runtime input directory
ocean restart files
CICE4 grid/mask files
tile.data
runoff.bin / Pfafstetter transport
MIT-specific remapping assets
HISTORY.rc
```

Specifically:

MOM6 typically uses:

```text
MAPL_Tripolar.nc
```

MIT uses:

```text
mit.ascii
```

MIT runtime directory:

```text
mitocean_run
```

GEOS v12 `linkbcs` contains MIT-specific linking similar to:

```bash
ln -sf .../mit.ascii
ln -sf .../DC0360xPC0181_LL5400x15-LL.bin
```

CICE4 links include:

```bash
grid_cice.bin
kmt_cice.bin
```

The combined GEOS/MAPL geometry uses:

```text
tile.data
runoff.bin
```

---

# 5. Important Distinction Between Files

Do not confuse these files:

## `tile.data`

Combined GEOS/MAPL exchange-grid / surface tiling.

It maps atmosphere cells to land/ocean surface pieces.

## `mit.ascii`

MIT ocean-grid description.

## `runoff.bin`

Pfafstetter routing / runoff mapping tied to the combined surface geometry.

## `grid_cice.bin`, `kmt_cice.bin`

CICE4 grid and ocean/ice mask associated with the ocean grid.

## `MAPL_Tripolar.nc`

MOM/MOM6 grid specification; not the MIT equivalent.

---

# 6. GEOS/MAPL ASCII `tile.data` Format

The user supplied this header:

```text
2006379    291284     43200     21600
2
PE180x1080-CF
180
1080
LL23040x30-LL
23040
30
```

Interpretation:

```text
2006379 = number of exchange tiles
291284  = number of Pfafstetter catchments
43200   = raster NX
21600   = raster NY

2       = number of grids

GRID 1:
PE180x1080-CF
IM = 180
JM = 1080

GRID 2:
LL23040x30-LL
IM = 23040
JM = 30
```

The `43200 x 21600` raster corresponds to 30 arc-second global raster dimensions:

```text
360 / 43200 = 0.008333333 deg = 30 arcsec
```

---

# 7. Authoritative GEOS v12 ASCII Tile Column Ordering

The relevant source is:

```text
GEOS-ESM/GEOSgcm_GridComp
GEOSagcm_GridComp/GEOSphysics_GridComp/GEOSsurface_GridComp/
Utils/Raster/makebcs/TileFile_ASCII_to_nc4.F90
```

The ASCII reader explicitly reads a normal 2-grid tile record as:

```fortran
read (...) iTable(1,0), rTable(1,3), rTable(1,1), rTable(1,2), &
           iTable(1,2), iTable(1,3), rTable(1,4), iTable(1,6), &
           iTable(1,4), iTable(1,5), rTable(1,5), iTable(1,7)
```

Therefore the 12 ASCII columns are:

| Column | Meaning |
|---:|---|
| 1 | Surface type |
| 2 | Exchange-tile area, radians² |
| 3 | Tile center longitude, degrees |
| 4 | Tile center latitude, degrees |
| 5 | Grid-1 I index |
| 6 | Grid-1 J index |
| 7 | Fraction of Grid-1 cell occupied by this exchange tile |
| 8 | Grid-1 internal/dummy index |
| 9 | Grid-2 I index |
| 10 | Grid-2 J index |
| 11 | Fraction of Grid-2 cell represented by this exchange tile |
| 12 | Grid-2 internal/dummy index |

The corresponding NetCDF4 names in current GEOS source are approximately:

```text
typ
area
com_lon
com_lat
i_indg
j_indg
frac_cell
dummy_index

i_indg_ocn
j_indg_ocn
frac_cell_ocn
dummy_index_ocn
```

The source describes the dummy field as:

```text
internal_dummy_index_of_tile
```

Important: do NOT universally assume column 8 or 12 is defined by the API as a flattened index, even though column 8 often numerically behaves that way.

---

# 8. Surface Type Codes

From GEOS land-raster logic:

```text
0   = ocean
19  = lake
20  = land ice
100 = land
```

---

# 9. Example Land Records

Example supplied by user:

```text
100  0.249322871779E-05  0.631784207492E+02  0.409292676971E+02
 60 354  0.476951026781E-01 63600
  1   1  0.100000000000E+01 1
```

Decoded:

```text
col 1  = 100                    land
col 2  = 2.49322871779E-06     tile area [rad²]
col 3  = 63.1784207492          lon
col 4  = 40.9292676971          lat

col 5  = 60                     grid-1 I
col 6  = 354                    grid-1 J
col 7  = 0.0476951026781        fraction of grid-1 cell
col 8  = 63600                  grid-1 internal index

col 9  = 1
col 10 = 1
col 11 = 1.0
col 12 = 1
```

For this atmospheric grid:

```text
IM = 180
I  = 60
J  = 354
```

column 8 is numerically:

```text
I + (J-1)*IM
= 60 + 353*180
= 63600
```

Thus grid-1 dummy/index is behaving as a flattened atmospheric index in this file.

---

# 10. Important Land-Side Interpretation of Columns 9–12

For non-ocean tiles, columns 9–12 should not simply be interpreted as normal ocean-cell coordinates.

Current GEOS conversion code treats the second-grid I index for `type=100` as the Pfafstetter index:

```fortran
where (iTable(:,0) == 100)
    pfaf = II
endwhere
```

and masks ocean I/J for non-ocean tiles in the newer representation.

Therefore, for land tiles:

```text
column 9
```

is effectively associated with the Pfafstetter/catchment-side surface element.

Example:

```text
row 2:
100 ... 2 1 0.157147498907 2

row 3:
100 ... 2 1 0.842852501095 2
```

The fractions add to approximately 1:

```text
0.157147498907 + 0.842852501095 ≈ 1
```

This means one surface/Pfaf element is split across two atmospheric exchange tiles.

---

# 11. MITgcm LLC270 Ocean Example

The user then provided a true ocean tile from an MITgcm LLC270 run:

```text
0  0.148297032643E-05  -0.390297005428E+02  -0.781009701186E+02
80 1009  0.165223907951E-01 181520
31    1   0.528375243367E+00 290189
```

Decoded:

```text
col 1  = 0                       ocean
col 2  = 1.48297032643E-06      exchange tile area [rad²]
col 3  = -39.0297005428         longitude
col 4  = -78.1009701186         latitude

col 5  = 80                      atmosphere/grid-1 I
col 6  = 1009                    atmosphere/grid-1 J
col 7  = 0.0165223907951         fraction of atmosphere cell
col 8  = 181520                  atmosphere internal index

col 9  = 31                      ocean/grid-2 I
col 10 = 1                       ocean/grid-2 J
col 11 = 0.528375243367          fraction of ocean cell
col 12 = 290189                  ocean internal/dummy index
```

For the atmosphere side:

```text
I = 80
J = 1009
IM = 180
```

and:

```text
80 + (1009-1)*180
= 181520
```

exactly matching column 8.

---

# 12. Important MIT/LLC Indexing Observation

For the MIT LLC row:

```text
ocean I     = 31
ocean J     = 1
ocean dummy = 290189
```

The ocean dummy index is clearly NOT a simple:

```text
I + (J-1)*IM
```

based on columns 9 and 10.

Therefore:

```text
column 12
```

must be treated as a separate internal ocean-tile/grid identifier.

Current GEOS source itself calls it:

```text
internal_dummy_index_of_tile
```

Do not recompute it manually from columns 9 and 10 unless the LLC-specific indexing routine is identified.

This is expected to matter for MIT LLC compact/faced layouts.

---

# 13. Meaning of Tile Fractions

For an ocean exchange tile:

```text
column 7  = tile_area / atmospheric_parent_cell_area
column 11 = tile_area / ocean_parent_cell_area
```

For the MIT LLC example:

```text
tile area     = 1.48297032643E-06 rad²
atmos fraction = 0.0165223907951
ocean fraction = 0.528375243367
```

Approximate parent cell areas:

```text
atmos cell area
= 1.48297032643E-06 / 0.0165223907951
≈ 8.97E-05 rad²

ocean cell area
= 1.48297032643E-06 / 0.528375243367
≈ 2.81E-06 rad²
```

This confirms the exchange-grid interpretation: one atmospheric cell may overlap multiple ocean cells and one ocean cell may overlap multiple atmospheric cells.

---

# 14. Consequence for MOM6 → MIT Tile Conversion

It is NOT safe to take the MOM6 `tile.data` and only replace columns 9–12.

When the ocean grid changes, these may all change for ocean tiles:

```text
column 2  tile area
column 3  tile center lon
column 4  tile center lat
column 7  atmosphere fraction
column 9  ocean I
column 10 ocean J
column 11 ocean fraction
column 12 ocean internal index
```

Why?

Because the actual intersection polygons between atmosphere and ocean grid cells change.

Thus:

```text
MOM6 exchange tile geometry != MIT LLC exchange tile geometry
```

even if the atmosphere grid is unchanged.

---

# 15. Tile Reuse Guidance

A GEOS v11.7 MIT `tile.data` may potentially be reusable in GEOS v12 if all geometry-defining inputs are unchanged:

```text
same atmospheric grid
same MIT LLC grid
same MIT bathymetry/wet mask
same land mask version
same Pfafstetter/catchment raster
same CICE grid/mask
same relevant BCS geometry conventions
```

But it should NOT be reused solely because the MITgcm version is unchanged.

The land BCS / Pfafstetter system may have changed between GEOS versions.

Treat at least these as a related geometry set:

```text
tile.data
runoff.bin / Pfafstetter transport
```

and likely also verify:

```text
mit.ascii
grid_cice.bin
kmt_cice.bin
```

against the exact LLC configuration.

---

# 16. GEOS Tile Generation Background

Current GEOS boundary-condition tools conceptually do:

```text
atmospheric raster
+
land/Pfafstetter raster
+
ocean raster
=
combined surface / exchange tiling
```

A key tool is:

```text
CombineRasters
```

Its source describes the process as overlaying atmosphere, land, and ocean rasters to create unique exchange tiles.

Current general GEOS BCS scripts have obvious branches for some regular/MOM grids, but an explicit modern LLC90 raster-generation path has not yet been identified.

Therefore do NOT yet assume the generic current `make_bcs_cube.py` can create the required MIT LLC tile from scratch without an MIT-specific ocean-raster input or legacy tool.

---

# 17. Recommended Migration Strategy

Preferred approach:

1. Build GEOS v12 with MIT enabled:

```bash
-DBUILD_MIT_OCEAN=ON
-DMIT_CONFIG_ID=<matching old MIT config>
```

2. Create a fresh experiment using GEOS v12 `gcm_setup`.

3. Select:

```text
Atmosphere: c90
Coupled: YES
Ocean: MIT
Sea ice: CICE4
Ocean grid: LLC90
```

4. Use the GEOS v12-generated runtime configuration as the baseline.

5. Migrate only the needed old MIT input/restart state and configuration details.

Do NOT copy the whole old v11.7 `AGCM.rc` into v12.

---

# 18. Useful Diagnostics to Run

From a working old MIT experiment and the v12 MOM6 experiment:

```bash
grep -E 'OGCM|OCEAN_DIR|GRIDNAME|GRIDSPEC' AGCM.rc
```

```bash
ls -l tile.data mit.ascii runoff.bin grid_cice.bin kmt_cice.bin 2>/dev/null
```

```bash
head -15 tile.data
```

```bash
readlink -f tile.data
readlink -f mit.ascii
readlink -f runoff.bin
```

To identify MIT build configuration:

```bash
grep -E 'BUILD_MIT_OCEAN|MIT_CONFIG_ID' build/CMakeCache.txt
```

To inspect ocean tiles:

```bash
awk '$1 == 0 {print; exit}' tile.data
```

First 10 ocean tiles:

```bash
awk '$1 == 0 {print; if (++n == 10) exit}' tile.data
```

For LLC indexing investigation:

```bash
awk '$1==0 {print $9,$10,$12; if(++n==20) exit}' tile.data
```

---

# 19. Immediate Open Question

The next key technical task is to determine the exact relationship between:

```text
column 9  = LLC ocean I
column 10 = LLC ocean J
column 12 = LLC internal index
```

for MIT LLC270 and, ultimately, LLC90.

This requires locating the GEOS/MIT LLC raster-generation/indexing code or examining enough LLC tile records to infer the indexing convention.

In particular, the LLC internal index should NOT be guessed from the rectangular `I,J` pair.

---

# 20. Source Files Already Consulted

Primary GEOS source references used in the discussion:

## ASCII tile reader / writer

```text
GEOS-ESM/GEOSgcm_GridComp
GEOSagcm_GridComp/GEOSphysics_GridComp/GEOSsurface_GridComp/
Utils/Raster/makebcs/TileFile_ASCII_to_nc4.F90
```

This is the strongest reference for the 12-column ASCII tile format.

## Raster / tiling implementation

```text
GEOS-ESM/GEOSgcm_GridComp
GEOSagcm_GridComp/GEOSphysics_GridComp/GEOSsurface_GridComp/
Utils/Raster/makebcs/rasterize.F90
```

Important source comments include:

```text
iTable(0) :: Surface type
iTable(2) :: I_1
iTable(3) :: J_1
iTable(4) :: I_2
iTable(5) :: J_2

rTable(1) :: longitude
rTable(2) :: latitude
rTable(3) :: tile area
rTable(4) :: first grid box area
rTable(5) :: second grid box area
```

The writer computes fraction as:

```fortran
fr = area / rTable(4)
```

and analogous logic is used for the second grid.

## GEOS v12 experiment setup

```text
GEOS-ESM/GEOSgcm_App/gcm_setup
```

Used to verify MIT and CICE4 choices, c90 restriction, LLC configuration, and MIT-specific runtime settings.

## Ocean component build

```text
GEOS-ESM/GEOS_OceanGridComp
```

Relevant areas:

```text
CMakeLists.txt
MIT_GEOS5PlugMod/CMakeLists.txt
```

---

# 21. Key Conclusions So Far

The most important conclusions are:

1. **GEOS v12 still supports MITgcm + CICE4.**

2. **MITgcm is a build-time option**, not just an `AGCM.rc` switch.

3. **MITgcm source version remains checkpoint68o** in the inspected v11.7 and v12 component manifests.

4. **The 12 ASCII `tile.data` columns are now well identified from GEOS source.**

5. For ocean tiles:
   ```text
   cols 5–8  = atmosphere-side mapping
   cols 9–12 = ocean-side mapping
   ```

6. Column 8 often equals the flattened atmospheric index.

7. **Column 12 for MIT LLC does not equal a simple flattened `(I,J)` index.**

8. The exchange-grid tile geometry itself changes when swapping MOM6 → MIT, so replacing only ocean-index columns is unsafe.

9. A complete existing MIT LLC tile set may be reusable if geometry inputs are truly identical, but that needs verification.

10. The next priority is identifying the LLC raster/index-generation convention and comparing old MIT LLC90 BCS assets against the new v12 environment.

