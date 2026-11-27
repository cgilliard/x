#!/bin/sh
# scripts/test.sh [FILE...] -- build, then run the tests (default: all of
# tests/).  Exit 0 if every one passes.
#
# A test is a source file (tests/*.fam).  It is compiled, linked with the
# runtime and run.  Comments in its first five lines say what must happen:
#     exit: N          the program runs and exits with code N
#     output: TEXT     and writes exactly TEXT (\n for a newline)
#     input: TEXT      what the program reads (\n for a newline)
#     error: TEXT      a step fails with exactly the message TEXT
# and may name more files (relative to tests/) to build and link with it:
#     with: FILE...
# A source named *.test.fam is built for its `test` blocks instead
# (famc --test), and the files with it likewise.
#
# With no arguments, a few malformed objects are also given to the linker.

cd "$(dirname "$0")/.." || exit 1
sh scripts/build.sh || exit 1

tmp="bin/test.$$"
pass=0; fail=0

# object FILE OBJECT -- compile FILE; prints "error: ..." if that fails.
object() {
        o_msg=$(tools/famc -c $tflag "$1" -o "$2" 2>&1) || echo "error: $o_msg"
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
        l_msg=$(tools/famc $tflag "$@" -o "$tmp" 2>&1) ||
                { echo "error: $l_msg"; return; }
        printf '%b' "$win" | timeout 60 tools/q32 "$tmp" > "$tmp.txt" 2>&1
        echo "exit: $?"
}

raw=
[ $# -gt 0 ] || { set -- tests/*.fam; raw=1; }
for t; do
        head3=$(head -n 5 "$t" | sed 's/^\(\/\/\|#\) *//')
        want=$(printf "%s\n" "$head3" | sed -n 's/^\(exit\|error\): */\1: /p' | head -n 1)
        with=$(printf "%s\n" "$head3" | sed -n 's/^with: *//p')
        wout=$(printf "%s\n" "$head3" | sed -n 's/^output: //p')
        win=$(printf "%s\n" "$head3" | sed -n 's/^input: //p')
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
        tflag=; win=
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
        # the packer: a packed program runs as the program does, and the
        # core, packed, compiles as the core does
        tools/famc -c tests/print_int.fam -o "$tmp.1.o" &&
                tools/famc "$tmp.1.o" -o "$tmp" &&
                tools/famc --pack "$tmp" -o "$tmp.packed" &&
                tools/q32 "$tmp" < /dev/null > "$tmp.txt" &&
                tools/q32 "$tmp.packed" < /dev/null | cmp -s - "$tmp.txt" &&
                [ "$(wc -c < "$tmp.packed")" -lt "$(wc -c < "$tmp")" ]
        check "(a packed program runs the same, and is smaller)" "exit: 0" "exit: $?"
        tools/famc --pack bin/fam -o "$tmp.core" &&
                CORE=$tmp.core tools/famc "$tmp.1.o" -o "$tmp.2" &&
                cmp -s "$tmp" "$tmp.2"
        check "(the core, packed, links the same binary)" "exit: 0" "exit: $?"
        rm -f "$tmp" "$tmp.2" "$tmp.1.o" "$tmp.packed" "$tmp.txt" "$tmp.core"
fi

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
