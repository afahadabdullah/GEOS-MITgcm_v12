#!/usr/bin/env python3
"""
Run-phase companion to patch_calving_mit.py.

PROBLEM
-------
GEOS_OceanGridComp's run method does

    call MAPL_GetPointer(GIM(OCN), CALVING, 'CALVING', _RC)      ! line ~592

GIM(OCN) is the CHILD's import state.  MIT_GEOS5PlugMod declares no CALVING
import, so the lookup returns not-found (status 41) and aborts.

Skipping the lookup alone is not enough: CALVING is a WRITE target, not a read.

    CALVING = CALVINGi          ! DO_DATA_ATM4OCN branch
    where(CALVING < 0.0) ...
    CALVING = 0.0               ! else branch
    if (associated(CALVINGe)) CALVINGe = CALVING

With DO_DATA_ATM4OCN false, `CALVING = 0.0` would write through an
unassociated pointer -- a segfault instead of a clean abort.

FIX
---
Give MIT a real zero-filled array sized off DISCHARGE (same child tile layout,
fetched on the preceding line), so every assignment below stays valid and the
CALVING export still publishes a well-defined zero field.  Physically right:
MITgcm has no glacier-discharge coupling, so calving flux is zero.

Deallocate before the DO_DATASEA block closes, since the run method is called
every ocean step and would otherwise leak.  The deallocate is guarded by the
same OCEAN_NAME test -- for MOM/MOM6/DATASEA the pointer aliases state memory
and must never be freed.

USAGE
-----
    python3 patch_calving_mit_run.py --check  /path/to/GEOS_OceanGridComp.F90
    python3 patch_calving_mit_run.py          /path/to/GEOS_OceanGridComp.F90
    python3 patch_calving_mit_run.py --revert /path/to/GEOS_OceanGridComp.F90

Writes a .bakrun alongside the original.  Idempotent.
"""

import argparse
import os
import shutil
import sys

MARKER = "MIT has no CALVING import (run phase)"

# Anchor 1: the failing GetPointer.  'GIM(OCN), CALVING' is unique -- the other
# CALVING GetPointer (line ~576) reads from IMPORT, not GIM(OCN).
ANCHOR_GET = "GIM(OCN), CALVING"

# Anchor 2: last statement before `end if !DO_DATASEA`, after the last CALVING use.
ANCHOR_END = "if (associated(PEN_OCNe)) PEN_OCNe = PEN_OCN"


def find_unique(lines, needle, what):
    hits = [i for i, l in enumerate(lines) if needle in l]
    if len(hits) != 1:
        sys.exit(
            f"ERROR: expected exactly 1 line containing {needle!r} ({what}), "
            f"found {len(hits)}"
            + (":\n  " + "\n  ".join(f"{h+1}: {lines[h].rstrip()}" for h in hits)
               if hits else "")
        )
    return hits[0]


def indent_of(line):
    return " " * (len(line) - len(line.lstrip()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--revert", action="store_true")
    args = ap.parse_args()

    path, bak = args.file, args.file + ".bakrun"

    if args.revert:
        if not os.path.exists(bak):
            sys.exit(f"ERROR: no backup at {bak}")
        shutil.copy(bak, path)
        print(f"reverted {path} from {bak}")
        return

    if not os.path.isfile(path):
        sys.exit(f"ERROR: no such file: {path}")

    with open(path) as f:
        lines = f.readlines()

    if any(MARKER in l for l in lines):
        print("Already patched -- nothing to do.")
        return

    i_get = find_unique(lines, ANCHOR_GET, "run-phase GetPointer")
    i_end = find_unique(lines, ANCHOR_END, "end of DO_DATASEA block")

    if i_end <= i_get:
        sys.exit("ERROR: end-of-block anchor precedes the GetPointer; aborting.")

    # Sanity: DISCHARGE must be fetched before CALVING so its shape is known.
    disc = [i for i, l in enumerate(lines) if "GIM(OCN), DISCHARGE" in l]
    if not disc or disc[0] >= i_get:
        sys.exit("ERROR: could not confirm DISCHARGE is fetched before CALVING.")

    gi = indent_of(lines[i_get])
    ei = indent_of(lines[i_end])

    block = [
        f"{gi}! {MARKER}: MIT_GEOS5PlugMod declares none, so GIM(OCN) has no\n",
        f"{gi}! CALVING to point at. Supply a zero field sized off DISCHARGE\n",
        f"{gi}! (same child tile layout) so the assignments below and the\n",
        f"{gi}! CALVING export remain valid. MITgcm has no glacier discharge.\n",
        f"{gi}if (trim(OCEAN_NAME) == \"MIT\") then\n",
        f"{gi}   allocate(CALVING(size(DISCHARGE,1), size(DISCHARGE,2)))\n",
        f"{gi}   CALVING = 0.0\n",
        f"{gi}else\n",
        f"{gi}   {lines[i_get].lstrip()}",
        f"{gi}endif\n",
    ]

    dealloc = [
        f"{ei}! release the zero CALVING allocated above; for MOM/MOM6/DATASEA\n",
        f"{ei}! CALVING aliases state memory and must NOT be freed.\n",
        f"{ei}if (trim(OCEAN_NAME) == \"MIT\") deallocate(CALVING)\n",
    ]

    out = (lines[:i_get] + block + lines[i_get + 1:i_end + 1]
           + dealloc + lines[i_end + 1:])

    print(f"file       : {path}")
    print(f"GetPointer : line {i_get + 1}")
    print(f"deallocate : after line {i_end + 1}")
    print()
    print("--- replacing ---")
    print(lines[i_get], end="")
    print("--- with ---")
    print("".join(block), end="")
    print("--- inserting after PEN_OCNe line ---")
    print("".join(dealloc), end="")
    print()

    if args.check:
        print("--check given; nothing written.")
        return

    if not os.path.exists(bak):
        shutil.copy(path, bak)
        print(f"backup written: {bak}")
    with open(path, "w") as f:
        f.writelines(out)
    print(f"PATCHED: {path}")


if __name__ == "__main__":
    main()
