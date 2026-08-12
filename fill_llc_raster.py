#!/usr/bin/env python3
"""Reconcile the GEOS land mask with the MITgcm LLC ocean domain.

The problem
-----------
mkMITAquaRaster.x writes the LLC compact index of the ocean cell covering each
43200x21600 raster pixel, and RASTERUNDEF (-999) everywhere the LLC domain has
no wet cell.  That is normal for ~20% of the raster: the land surface.
CombineRasters.x resolves those pixels from the Pfafstetter land raster.

The defect is narrower.  The GEOS v12 land mask was built against the MOM6
tripolar ocean grid, which resolves estuaries and fjords that the coarser LLC270
closes off.  Where the land mask says *ocean* but the LLC raster is RASTERUNDEF,
CombineRasters has neither an ocean cell nor a land catchment to reference.  It
falls back on the Pfafstetter ocean placeholder tile -- a zero-area record with
zero indices -- and every such pixel is attributed to it, producing ocean
exchange records carrying compact index (0,0) in the final tile.data.

The policy
----------
Not every mismatched pixel should become ocean.  A pixel a few kilometres from a
wet LLC cell is a sub-grid coastline sliver and belongs to that cell.  A pixel
deep inside the Meghna estuary or the Rio de la Plata is more than 100 km from
any wet LLC cell; assigning it to the nearest one would dump a whole grid cell's
worth of estuarine freshwater into open ocean.  The established GEOS v11.7
LLC270 tile file treats that water as lake, not ocean.

So each mismatched pixel is resolved by distance:

  nearest wet LLC cell within --max-distance   -> assign that compact index
  otherwise                                    -> reclassify to lake in the
                                                  land raster

Both rasters are written out, and CombineRasters then derives every area and
fraction itself.  Neither input is modified.

Usage
-----
    # cheap scan: what is in these rasters?
    fill_llc_raster.py --inspect \\
        --llc-raster raw.rst --land-raster Pfafstetter.rst \\
        --valid-max 691200 --land-ocean 289836

    # full decision pass, no files written
    fill_llc_raster.py --dry-run \\
        --llc-raster raw.rst --land-raster Pfafstetter.rst \\
        --valid-max 691200 --land-ocean 289836 --land-lake 289837

    # write both repaired rasters
    fill_llc_raster.py \\
        --llc-raster raw.rst --land-raster Pfafstetter.rst \\
        --llc-output llc_fixed.rst --land-output land_fixed.rst \\
        --valid-max 691200 --land-ocean 289836 --land-lake 289837
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import sys
import time
from collections import Counter, OrderedDict

try:
    import numpy as np
except ImportError:  # pragma: no cover
    sys.exit("ERROR: numpy is required (module load python/GEOSpyD)")


NX_DEFAULT = 43200
NY_DEFAULT = 21600


class Raster:
    """A GEOS .rst raster with auto-detected on-disk layout.

    GEOS writes these either as flat binary or as Fortran sequential records
    (one record per raster row, bracketed by 4-byte length markers).  Element
    width is inferred from the file size; LLC270 needs 32-bit indices because
    the compact grid has 691200 cells.
    """

    def __init__(self, path: str, nx: int, ny: int, mode: str = "rb"):
        self.path = path
        self.nx = nx
        self.ny = ny

        size = os.path.getsize(path)
        candidates = [
            (np.int32, True, ny * (nx * 4 + 8)),
            (np.int32, False, nx * ny * 4),
            (np.int16, True, ny * (nx * 2 + 8)),
            (np.int16, False, nx * ny * 2),
        ]

        self.dtype = None
        for dtype, fortran, expected in candidates:
            if size == expected:
                self.dtype, self.fortran = dtype, fortran
                break

        if self.dtype is None:
            expected = ", ".join(str(c[2]) for c in candidates)
            sys.exit(
                f"ERROR: cannot infer layout of {path}\n"
                f"  file size: {size} bytes\n"
                f"  expected one of: {expected}\n"
                f"  (for a {nx}x{ny} raster)"
            )

        self.itemsize = np.dtype(self.dtype).itemsize
        self.pad = 4 if self.fortran else 0
        self.row_bytes = nx * self.itemsize + 2 * self.pad
        self.fh = open(path, mode)

    def describe(self) -> str:
        kind = "Fortran sequential" if self.fortran else "flat binary"
        return f"{self.nx}x{self.ny} {np.dtype(self.dtype).name} ({kind})"

    def _offset(self, j: int) -> int:
        return j * self.row_bytes + self.pad

    def read_row(self, j: int) -> "np.ndarray":
        self.fh.seek(self._offset(j))
        buf = self.fh.read(self.nx * self.itemsize)
        return np.frombuffer(buf, dtype=self.dtype).copy()

    def write_row(self, j: int, row: "np.ndarray") -> None:
        self.fh.seek(self._offset(j))
        self.fh.write(np.asarray(row, dtype=self.dtype).tobytes())

    def close(self) -> None:
        self.fh.close()


class RowCache:
    """LRU cache of raster rows, so clustered gaps do not re-read from disk."""

    def __init__(self, raster: Raster, capacity: int = 512):
        self.raster = raster
        self.capacity = capacity
        self._rows: "OrderedDict[int, np.ndarray]" = OrderedDict()

    def get(self, j: int) -> "np.ndarray":
        row = self._rows.get(j)
        if row is not None:
            self._rows.move_to_end(j)
            return row
        row = self.raster.read_row(j)
        self._rows[j] = row
        if len(self._rows) > self.capacity:
            self._rows.popitem(last=False)
        return row


def valid_llc(row: "np.ndarray", valid_min: int, valid_max: int) -> "np.ndarray":
    """Boolean mask of raster values usable as LLC compact indices."""
    good = row >= valid_min
    if valid_max > 0:
        good &= row <= valid_max
    return good


def scan(
    llc: Raster,
    land: Raster,
    valid_min: int,
    valid_max: int,
    land_ocean: int,
    progress_every: int = 2000,
):
    """Locate pixels undefined in the LLC raster but marked ocean in the land raster."""
    targets = []
    n_target = 0
    n_undef = 0
    llc_markers: "Counter[int]" = Counter()
    land_values: "Counter[int]" = Counter()
    lo = hi = None

    for j in range(llc.ny):
        row = llc.read_row(j)
        row_lo, row_hi = int(row.min()), int(row.max())
        lo = row_lo if lo is None else min(lo, row_lo)
        hi = row_hi if hi is None else max(hi, row_hi)

        undefined = ~valid_llc(row, valid_min, valid_max)
        n_undef_row = int(undefined.sum())
        n_undef += n_undef_row

        if n_undef_row:
            # Exact tallies, not a head-of-row sample: a truncated sample is
            # spatially biased toward one edge of the map.
            values, counts = np.unique(row[undefined], return_counts=True)
            for value, count in zip(values.tolist(), counts.tolist()):
                llc_markers[int(value)] += int(count)

            land_row = land.read_row(j)
            values, counts = np.unique(land_row[undefined], return_counts=True)
            for value, count in zip(values.tolist(), counts.tolist()):
                land_values[int(value)] += int(count)

            idx = np.flatnonzero(undefined & (land_row == land_ocean))
            if idx.size:
                targets.append((j, idx))
                n_target += int(idx.size)

        if progress_every and j and j % progress_every == 0:
            print(
                f"  scanned row {j}/{llc.ny} "
                f"(llc undefined {n_undef}, mismatches {n_target})",
                flush=True,
            )

    return targets, n_target, n_undef, lo, hi, llc_markers, land_values


def nearest_valid(
    cache: RowCache,
    nx: int,
    ny: int,
    j0: int,
    i0: int,
    max_radius: int,
    valid_min: int,
    valid_max: int,
    start_radius: int = 16,
):
    """Return (compact_index, distance) of the nearest usable LLC pixel.

    Scans a square window once per radius and doubles on failure, rather than
    restarting a growing scan at every integer radius -- the latter costs
    O(R^3) element operations per pixel and is unusably slow at large R.

    A square of half-width R contains every pixel within Euclidean distance R,
    but a candidate found in a corner may lie further than R, in which case a
    nearer one could sit outside the square.  The result is therefore accepted
    only once best_distance <= radius.

    Longitude wraps; latitude does not.  Returns (0, None) if nothing is found
    within max_radius, which the caller resolves by reclassification.
    """
    half = nx // 2
    radius = max(1, start_radius)

    while True:
        jlo = max(0, j0 - radius)
        jhi = min(ny - 1, j0 + radius)
        offsets = (np.arange(i0 - radius, i0 + radius + 1) % nx).astype(np.int64)
        di = (offsets - i0 + half) % nx - half
        di2 = di * di

        best_value = 0
        best_d2 = None

        for j in range(jlo, jhi + 1):
            values = cache.get(j)[offsets]
            good = np.flatnonzero(valid_llc(values, valid_min, valid_max))
            if good.size == 0:
                continue
            dj = j - j0
            d2 = di2[good] + dj * dj
            k = int(np.argmin(d2))
            if best_d2 is None or int(d2[k]) < best_d2:
                best_d2 = int(d2[k])
                best_value = int(values[good[k]])

        if best_value and best_d2 <= radius * radius:
            return best_value, math.sqrt(best_d2)
        if radius >= max_radius:
            if best_value:
                return best_value, math.sqrt(best_d2)
            return 0, None

        radius = min(radius * 2, max_radius)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Reconcile the GEOS land mask with the MITgcm LLC ocean domain.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--llc-raster", required=True, help="raw .rst from mkMITAquaRaster.x")
    ap.add_argument("--land-raster", required=True, help="Pfafstetter.rst")
    ap.add_argument("--llc-output", help="repaired LLC raster to write")
    ap.add_argument("--land-output", help="repaired land raster to write")
    ap.add_argument("--nx", type=int, default=NX_DEFAULT, help="raster width")
    ap.add_argument("--ny", type=int, default=NY_DEFAULT, help="raster height")
    ap.add_argument("--valid-min", type=int, default=1, help="lowest usable compact index")
    ap.add_argument("--valid-max", type=int, default=0, help="highest usable compact index (0 = none)")
    ap.add_argument("--land-ocean", type=int, required=True, help="ocean marker in the land raster")
    ap.add_argument("--land-lake", type=int, help="lake marker in the land raster")
    ap.add_argument(
        "--max-distance",
        type=float,
        default=0.0,
        help="assign to ocean only within this many pixels; beyond it, reclassify to lake "
             "(0 = always reclassify, which keeps LLC cell areas consistent with the mitgrid)",
    )
    ap.add_argument("--max-radius", type=int, default=256, help="hard search limit in pixels")
    ap.add_argument("--report", default=None, help="write a decision report here")
    ap.add_argument("--inspect", action="store_true", help="cheap scan only, then exit")
    ap.add_argument("--dry-run", action="store_true", help="decide everything but write nothing")
    ap.add_argument(
        "--max-fill-fraction",
        type=float,
        default=0.01,
        help="refuse to act on more than this fraction of the raster",
    )
    args = ap.parse_args()

    for path in (args.llc_raster, args.land_raster):
        if not os.path.isfile(path):
            sys.exit(f"ERROR: raster not found: {path}")

    writing = not (args.inspect or args.dry_run)
    if writing and not (args.llc_output and args.land_output):
        sys.exit("ERROR: --llc-output and --land-output are required unless --inspect/--dry-run")

    llc = Raster(args.llc_raster, args.nx, args.ny)
    land = Raster(args.land_raster, args.nx, args.ny)
    print(f"[fill_llc_raster] llc raster:  {args.llc_raster}")
    print(f"[fill_llc_raster]   layout:    {llc.describe()}")
    print(f"[fill_llc_raster] land raster: {args.land_raster}")
    print(f"[fill_llc_raster]   layout:    {land.describe()}")
    print(f"[fill_llc_raster]   ocean marker {args.land_ocean}, lake marker {args.land_lake}")

    bound = args.valid_max if args.valid_max > 0 else "unbounded"
    print(f"[fill_llc_raster] usable index range: {args.valid_min}..{bound}")
    print("[fill_llc_raster] scanning")

    targets, n_target, n_undef, lo, hi, llc_markers, land_values = scan(
        llc, land, args.valid_min, args.valid_max, args.land_ocean
    )
    llc.close()
    land.close()

    total_pixels = args.nx * args.ny
    print(f"[fill_llc_raster] llc value range: {lo} .. {hi}")
    print(
        f"[fill_llc_raster] llc undefined: {n_undef} "
        f"({100.0 * n_undef / total_pixels:.2f}% of raster -- the land surface)"
    )
    if llc_markers:
        seen = ", ".join(f"{v} (x{c})" for v, c in llc_markers.most_common(5))
        print(f"[fill_llc_raster]   markers: {seen}")
    if land_values:
        print(f"[fill_llc_raster]   land values where llc is undefined ({len(land_values)} distinct):")
        for value, count in land_values.most_common(12):
            share = 100.0 * count / max(n_undef, 1)
            print(f"[fill_llc_raster]     {value:>10d}  {count:>12d}  {share:6.2f}%")
    print(f"[fill_llc_raster] mask mismatches (llc undefined AND land ocean): {n_target}")

    if args.inspect:
        if targets:
            j, columns = targets[0]
            print(f"[fill_llc_raster] first mismatch: row {j}, column {int(columns[0])}")
        return 0

    if n_target == 0:
        print("[fill_llc_raster] nothing to reconcile")
        if writing:
            shutil.copyfile(args.llc_raster, args.llc_output)
            shutil.copyfile(args.land_raster, args.land_output)
        return 0

    fraction = n_target / total_pixels
    if fraction > args.max_fill_fraction:
        print(
            f"ERROR: {n_target} mismatches is {100.0 * fraction:.2f}% of the raster, "
            f"above --max-fill-fraction={100.0 * args.max_fill_fraction:.2f}%.\n"
            "  A genuine coastline mismatch is a few tens of thousands of pixels.\n"
            "  Check that --land-ocean is the right marker.",
            file=sys.stderr,
        )
        return 1

    # ---- decide everything before writing anything -------------------------
    # An earlier version wrote rows as it went and then failed at the end,
    # leaving a half-repaired raster on disk.  Decisions are cheap to hold in
    # memory for a few tens of thousands of pixels, so resolve first.
    src = Raster(args.llc_raster, args.nx, args.ny)
    cache = RowCache(src)

    assign: "dict[int, list[tuple[int, int]]]" = {}
    reclass: "dict[int, list[int]]" = {}
    gained: "Counter[int]" = Counter()
    distances: "Counter[int]" = Counter()
    n_assigned = 0
    n_reclass = 0

    done = 0
    report_every = max(1, n_target // 20)
    started = time.time()

    for j, columns in targets:
        for i in columns.tolist():
            value, distance = nearest_valid(
                cache, args.nx, args.ny, j, int(i),
                args.max_radius, args.valid_min, args.valid_max,
            )
            if value and distance is not None and distance <= args.max_distance:
                assign.setdefault(j, []).append((int(i), value))
                gained[value] += 1
                distances[int(distance)] += 1
                n_assigned += 1
            else:
                reclass.setdefault(j, []).append(int(i))
                n_reclass += 1

            done += 1
            if done % report_every == 0:
                elapsed = time.time() - started
                rate = done / elapsed if elapsed > 0 else 0.0
                print(
                    f"  resolved {done}/{n_target} ({100.0 * done / n_target:.0f}%, "
                    f"{rate:.0f} px/s)",
                    flush=True,
                )

    src.close()

    print(f"[fill_llc_raster] assigned to a nearby LLC cell: {n_assigned} "
          f"(within {args.max_distance:g} px)")
    print(f"[fill_llc_raster] reclassified to lake:          {n_reclass}")
    if gained:
        index, count = gained.most_common(1)[0]
        print(f"[fill_llc_raster] receiving cells: {len(gained)}, "
              f"largest gain {count} pixels (compact index {index})")

    if n_reclass and not args.land_lake:
        print(
            f"ERROR: {n_reclass} pixels are further than {args.max_distance:g} px from any\n"
            "  wet LLC cell and must be reclassified, but --land-lake was not given.\n"
            "  Find the lake placeholder record in Pfafstetter.til:\n"
            "    awk 'NR > 5 && $1 == 19 {print NR - 5; exit}' Pfafstetter.til",
            file=sys.stderr,
        )
        return 1

    if args.report:
        with open(args.report, "w") as fh:
            fh.write(f"llc undefined pixels:  {n_undef}\n")
            fh.write(f"mask mismatches:       {n_target}\n")
            fh.write(f"assigned to ocean:     {n_assigned}\n")
            fh.write(f"reclassified to lake:  {n_reclass}\n")
            fh.write(f"max-distance:          {args.max_distance}\n\n")
            fh.write("distance_px  pixels_assigned\n")
            for distance, count in sorted(distances.items()):
                fh.write(f"{distance:11d}  {count:d}\n")
            fh.write("\ncompact_index  pixels_gained\n")
            for index, count in gained.most_common():
                fh.write(f"{index:13d}  {count:d}\n")
        print(f"[fill_llc_raster] report: {args.report}")

    if args.dry_run:
        print("[fill_llc_raster] dry run; nothing written")
        return 0

    # ---- write -------------------------------------------------------------
    print(f"[fill_llc_raster] writing {args.llc_output}")
    shutil.copyfile(args.llc_raster, args.llc_output)
    print(f"[fill_llc_raster] writing {args.land_output}")
    shutil.copyfile(args.land_raster, args.land_output)

    llc_src = Raster(args.llc_raster, args.nx, args.ny)
    llc_dst = Raster(args.llc_output, args.nx, args.ny, mode="r+b")
    for j, items in assign.items():
        row = llc_src.read_row(j)
        for i, value in items:
            row[i] = value
        llc_dst.write_row(j, row)
    llc_src.close()
    llc_dst.close()

    if reclass:
        land_src = Raster(args.land_raster, args.nx, args.ny)
        land_dst = Raster(args.land_output, args.nx, args.ny, mode="r+b")
        for j, columns in reclass.items():
            row = land_src.read_row(j)
            for i in columns:
                row[i] = args.land_lake
            land_dst.write_row(j, row)
        land_src.close()
        land_dst.close()

    print("[fill_llc_raster] done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
