#!/usr/bin/env python3
# s2fam0 -- convert a RISC-V assembly file into the fam0 hex format that
# fam0.seed compiles, keeping the comments.
#
# Two programs are written in assembly: src/fam.S (the core) and src/famc.S
# (the compiler's front end).  Each has a .fam0 beside it,
# made by this script and committed.  scripts/build.sh reads only the .fam0
# files, so building needs neither this script nor an assembler; this is for
# whoever changes a .S file, or wants to see that a .fam0 is what its .S
# says.  (src/fam0.fam0, the seed's own source, is written by hand in hex.)
#
# The fam0 format is one instruction a line, as its 4 bytes lowest first:
#     13 0B A0 00 # addi s6,zero,10
# Lines starting with # and blank lines are ignored by fam0.
#
# Usage:
#   s2fam0.py src/famc.S -o src/famc.fam0       convert one file
#   s2fam0.py src/famc.S                        the same, to standard output
#   s2fam0.py --all                             convert every src/*.S
#   s2fam0.py --check                           convert every src/*.S and say
#                                               whether each committed .fam0
#                                               is identical (exit 1 if not)
# It needs python3 and the GNU assembler and objdump for RISC-V
# (riscv64-unknown-elf-as, riscv64-unknown-elf-objdump).

import os, re, subprocess, sys

AS    = "riscv64-unknown-elf-as"
ODUMP = "riscv64-unknown-elf-objdump"
NOP   = "13 00 00 00"   # q32 magic, prepended exactly like scripts/build.sh

USAGE = "usage: s2fam0.py INPUT.S [-o OUTPUT.fam0] | --all | --check"

def every(check):
    """--all / --check: each src/*.S to (or against) the .fam0 beside it."""
    import glob, io, contextlib
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    bad = 0
    for inp in sorted(glob.glob(os.path.join(root, "src", "*.S"))):
        out = inp[:-2] + ".fam0"
        name = os.path.relpath(out, root)
        if not check:
            convert(inp, out); print("wrote", name); continue
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf): convert(inp, None)
        same = os.path.isfile(out) and open(out).read() == buf.getvalue()
        print(name, "is what its .S gives" if same else "DIFFERS from what its .S gives")
        bad += not same
    return 1 if bad else 0

def main():
    inp, out = None, None
    args = sys.argv[1:]
    if args in (["--all"], ["--check"]): return every(args == ["--check"])
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-o", "--output"): out = args[i+1]; i += 2
        elif a in ("-h", "--help"):
            print(USAGE); return 0
        elif a.startswith("-"): sys.exit(f"s2fam0: unknown option: {a}")
        else: inp = a; i += 1
    if inp is None: sys.exit(USAGE)
    if not os.path.isfile(inp): sys.exit(f"s2fam0: input not found: {inp}")
    return convert(inp, out)

def convert(inp, out):

    obj = inp + ".s2fam0.o"
    try:
        subprocess.run([AS, "-g", "-march=rv32i_zicsr", "-mabi=ilp32", "-o", obj, inp], check=True)
        dis = subprocess.run([ODUMP, "-dlz", obj], check=True, capture_output=True, text=True).stdout
    finally:
        if os.path.exists(obj): os.remove(obj)

    src = open(inp).read().splitlines()

    # parse objdump -dl: instructions in address order, each tagged with its
    # source line.  `file:NNN` lines set the current source line; instruction
    # lines look like:  "  9c:\t00050493          \tmv\ts1,a0"
    line_re  = re.compile(r"^\S*:(\d+)$")
    insn_re  = re.compile(r"^\s*[0-9a-f]+:\t([0-9a-f]{8})\s+(.*)$")
    insns = []          # (src_line, value_hex, disasm)
    cur = 0
    for ln in dis.splitlines():
        m = line_re.match(ln)
        if m: cur = int(m.group(1)); continue
        m = insn_re.match(ln)
        if m:
            val = m.group(1)
            asm = re.sub(r"\s+", " ", m.group(2)).strip()
            insns.append((cur, val, asm))

    def comment(line):
        s = line.rstrip()
        if s.strip() == "": return ""
        # already a comment? keep as-is; otherwise comment-ize (code lines start
        # with hex-ish chars that fam0 would try to parse).
        return s if s.lstrip().startswith("#") else "# " + s

    fh = open(out, "w") if out else sys.stdout
    w = lambda s="": print(s, file=fh)
    nopline = f"{NOP}\t# nop  (q32 magic; prepended like scripts/build.sh)"
    first_sl = insns[0][0] if insns else 1
    # leading comments (the license/header block), with the nop emitted just
    # after the license — i.e. right after its first blank line.
    nop_done = False
    for k in range(0, first_sl - 1):
        if k < len(src): w(comment(src[k]))
        if not nop_done and k < len(src) and src[k].strip() == "":
            w(nopline); w(""); nop_done = True
    if not nop_done:
        w(nopline); w("")
    last = first_sl - 1
    for (sl, val, asm) in insns:
        if sl > last:                       # emit intervening source lines as comments
            for k in range(last, sl):
                if k < len(src): w(comment(src[k]))
            last = sl
        le = f"{val[6:8]} {val[4:6]} {val[2:4]} {val[0:2]}".upper()
        w(f"{le}\t# {asm}")
    if fh is not sys.stdout: fh.close()
    return 0

if __name__ == "__main__":
    sys.exit(main())
