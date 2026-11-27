#!/bin/sh
# scripts/test.sh [FILE...] -- build, then run the tests (default: all of
# tests/).  Exit 0 if every one passes.
#
# A test is a source file (tests/*.fam) or the text form of an object
# (tests/*.s).  It is compiled or assembled, linked with the runtime and
# run.  Comments in its first four lines say what must happen:
#     exit: N          the program runs and exits with code N
#     output: TEXT     and writes exactly TEXT (\n for a newline)
#     error: TEXT      a step fails with exactly the message TEXT
# and may name more files (relative to tests/) to build and link with it:
#     with: FILE...
# A source named *.test.fam is built for its `test` blocks instead
# (fam.sh cc --test, ld --test), and the files with it likewise.
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
        *.fam) o_msg=$(sh scripts/fam.sh cc $tflag "$1" "$2" 2>&1) ;;
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

# link_run OBJECT... -- link and run; prints the outcome.  What the program
# wrote is left in $tmp.txt.
link_run() {
        l_msg=$(sh scripts/fam.sh ld $tflag "$tmp" "$@" 2>&1) ||
                { echo "error: $l_msg"; return; }
        timeout 60 sh scripts/fam.sh run "$tmp" > "$tmp.txt" 2>&1
        echo "exit: $?"
}

raw=
[ $# -gt 0 ] || { set -- tests/*.fam tests/*.s; raw=1; }
for t; do
        head3=$(head -n 4 "$t" | sed 's/^\(\/\/\|#\) *//')
        want=$(printf "%s\n" "$head3" | sed -n 's/^\(exit\|error\): */\1: /p' | head -n 1)
        with=$(printf "%s\n" "$head3" | sed -n 's/^with: *//p')
        wout=$(printf "%s\n" "$head3" | sed -n 's/^output: //p')
        got=; objs=; i=0
        case $t in *.test.fam) tflag=--test ;; *) tflag= ;; esac
        for f in "$t" $(for w in $with; do echo "tests/$w"; done); do
                i=$((i + 1))
                got=$(object "$f" "$tmp.$i.o")
                [ -z "$got" ] || break
                objs="$objs $tmp.$i.o"
        done
        [ -n "$got" ] || got=$(link_run $objs)
        if [ -n "$wout" ] && [ "$got" = "$want" ]; then
                printf '%b' "$wout" | cmp -s - "$tmp.txt" ||
                        got="$got, output: $(cat "$tmp.txt")"
        fi
        check "$t" "$want" "$got"
        rm -f "$tmp" "$tmp".*.o "$tmp.txt"
done

# raw NAME WANT BYTES -- give the linker BYTES (a printf format) as an object.
raw() {
        tflag=
        printf "$3" > "$tmp.1.o"
        check "$1" "$2" "$(link_run "$tmp.1.o")"
        rm -f "$tmp" "$tmp".*.o "$tmp.txt"
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
