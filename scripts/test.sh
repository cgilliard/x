#!/bin/sh
# scripts/test.sh [FILE...] -- build, then run the tests (default: all of
# tests/).  Exit 0 if every one passes.
#
# A test is a source file (tests/*.fam) or the text form of an object
# (tests/*.s).  It is compiled or assembled, linked with bin/rt0.o and run.
# Comments in its first three lines say what must happen:
#     exit: N          the program runs and exits with code N
#     error: TEXT      a step fails with exactly the message TEXT
# and may name more files (relative to tests/) to build and link with it:
#     with: FILE...
#
# With no arguments, a few malformed objects are also given to the linker.

cd "$(dirname "$0")/.." || exit 1
sh scripts/build.sh || exit 1

tmp="bin/test.$$"
pass=0; fail=0

# object FILE OBJECT -- compile or assemble FILE; prints "error: ..." if
# that fails.
object() {
        case $1 in
        *.fam) o_msg=$(sh scripts/fam.sh cc "$1" "$2" 2>&1) ;;
        *)     o_msg=$(sh scripts/fam.sh as "$1" "$2" 2>&1) ;;
        esac || echo "error: $o_msg"
}

# check NAME WANT GOT
check() {
        if [ -n "$2" ] && [ "$3" = "$2" ]; then
                pass=$((pass + 1)); echo "ok    $1"
        else
                fail=$((fail + 1)); echo "FAIL  $1"
                echo "        want: ${2:-(no exit: or error: line)}"
                echo "        got:  $3"
        fi
}

# link_run OBJECT... -- link with bin/rt0.o and run; prints the outcome.
link_run() {
        l_msg=$(sh scripts/fam.sh ld "$tmp" bin/rt0.o "$@" 2>&1) ||
                { echo "error: $l_msg"; return; }
        timeout 60 sh scripts/fam.sh run "$tmp" > /dev/null 2>&1
        echo "exit: $?"
}

raw=
[ $# -gt 0 ] || { set -- tests/*.fam tests/*.s; raw=1; }
for t; do
        head3=$(head -n 3 "$t" | sed 's/^\(\/\/\|#\) *//')
        want=$(echo "$head3" | sed -n 's/^\(exit\|error\): */\1: /p' | head -n 1)
        with=$(echo "$head3" | sed -n 's/^with: *//p')
        got=; objs=; i=0
        for f in "$t" $(for w in $with; do echo "tests/$w"; done); do
                i=$((i + 1))
                got=$(object "$f" "$tmp.$i.o")
                [ -z "$got" ] || break
                objs="$objs $tmp.$i.o"
        done
        [ -n "$got" ] || got=$(link_run $objs)
        check "$t" "$want" "$got"
        rm -f "$tmp" "$tmp".*.o
done

# raw NAME WANT BYTES -- give the linker BYTES (a printf format) as an object.
raw() {
        printf "$3" > "$tmp.1.o"
        check "$1" "$2" "$(link_run "$tmp.1.o")"
        rm -f "$tmp" "$tmp".*.o
}
if [ -n "$raw" ]; then
        raw "(a text as an object)" "error: famld: the input is not a fam object" \
                'fn main() { return 1; }\n'
        raw "(an object of version 2)" "error: famld: unknown object version" \
                'FAMO\002\000\000\000\034\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000'
        raw "(an object whose parts do not add up)" "error: famld: bad object" \
                'FAMO\001\000\000\000\034\000\000\000\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000'
        raw "(a call site outside the code)" "error: famld: bad object" \
                'FAMO\001\000\000\000\074\000\000\000\001\000\000\000\001\000\000\000\000\000\000\000\004\000\000\000\000\000\000\000\000\000\000\000\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000x\000\000\000'
        sh scripts/fam.sh dump bin/rt0.o > "$tmp.s" &&
                sh scripts/fam.sh as "$tmp.s" "$tmp.1.o" &&
                cmp -s bin/rt0.o "$tmp.1.o"
        check "(dump, then as, gives the same object)" "exit: 0" "exit: $?"
        rm -f "$tmp.s" "$tmp.1.o"
fi

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
