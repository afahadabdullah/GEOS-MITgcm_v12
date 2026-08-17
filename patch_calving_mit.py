#!/usr/bin/env python3
"""
Patch GEOS_OceanGridComp.F90 so that CALVING is not terminated on the MIT
ocean child.

WHY
---
GEOS_OceanGridComp calls MAPL_TerminateImport on a list of child imports that
includes CALVING.  MOM5/MOM6 plugs declare a CALVING import; MIT_GEOS5PlugMod
does not (its import table is TAUX TAUY LWFLX SHFLX QFLUX RAIN SNOW DISCHARGE
SFLX PS PEN* DRNIR DFNIR DEL_TEMP SWHEAT WGHT -- no CALVING).  Terminating an
import the child never declared registers a connection with nothing on the
other end, which fails during GCMSetServices with:

    GENERIC: ERROR: SRC_NAME: <CALVING>  DST_NAME: <CALVING> is not satisfied

The patch splits the call on OCEAN_NAME and drops 'CALVING' from the MIT list.
It copies the original statement verbatim -- indentation untouched, so no risk
of pushing continuation lines past the 132-column free-form limit.

USAGE
-----
    python3 patch_calving_mit.py --check  /path/to/GEOS_OceanGridComp.F90
    python3 patch_calving_mit.py          /path/to/GEOS_OceanGridComp.F90
    python3 patch_calving_mit.py --revert /path/to/GEOS_OceanGridComp.F90

Writes a .bak alongside the original.  Idempotent: refuses to double-apply.
"""

import argparse
import os
import re
import shutil
import sys

GUARD = 'if (trim(OCEAN_NAME) == "MIT") then'
MARKER = "MIT has no CALVING import"


def find_block(lines):
    """Locate the MAPL_TerminateImport statement that mentions CALVING and CHILD=OCN.

    Returns (start, end) inclusive line indices, or None.
    """
    for i, line in enumerate(lines):
        if "MAPL_TerminateImport" not in line:
            continue
        # Walk the continuation chain: a statement continues while the line
        # ends with '&' (ignoring any trailing comment after the '&').
        j = i
        block = [lines[j]]
        while j < len(lines) - 1:
            stripped = lines[j].rstrip("\n")
            code = stripped.split("!")[0].rstrip()
            if not code.endswith("&"):
                break
            j += 1
            block.append(lines[j])
        text = "".join(block)
        if "CALVING" in text and "CHILD" in text and "OCN" in text:
            return i, j
    return None


def strip_calving(block):
    """Remove 'CALVING' and its trailing comma from a copy of the statement."""
    out = []
    removed = 0
    for line in block:
        new = re.sub(r"'CALVING\s*'\s*,\s*", "", line)
        if new != line:
            removed += 1
        out.append(new)
    return out, removed


def already_patched(lines):
    return any(MARKER in l for l in lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--check", action="store_true",
                    help="report what would change; write nothing")
    ap.add_argument("--revert", action="store_true",
                    help="restore the .bak written by a previous run")
    args = ap.parse_args()

    path = args.file
    bak = path + ".bak"

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

    if already_patched(lines):
        print("Already patched -- nothing to do.")
        print(f"  (marker '{MARKER}' found)")
        return

    found = find_block(lines)
    if not found:
        sys.exit(
            "ERROR: could not locate a MAPL_TerminateImport statement\n"
            "       containing CALVING and CHILD=OCN.\n"
            "       The source may differ from what this patch expects;\n"
            "       apply the change by hand."
        )

    start, end = found
    block = lines[start:end + 1]
    mit_block, removed = strip_calving(block)

    if removed == 0:
        sys.exit("ERROR: found the block but no 'CALVING', token to remove.")

    # Indentation for the if/else/endif, taken from the original statement.
    indent = " " * (len(block[0]) - len(block[0].lstrip()))

    new = []
    new.append(f"{indent}! {MARKER}: MIT_GEOS5PlugMod never declares one.\n")
    new.append(f"{indent}! Terminating a non-existent child import registers an\n")
    new.append(f"{indent}! unsatisfiable connection and aborts GCMSetServices.\n")
    new.append(f"{indent}{GUARD}\n")
    new.extend(mit_block)
    new.append(f"{indent}else\n")
    new.extend(block)
    new.append(f"{indent}endif\n")

    out = lines[:start] + new + lines[end + 1:]

    print(f"file          : {path}")
    print(f"statement     : lines {start + 1}-{end + 1}")
    print(f"CALVING tokens: {removed} removed in the MIT copy")
    print()
    print("--- original ---")
    print("".join(block), end="")
    print("--- MIT copy ---")
    print("".join(mit_block), end="")
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
    print()
    print("Next:")
    print("  source $GEOSBIN/g5_modules")
    print("  cd <build dir> && make -j 12 install")
    print("  cp <install>/bin/GEOSgcm.x <expdir>/GEOSgcm.x   # exp has its OWN copy")


if __name__ == "__main__":
    main()
