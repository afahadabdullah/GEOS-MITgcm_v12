GEOS v12: MOM6+CICE4 -> MITgcm+CICE4 (c180 / LLC270)
List of changes made.


CODE
----

1. gc2gc.F90
   Handle actual CICE field rank and precision (rank-1 vs rank-2, R8 vs R4)
   instead of assuming they match; convert R4<->R8 where needed.
   Was causing MAPL_GetPointer failures.

2. GEOS_OgcmGridComp.F90
   Guarded CALVING termination by OCEAN_NAME.

3. GEOS_OceanGridComp.F90, SetServices (~line 199)
   Dropped 'CALVING' from the MAPL_TerminateImport list for MIT only.
   Applied by patch_calving_mit.py.

4. GEOS_OceanGridComp.F90, run phase (~line 592)
   Replaced MAPL_GetPointer(GIM(OCN), CALVING, ...) with, for MIT only,
   allocate(CALVING(size(DISCHARGE,1), size(DISCHARGE,2))); CALVING = 0.0
   Added guarded deallocate after the PEN_OCNe line, before end of DO_DATASEA.
   Applied by patch_calving_mit_run.py.


SCRIPTS / CONFIG
----------------

5. gcm_setup
   - Added DOMITOCN menu (c180 -> LLC270, c90 -> LLC90).
   - Added OGCM_NTILES, replacing hardcoded 360 tile count.
   - Added MIT override deriving OGCM_NX/OGCM_NY from OGCM_NTILES (768).

6. AGCM.rc
   - NX = 30, NY = 36 (was NX:1 NY:768, invalid for c180).
   - OGCM.GRIDNAME reconciled with grid-2 name in the tile file
     (MITLLC23040x30-MITLLC vs LL23040x30-LL).  << confirm which side was edited

7. MOM boundary-condition filenames
   Reverted to pre-MOM6-CICE6 names; MOM6-CICE4 requires the older ones.


RESTARTS / INPUT FILES
----------------------

8. iced.nc
   Modified to match the CICE4 configuration.

9. seaicethermo_internal_rst
   Set to 5 ice categories, 4 ice layers, 1 snow layer.

10. Restart sources
    from v11.7 MIT : openwater_internal, saltwater_import,
                     seaicethermo_internal (remapped LLC270 -> LLC270)
                     seaice_import (straight copy, ocean grid 23040x30)
    from v12 MOM6  : catch_internal, landice_internal (straight copy),
                     lake_internal (remapped)
    straight copy  : 25 upper-air restarts (c180/91L both sides)

11. remap_params_v117ice_to_llc270.yaml
    New. v11.7 -> v12 LLC270, remap_water only, remap_catch false.

12. remap_params_mom6_to_llc270.yaml
    New. v12 MOM6 tripolar -> LLC270 (superseded for ice by #11).


NOTES
-----

- tile.bin is rebuilt from tile.data only under `if (! -e tile.bin)`.
  Delete scratch/tile.bin after any .til change.
- source g5_modules before make, or genmake2 leaves no MPI include paths
  (shows up as mpif.h: No such file or directory).
- The experiment directory holds its own GEOSgcm.x; copy it after each rebuild.
- CALVING is declared in the ACG-generated GEOS_Ocean_Import___.h, not in
  source. To find other fields MIT lacks:
    grep -o "SHORT_NAME *= *'[A-Z_0-9]*'" GEOS_Ocean_Import___.h | sort -u
