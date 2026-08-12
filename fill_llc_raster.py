#!/usr/bin/env python3
"""Repair LLC/Pfafstetter coastline mismatches in a GEOS raster pair.

Why this exists
---------------
mkMITAquaRaster.x writes the LLC compact index of the ocean tile covering each
43200x21600 raster pixel, and writes RASTERUNDEF (-999) everywhere the LLC
ocean domain has no cell.  That is the normal, correct state for roughly 20% of
the raster -- the entire land surface.  CombineRasters.x resolves those pixels
from the Pfafstetter land raster, which is exactly what the second positional
argument is for.

The defect is narrower.  Where the GEOS land mask calls a pixel *water* but the
LLC raster is RASTERUNDEF there, CombineRasters has no ocean cell to reference
and no land catchment either.  It indexes the LLC table with -999, emits a
single degenerate sentinel surface tile (zero area, zero indices, uninitialised
latitude) at the land/ocean block boundary, and attributes every such pixel to
it.  Those become ocean exchange records carrying compact index (0,0) in the
final tile.data.

This tool fills ONLY that intersection: pixels that are RASTERUNDEF in the LLC
raster *and* ocean in the land raster.  Each is assigned the compact index of
its nearest valid LLC neighbour, so CombineRasters sees a consistent pair,
derives every area and fraction itself, and no post-hoc renormalisation of the
tile file is required.

CRITICAL: running without --land-raster would target all 183 million
RASTERUNDEF pixels and convert the continents to ocean.  The tool refuses to do
that unless --force is given, and refuses any fill covering more than
--max-fill-fraction of the raster.

Usage
-----
    fill_llc_raster.py --inspect \\
        --llc-raster  raw.rst \\
        --land-raster Pfafstetter.rst

    fill_llc_raster.py \\
        --llc-raster  raw.rst \\
        --land-raster Pfafstetter.rst \\
        --output      filled.rst \\
        --report      stats.txt

Neither input is modified; the LLC raster is copied and the copy repaired.
"""

from __future__ import annotations

import argparse
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
RASTERUNDEF = -999


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

    def invalidate(self, j: int) -> None:
        self._rows.pop(j, None)


def valid_llc(row: "np.ndarray", valid_min: int, valid_max: int) -> "np.ndarray":
    """Boolean mask of raster values usable as LLC compact indices."""
    good = row >= valid_min
    if valid_max > 0:
        good &= row <= valid_max
    return good


