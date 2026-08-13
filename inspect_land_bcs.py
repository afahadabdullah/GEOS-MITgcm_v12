#!/usr/bin/env python3
"""
inspect_land_bcs.py -- work out the tile dimension of GEOS land boundary-condition
files (vegdyn.data, lai.data, green.data, ndvi.data, nirdf.dat, visdf.dat) and
check it against a tile.data exchange-grid file.

These files are Fortran sequential unformatted: every record is
    [int32 nbytes][payload][int32 nbytes]
so the tile count can be recovered exactly from the record lengths without
knowing the writing program.  Endianness is auto-detected by requiring the
leading and trailing markers of every record to agree and the walk to land
precisely on EOF.

Usage
-----
  # dimension of each BC file
  python3 inspect_land_bcs.py --bcs-dir /path/to/bcs/land/bundle

  # explicit files
  python3 inspect_land_bcs.py vegdyn.data lai.data visdf.dat

  # count land/lake/landice/ocean tiles in a tile file
  python3 inspect_land_bcs.py --tile-data /path/to/tile.data

  # both, with a verdict on whether the BCs can be reused unchanged
  python3 inspect_land_bcs.py --bcs-dir /path/to/bcs --tile-data ./tile.data
"""

import argparse
import os
import struct
import sys
from collections import Counter

DEFAULT_NAMES = [
    "vegdyn.data",
    "lai.data",
    "green.data",
    "ndvi.data",
    "nirdf.dat",
    "visdf.dat",
]

# ---------------------------------------------------------------- Fortran walk


def walk_fortran(path, marker_size=4):
    """Return (endian, [(offset, nbytes), ...]) or (None, None) if not sequential."""
    size = os.path.getsize(path)
    fmt = {4: "i", 8: "q"}[marker_size]
    with open(path, "rb") as fh:
        for endian in ("<", ">"):
            recs = []
            pos = 0
            ok = True
            while pos < size:
                fh.seek(pos)
                head = fh.read(marker_size)
                if len(head) < marker_size:
                    ok = False
                    break
                n = struct.unpack(endian + fmt, head)[0]
                if n < 0 or pos + 2 * marker_size + n > size:
                    ok = False
                    break
                fh.seek(pos + marker_size + n)
                tail = fh.read(marker_size)
                if len(tail) < marker_size or struct.unpack(endian + fmt, tail)[0] != n:
                    ok = False
                    break
                recs.append((pos + marker_size, n))
                pos += 2 * marker_size + n
                if len(recs) > 5_000_000:
                    ok = False
                    break
            if ok and pos == size:
                return endian, recs
    return None, None


def describe_bc_file(path):
    """Infer the tile dimension of one BC file."""
    size = os.path.getsize(path)
    endian, recs = walk_fortran(path)
    info = {
        "path": path,
        "size": size,
        "endian": endian,
        "records": recs,
        "ntiles": None,
        "nslices": None,
        "header_bytes": None,
        "note": "",
    }
    if recs is None:
        info["note"] = "not a Fortran sequential file (try direct-access / netCDF)"
        return info

    lengths = [n for _, n in recs]
    # Data records are the big ones; headers (date stamps) are small.
    big = [n for n in lengths if n >= 1024]
    small = [n for n in lengths if n < 1024]
    if not big:
        info["note"] = "no record large enough to be tile data"
        return info

    common = Counter(big).most_common()
    data_len = common[0][0]
    if data_len % 4:
        info["note"] = "dominant record length is not a multiple of 4"
        return info

    info["ntiles"] = data_len // 4          # real*4, the GEOS convention
    info["ntiles_r8"] = data_len // 8       # in case it is real*8
    info["nslices"] = common[0][1]
    info["header_bytes"] = Counter(small).most_common(1)[0][0] if small else 0
    if len(common) > 1:
        info["note"] = "mixed data-record lengths: " + ", ".join(
            f"{n}B x{c}" for n, c in common
        )
    return info


# ---------------------------------------------------------------- tile.data


def scan_tile_data(path):
    """Header + per-type record counts + distinct surface-tile indices."""
    out = {"path": path, "header": [], "counts": Counter()}
    land_col9 = set()      # Pfafstetter catchment id
    land_col12 = set()     # internal surface-tile index
    lake_col12 = set()
    ice_col12 = set()
    ocean_col12 = set()

    with open(path, "r") as fh:
        for _ in range(8):
            line = fh.readline()
            if not line:
                break
            out["header"].append(line.rstrip())

        for line in fh:
            f = line.split()
            if len(f) < 12:
                continue
            t = f[0]
            out["counts"][t] += 1
            if t == "100":
                land_col9.add(f[8])
                land_col12.add(f[11])
            elif t == "19":
                lake_col12.add(f[11])
            elif t == "20":
                ice_col12.add(f[11])
            elif t == "0":
                ocean_col12.add(f[11])

    out["land_records"] = out["counts"].get("100", 0)
    out["lake_records"] = out["counts"].get("19", 0)
    out["ice_records"] = out["counts"].get("20", 0)
    out["ocean_records"] = out["counts"].get("0", 0)
    out["catchments"] = len(land_col9)
    out["land_surface_tiles"] = len(land_col12)
    out["lake_surface_tiles"] = len(lake_col12)
    out["ice_surface_tiles"] = len(ice_col12)
    out["ocean_surface_tiles"] = len(ocean_col12)
    return out


