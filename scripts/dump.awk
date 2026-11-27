# scripts/dump.awk -- print an object in its text form (docs/OBJECT.md).
# Input: the object's bytes in decimal, as `od -An -v -tu1` prints them.
# Used by `fam.sh dump`.

{ for (i = 1; i <= NF; i++) b[n++] = $i }

function word(at) {
        return b[at] + 256 * (b[at + 1] + 256 * (b[at + 2] + 256 * b[at + 3]))
}

function name(sym,    at, len, s, i) {
        at = names + word(sym + 4); len = word(sym + 8); s = ""
        for (i = 0; i < len; i++) s = s sprintf("%c", b[at + i])
        return s
}

function bad(why) {
        print "dump: " why > "/dev/stderr"; failed = 1; exit 1
}

END {
        if (failed) exit 1
        if (n < 28 || b[0] != 70 || b[1] != 65 || b[2] != 77 || b[3] != 79)
                bad("not a fam object")
        if (word(4) != 1) bad("unknown object version")
        nsym = word(12); ncall = word(16)
        syms = 28; calls = syms + 20 * nsym; code = calls + 8 * ncall
        names = code + word(20)
        if (word(8) != n || names + word(24) != n) bad("bad object")
        for (c = 0; c < ncall; c++)
                callee[word(calls + 8 * c)] = syms + 20 * word(calls + 8 * c + 4)
        for (s = 0; s < nsym; s++) {
                sym = syms + 20 * s
                kind = word(sym)
                if (kind == 0) continue
                print (kind == 1 ? "fn " name(sym) : kind == 3 ? "local " name(sym) : "init")
                at = word(sym + 12); end = at + word(sym + 16)
                while (at < end) {
                        if (at in callee) {
                                print "@" name(callee[at]); at += 28
                        } else {
                                printf "%02X%02X%02X%02X\n", b[code + at],
                                        b[code + at + 1], b[code + at + 2],
                                        b[code + at + 3]
                                at += 4
                        }
                }
                print "end"
        }
}