def scan(
    llc: Raster,
    land: "Raster | None",
    valid_min: int,
    valid_max: int,
    land_ocean: int,
    progress_every: int = 2000,
):
    """Locate pixels that are undefined in the LLC raster and ocean in the land raster."""
    targets = []
    n_target = 0
    n_llc_undef = 0
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
        n_llc_undef += n_undef_row

        if n_undef_row:
            # Exact tallies, not a sample: np.unique over the masked row costs
            # little and a truncated head-of-row sample is spatially biased
            # toward one edge of the map, which misleads about proportions.
            values, counts = np.unique(row[undefined], return_counts=True)
            for value, count in zip(values.tolist(), counts.tolist()):
                llc_markers[int(value)] += int(count)

        if land is not None:
            land_row = land.read_row(j)
            # Tally the land raster wherever the LLC raster is undefined, so
            # the inspect report shows which land values coincide with gaps.
            if n_undef_row:
                values, counts = np.unique(land_row[undefined], return_counts=True)
                for value, count in zip(values.tolist(), counts.tolist()):
                    land_values[int(value)] += int(count)
            hit = undefined & (land_row == land_ocean)
        else:
            hit = undefined

        idx = np.flatnonzero(hit)
        if idx.size:
            targets.append((j, idx))
            n_target += int(idx.size)

        if progress_every and j and j % progress_every == 0:
            print(
                f"  scanned row {j}/{llc.ny} "
                f"(llc undefined {n_llc_undef}, repair targets {n_target})",
                flush=True,
            )

    return targets, n_target, n_llc_undef, lo, hi, llc_markers, land_values


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
) -> int:
    """Compact index of the nearest usable LLC pixel, searching outward from (j0, i0).

    Scans a square window once per radius and doubles the radius on failure,
    rather than restarting a growing scan at every integer radius -- the latter
    costs O(R^3) element operations per pixel and is unusably slow at R=128.

    A square of half-width R contains every pixel within Euclidean distance R,
    but a candidate found in a corner may sit further than R, in which case a
    nearer one could lie outside the square.  So the result is accepted only
    once best_distance <= radius; otherwise the window grows again.

    Longitude wraps; latitude does not.  Returns 0 if nothing is found inside
    max_radius, which the caller treats as a hard error.
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
            return best_value
        if radius >= max_radius:
            # Accept a corner hit at the limit rather than failing outright.
            return best_value

        radius = min(radius * 2, max_radius)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Fill LLC/Pfafstetter coastline mismatches in a GEOS raster.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--llc-raster", required=True, help="raw .rst from mkMITAquaRaster.x")
    ap.add_argument("--land-raster", help="Pfafstetter.rst -- required unless --force")
    ap.add_argument("--output", help="repaired LLC .rst to write (omit with --inspect)")
    ap.add_argument("--nx", type=int, default=NX_DEFAULT, help="raster width")
    ap.add_argument("--ny", type=int, default=NY_DEFAULT, help="raster height")
    ap.add_argument("--valid-min", type=int, default=1, help="lowest usable compact index")
    ap.add_argument("--valid-max", type=int, default=0, help="highest usable compact index (0 = none)")
    ap.add_argument("--land-ocean", type=int, default=0, help="value marking ocean in the land raster")
    ap.add_argument("--max-radius", type=int, default=128, help="search radius in pixels")
    ap.add_argument("--report", default=None, help="write a per-cell gain report here")
    ap.add_argument("--inspect", action="store_true", help="report and exit without writing")
    ap.add_argument(
        "--max-fill-fraction",
        type=float,
        default=0.01,
        help="refuse to fill more than this fraction of the raster",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="permit filling without a land raster, and past --max-fill-fraction",
    )
    args = ap.parse_args()

    for path in (args.llc_raster, args.land_raster):
        if path and not os.path.isfile(path):
            sys.exit(f"ERROR: raster not found: {path}")
    if not args.inspect and not args.output:
        sys.exit("ERROR: --output is required unless --inspect is given")
    if not args.land_raster and not args.force:
        sys.exit(
            "ERROR: --land-raster is required.\n"
            "  Without it every RASTERUNDEF pixel is a target -- about 20% of the\n"
            "  raster, i.e. the whole land surface -- which would convert the\n"
            "  continents to ocean.  Pass --force only if you truly mean that."
        )

    llc = Raster(args.llc_raster, args.nx, args.ny)
    print(f"[fill_llc_raster] llc raster:  {args.llc_raster}")
    print(f"[fill_llc_raster]   layout:    {llc.describe()}")

    land = None
    if args.land_raster:
        land = Raster(args.land_raster, args.nx, args.ny)
        print(f"[fill_llc_raster] land raster: {args.land_raster}")
        print(f"[fill_llc_raster]   layout:    {land.describe()}")
        print(f"[fill_llc_raster]   ocean marker: {args.land_ocean}")

    bound = args.valid_max if args.valid_max > 0 else "unbounded"
    print(f"[fill_llc_raster] usable index range: {args.valid_min}..{bound}")
    print("[fill_llc_raster] scanning")

    targets, n_target, n_undef, lo, hi, llc_markers, land_values = scan(
        llc, land, args.valid_min, args.valid_max, args.land_ocean
    )
    llc.close()
    if land is not None:
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
        print(f"[fill_llc_raster]   land raster values where llc is undefined ({len(land_values)} distinct):")
        for value, count in land_values.most_common(12):
            share = 100.0 * count / max(n_undef, 1)
            print(f"[fill_llc_raster]     {value:>10d}  {count:>12d}  {share:6.2f}%")
    print(f"[fill_llc_raster] repair targets (llc undefined AND land ocean): {n_target}")

    if args.inspect:
        if targets:
            j, columns = targets[0]
            print(f"[fill_llc_raster] first target: row {j}, column {int(columns[0])}")
        return 0

    if n_target == 0:
        print("[fill_llc_raster] nothing to repair; copying unchanged")
        shutil.copyfile(args.llc_raster, args.output)
        return 0

    fraction = n_target / total_pixels
    if fraction > args.max_fill_fraction and not args.force:
        print(
            f"ERROR: {n_target} targets is {100.0 * fraction:.2f}% of the raster, "
            f"above --max-fill-fraction={100.0 * args.max_fill_fraction:.2f}%.\n"
            "  A genuine coastline mismatch is a few tens of thousands of pixels.\n"
            "  Check --land-ocean is the right marker before overriding with --force.",
            file=sys.stderr,
        )
        return 1

    print(f"[fill_llc_raster] copying to {args.output}")
    shutil.copyfile(args.llc_raster, args.output)

    # Read candidate values from the untouched original and write only to the
    # copy.  Caching the destination instead would let a just-filled pixel act
    # as a source for the next target, so values propagate in chains and the
    # result depends on iteration order rather than on actual proximity.
    src = Raster(args.llc_raster, args.nx, args.ny)
    dst = Raster(args.output, args.nx, args.ny, mode="r+b")
    cache = RowCache(src)

    gained: "Counter[int]" = Counter()
    unresolved = []
    filled = 0

    done = 0
    report_every = max(1, n_target // 20)
    started = time.time()

    for j, columns in targets:
        row = src.read_row(j)
        for i in columns.tolist():
            value = nearest_valid(
                cache, args.nx, args.ny, j, int(i),
                args.max_radius, args.valid_min, args.valid_max,
            )
            if value == 0:
                unresolved.append((j, int(i)))
            else:
                row[i] = value
                gained[value] += 1
                filled += 1
            done += 1
            if done % report_every == 0:
                elapsed = time.time() - started
                rate = done / elapsed if elapsed > 0 else 0.0
                print(
                    f"  filled {done}/{n_target} ({100.0 * done / n_target:.0f}%, "
                    f"{rate:.0f} px/s)",
                    flush=True,
                )
        dst.write_row(j, row)

    src.close()
    dst.close()

    print(f"[fill_llc_raster] filled {filled} pixels across {len(gained)} LLC cells")
    if gained:
        index, count = gained.most_common(1)[0]
        print(f"[fill_llc_raster] largest single-cell gain: {count} pixels (compact index {index})")

    if unresolved:
        print(
            f"ERROR: {len(unresolved)} pixels found no valid neighbour within "
            f"{args.max_radius} pixels; first few: {unresolved[:5]}",
            file=sys.stderr,
        )
        return 1

    if args.report:
        with open(args.report, "w") as fh:
            fh.write(f"llc undefined pixels: {n_undef}\n")
            fh.write(f"repair targets:       {n_target}\n")
            fh.write(f"filled pixels:        {filled}\n")
            fh.write(f"receiving cells:      {len(gained)}\n\n")
            fh.write("compact_index  pixels_gained\n")
            for index, count in gained.most_common():
                fh.write(f"{index:13d}  {count:d}\n")
        print(f"[fill_llc_raster] report: {args.report}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