# ---------------------------------------------------------------- reporting


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="BC files to inspect")
    ap.add_argument("--bcs-dir", help="directory to search for the standard land BC names")
    ap.add_argument("--tile-data", help="tile.data (or .til) to cross-check against")
    args = ap.parse_args()

    targets = list(args.files)
    if args.bcs_dir:
        for name in DEFAULT_NAMES:
            p = os.path.join(args.bcs_dir, name)
            if os.path.exists(p):
                targets.append(p)
            else:
                # bundles often carry a resolution suffix, e.g. lai_clim_...data
                stem = name.split(".")[0]
                for cand in sorted(os.listdir(args.bcs_dir)):
                    if cand.startswith(stem) and cand not in DEFAULT_NAMES:
                        targets.append(os.path.join(args.bcs_dir, cand))
                        break

    bc_ntiles = {}
    if targets:
        print("=" * 78)
        print("LAND BOUNDARY-CONDITION FILES")
        print("=" * 78)
        for p in targets:
            if not os.path.exists(p):
                print(f"{os.path.basename(p):<28} MISSING")
                continue
            i = describe_bc_file(p)
            name = os.path.basename(p)
            if i["ntiles"] is None:
                print(f"{name:<28} {i['size']:>14,} B   {i['note']}")
                continue
            end = "little" if i["endian"] == "<" else "BIG"
            print(f"{name:<28} {i['size']:>14,} B  {end}-endian  "
                  f"{len(i['records'])} records")
            print(f"{'':<28} data record = {i['ntiles']*4:,} B "
                  f"-> ntiles = {i['ntiles']:,} (real*4)"
                  f" | {i['ntiles_r8']:,} (real*8)")
            print(f"{'':<28} {i['nslices']} such record(s)"
                  + (f", {i['header_bytes']}-byte header records" if i["header_bytes"] else "")
                  + (f"  [{i['note']}]" if i["note"] else ""))
            bc_ntiles[name] = i["ntiles"]

        if bc_ntiles:
            vals = set(bc_ntiles.values())
            print()
            if len(vals) == 1:
                print(f"All BC files agree: NTILES = {vals.pop():,}")
            else:
                print("BC files DISAGREE on NTILES:")
                for k, v in bc_ntiles.items():
                    print(f"    {k:<26} {v:,}")

    if args.tile_data:
        print()
        print("=" * 78)
        print("TILE FILE")
        print("=" * 78)
        t = scan_tile_data(args.tile_data)
        for line in t["header"]:
            print("  | " + line)
        print()
        print(f"  land     records {t['land_records']:>10,}   "
              f"surface tiles {t['land_surface_tiles']:>10,}   "
              f"catchments {t['catchments']:,}")
        print(f"  lake     records {t['lake_records']:>10,}   "
              f"surface tiles {t['lake_surface_tiles']:>10,}")
        print(f"  land ice records {t['ice_records']:>10,}   "
              f"surface tiles {t['ice_surface_tiles']:>10,}")
        print(f"  ocean    records {t['ocean_records']:>10,}   "
              f"surface tiles {t['ocean_surface_tiles']:>10,}")
        total_surf = (t["land_surface_tiles"] + t["lake_surface_tiles"]
                      + t["ice_surface_tiles"] + t["ocean_surface_tiles"])
        print(f"  total surface tiles {total_surf:,}")

        if bc_ntiles:
            n = sorted(set(bc_ntiles.values()))[0]
            print()
            print("  match against BC NTILES = {:,}".format(n))
            candidates = {
                "land exchange records (type 100)": t["land_records"],
                "land surface tiles (col 12)": t["land_surface_tiles"],
                "Pfafstetter catchments (col 9)": t["catchments"],
                "land + lake + landice records": t["land_records"] + t["lake_records"] + t["ice_records"],
                "land + lake + landice surface tiles": t["land_surface_tiles"] + t["lake_surface_tiles"] + t["ice_surface_tiles"],
            }
            hit = False
            for label, v in candidates.items():
                flag = "  <== MATCH" if v == n else ""
                if v == n:
                    hit = True
                print(f"    {label:<40} {v:>12,}{flag}")
            if not hit:
                print("    no match -- the BC bundle was built for a different tiling")

    if not targets and not args.tile_data:
        ap.print_help()
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
