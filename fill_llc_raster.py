#!/usr/bin/env python3
"""Repair undefined (zero) pixels in a GEOS LLC raster produced by mkMITAquaRaster.x.

Why this exists
---------------
mkMITAquaRaster.x assigns every 43200x21600 raster pixel the compact index of
the LLC tile that covers it, then runs a fill pass over pixels no tile claimed.
That fill does not always converge: a few tens of thousands of pixels are left
at zero where the GEOS land mask calls a pixel water but the LLC ocean domain
has no wet cell there -- enclosed estuaries, fjords, gulfs behind blanked
tiles, and ice-shelf fronts.

CombineRasters.x cannot represent "water with no ocean cell", so it emits a
single degenerate sentinel surface tile (zero area, zero indices, uninitialised
latitude) and attributes every such pixel to it.  The second CombineRasters
pass then intersects that one tile with the atmosphere grid and produces ocean
exchange records carrying compact index (0,0) in the final tile.data.

Repairing the raster before combination removes the sentinel at its source.
Each zero pixel is assigned the compact index of its nearest non-zero
neighbour, so CombineRasters sees a fully defined raster, derives every tile
area and fraction itself, and the resulting tile.data needs no post-hoc
renormalisation.

Usage
-----
    fill_llc_raster.py --input raw.rst --output filled.rst [--report stats.txt]

The input file is never modified; it is copied and the copy is repaired.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from collections import Counter, OrderedDict

try:
    import numpy as np
except ImportError:  # pragma: no cover
    sys.exit("ERROR: numpy is required (module load python, or pip install numpy)")


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
        self.hits = 0
        self.misses = 0

    def get(self, j: int) -> "np.ndarray":
        row = self._rows.get(j)
        if row is not None:
            self._rows.move_to_end(j)
            self.hits += 1
            return row
        self.misses += 1
        row = self.raster.read_row(j)
        self._rows[j] = row
        if len(self._rows) > self.capacity:
            self._rows.popitem(last=False)
        return row

    def invalidate(self, j: int) -> None:
        self._rows.pop(j, None)


def invalid_mask(row: "np.ndarray", valid_min: int, valid_max: int) -> "np.ndarray":
    """Boolean mask of raster values that are not usable compact indices.

    GEOS does not use a single undefined marker consistently: unassigned
    pixels may be 0, or RASTERUNDEF (-999), or any value outside the tile
    table.  Testing a range catches all of them, where testing == 0 does not.
    """
    bad = row < valid_min
    if valid_max > 0:
        bad |= row > valid_max
    return bad


def scan_undefined(raster: Raster, valid_min: int, valid_max: int, progress_every: int = 2000):
    """Return [(j, array_of_i)] for rows holding unusable values, plus stats."""
    gaps = []
    total = 0
    lo = None
    hi = None
    histogram: "Counter[int]" = Counter()

    for j in range(raster.ny):
        row = raster.read_row(j)
        row_lo = int(row.min())
        row_hi = int(row.max())
        lo = row_lo if lo is None else min(lo, row_lo)
        hi = row_hi if hi is None else max(hi, row_hi)

        idx = np.flatnonzero(invalid_mask(row, valid_min, valid_max))
        if idx.size:
            gaps.append((j, idx))
            total += int(idx.size)
            for value in row[idx][:256].tolist():
                histogram[int(value)] += 1

        if progress_every and j and j % progress_every == 0:
            print(f"  scanned row {j}/{raster.ny} ({total} undefined so far)", flush=True)

    return gaps, total, lo, hi, histogram


def nearest_valid(
    cache: RowCache,
    nx: int,
    ny: int,
    j0: int,
    i0: int,
    max_radius: int,
    valid_min: int,
    valid_max: int,
) -> int:
    """Compact index of the nearest usable pixel, searching outward from (j0, i0).

    Longitude wraps; latitude does not.  Returns 0 if nothing is found inside
    max_radius, which the caller treats as a hard error.
    """
    half = nx // 2
    for radius in range(1, max_radius + 1):
        best_value = 0
        best_d2 = None

        jlo = max(0, j0 - radius)
        jhi = min(ny - 1, j0 + radius)
        offsets = (np.arange(i0 - radius, i0 + radius + 1) % nx).astype(np.int64)

        for j in range(jlo, jhi + 1):
            values = cache.get(j)[offsets]
            good = np.flatnonzero(~invalid_mask(values, valid_min, valid_max))
            if good.size == 0:
                continue
            di = (offsets[good] - i0 + half) % nx - half
            dj = j - j0
            d2 = di * di + dj * dj
            k = int(np.argmin(d2))
            if best_d2 is None or int(d2[k]) < best_d2:
                best_d2 = int(d2[k])
                best_value = int(values[good[k]])

        if best_value:
            return best_value

    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Fill undefined pixels in a GEOS LLC raster.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--input", required=True, help="raw .rst from mkMITAquaRaster.x")
    ap.add_argument("--output", help="repaired .rst to write (omit with --inspect)")
    ap.add_argument("--nx", type=int, default=NX_DEFAULT, help="raster width")
    ap.add_argument("--ny", type=int, default=NY_DEFAULT, help="raster height")
    ap.add_argument("--max-radius", type=int, default=128, help="search radius in pixels")
    ap.add_argument("--report", default=None, help="write a per-tile gain report here")
    ap.add_argument("--valid-min", type=int, default=1, help="lowest usable compact index")
    ap.add_argument(
        "--valid-max",
        type=int,
        default=0,
        help="highest usable compact index (0 = no upper bound)",
    )
    ap.add_argument(
        "--inspect",
        action="store_true",
        help="report the value range and undefined markers, then exit without writing",
    )
    ap.add_argument(
        "--max-gain",
        type=int,
        default=0,
        help="fail if any single LLC cell gains more than this many pixels (0 = no limit)",
    )
    args = ap.parse_args()

    if not os.path.isfile(args.input):
        sys.exit(f"ERROR: input raster not found: {args.input}")
    if not args.inspect and not args.output:
        sys.exit("ERROR: --output is required unless --inspect is given")

    print(f"[fill_llc_raster] input:  {args.input}")
    probe = Raster(args.input, args.nx, args.ny)
    print(f"[fill_llc_raster] layout: {probe.describe()}")
    probe.close()

    bound = args.valid_max if args.valid_max > 0 else "unbounded"
    print(f"[fill_llc_raster] usable index range: {args.valid_min}..{bound}")
    print("[fill_llc_raster] scanning for undefined pixels")
    src = Raster(args.input, args.nx, args.ny)
    gaps, total, lo, hi, histogram = scan_undefined(src, args.valid_min, args.valid_max)
    src.close()

    print(f"[fill_llc_raster] value range in raster: {lo} .. {hi}")
    print(f"[fill_llc_raster] undefined pixels: {total} in {len(gaps)} rows")
    if histogram:
        common = ", ".join(f"{value} (x{count})" for value, count in histogram.most_common(10))
        print(f"[fill_llc_raster] undefined markers seen: {common}")

    if args.inspect:
        if gaps:
            j, columns = gaps[0]
            print(f"[fill_llc_raster] first undefined pixel: row {j}, column {int(columns[0])}")
        return 0

    if total == 0:
        print("[fill_llc_raster] raster is already complete; copying unchanged")
        shutil.copyfile(args.input, args.output)
        return 0

    print(f"[fill_llc_raster] copying to {args.output}")
    shutil.copyfile(args.input, args.output)

    dst = Raster(args.output, args.nx, args.ny, mode="r+b")
    cache = RowCache(dst)

    gained: "Counter[int]" = Counter()
    unresolved = []
    filled = 0

    for j, columns in gaps:
        row = dst.read_row(j)
        for i in columns.tolist():
            value = nearest_valid(
                cache, args.nx, args.ny, j, int(i),
                args.max_radius, args.valid_min, args.valid_max,
            )
            if value == 0:
                unresolved.append((j, int(i)))
                continue
            row[i] = value
            gained[value] += 1
            filled += 1
        dst.write_row(j, row)
        cache.invalidate(j)

    dst.close()

    print(f"[fill_llc_raster] filled {filled} pixels across {len(gained)} LLC cells")
    if gained:
        worst = gained.most_common(1)[0]
        print(f"[fill_llc_raster] largest single-cell gain: {worst[1]} pixels (compact index {worst[0]})")

    if unresolved:
        print(
            f"ERROR: {len(unresolved)} pixels found no non-zero neighbour within "
            f"{args.max_radius} pixels; first few: {unresolved[:5]}",
            file=sys.stderr,
        )
        return 1

    if args.max_gain and gained and gained.most_common(1)[0][1] > args.max_gain:
        print(
            f"ERROR: a single LLC cell gained more than --max-gain={args.max_gain} pixels",
            file=sys.stderr,
        )
        return 1

    if args.report:
        with open(args.report, "w") as fh:
            fh.write(f"undefined pixels: {total}\n")
            fh.write(f"filled pixels:    {filled}\n")
            fh.write(f"receiving cells:  {len(gained)}\n\n")
            fh.write("compact_index  pixels_gained\n")
            for index, count in gained.most_common():
                fh.write(f"{index:13d}  {count:d}\n")
        print(f"[fill_llc_raster] report: {args.report}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
