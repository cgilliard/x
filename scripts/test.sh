#!/bin/sh
# scripts/test.sh [--accept] [TEST...] -- test the compiler: build, compile
# and run every test in tests/, and compare what comes out with what is
# expected.  Exit 0 if every one is as expected.
#
# A test is a source file, tests/NAME.fam, or a directory of them,
# tests/NAME/.  What it does is, as a user would do it:
#
#       tools/famc tests/NAME.fam -o BINARY && tools/q32 BINARY
#
# and everything that prints, with a last line "exit N" for the exit code,
# must be what is in tests/NAME.expected.  So an expected file is, for a
# program that runs:                and for one that must not compile:
#       hello, world                    tests/NAME.fam:3: unknown variable y
#       exit 0                          exit 1
#
# Three more rules:
#   - tests/NAME.input, if there is one, is what the program reads.
#   - NAME.test.fam, or a directory NAME.test/, is run with `famc --test`.
#   - An expected file that has <HEX> in it is one whose hex values may
#     change (the addresses in the runtime's messages, say): for that test
#     every 0x... in what comes out is turned into <HEX> before comparing.
#     Without <HEX> in it, hex values are compared as they are.
#
# The comparing is done by bin/same, a fam program.
#
# --accept writes what comes out as the expected files, for new tests and
# for changes that are meant: look at `git diff` before committing them.
# (For a new test whose hex values may change, put <HEX> in its expected
# file by hand, once.)

cd "$(dirname "$0")/.." || exit 1
sh scripts/build.sh || exit 1

accept=; [ "$1" != --accept ] || { accept=1; shift; }
[ $# -gt 0 ] || set -- tests/*.fam tests/*/

out=bin/test.out                # what came out of the test being run
pass=0; fail=0

for t; do
        t=${t%/}
        name=${t%.fam}
        if [ -d "$t" ]; then src=$(echo "$t"/*.fam); else src=$t; fi
        input=/dev/null; [ ! -f "$name.input" ] || input=$name.input

        case $name in
        *.test) tools/famc --test $src ;;
        *)      tools/famc $src -o bin/test.bin && timeout 60 tools/q32 bin/test.bin ;;
        esac < "$input" > $out 2>&1
        echo "exit $?" >> $out

        # <HEX> in the expected file: any hex value will do
        case $(cat "$name.expected" 2> /dev/null) in *"<HEX>"*)
                sed 's/0x[0-9A-Fa-f][0-9A-Fa-f]*/<HEX>/g' $out > $out.hex
                cat $out.hex > $out ;;
        esac

        if [ -n "$accept" ]; then
                cat $out > "$name.expected"
                echo "wrote $name.expected"
        elif [ -f "$name.expected" ] &&
             cat $out "$name.expected" bin/end.bin | tools/q32 bin/same; then
                pass=$((pass + 1)); echo "ok    $t"
        else
                fail=$((fail + 1)); echo "FAIL  $t"
                echo "---- expected ($name.expected):"; cat "$name.expected"
                echo "---- got:"; cat $out
                echo "----"
        fi
done
rm -f $out $out.hex bin/test.bin

[ -z "$accept" ] || exit 0
echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
