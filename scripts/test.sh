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
# A source named *.test.fam is built for its `test` blocks instead, and the
# files with it likewise.
#
# With no arguments, a few malformed objects are also given to the linker,
# and the packer is tried.
#
# It uses the programs in bin/ under QEMU, as scripts/build.sh does, and
# nothing from tools/.

cd "$(dirname "$0")/.." || exit 1
sh scripts/build.sh || exit 1

: "${MEM:=128M}"
: "${CPU:=rv32,zicsr=true,m=false,a=false,f=false,d=false,c=false,\
zawrs=false,zfa=false,zfh=false,zfhmin=false,zcb=false,\
zcd=false,zcf=false,zcmp=false,zcmt=false,zifencei=false}"

tmp="bin/test.$$"
pass=0; fail=0
core=bin/fam

# qemu PROGRAM IN OUT -- run a program under QEMU, for a minute at most: it
# reads the file IN from the serial port, and what it writes there goes to
# OUT.  Its exit status is the program's.
qemu() {
        timeout 60 qemu-system-riscv32 \
                -machine virt -m "$MEM" -cpu "$CPU" \
                -display none -bios none \
                -chardev file,id=ser0,path="$3",input-path="$2" \
                -serial chardev:ser0 \
                -device loader,file="$1",addr=0x80000000 2> /dev/null
}

# The steps tools/famc takes for a user, taken here with the programs in
# bin/.  Each returns 1 if its program fails, leaving the program's message
# in $tmp.msg.

# compile SOURCE OBJECT -- bin/famc.  It is told the file's name in a first
# line that starts with the byte 0x02, or 0x01 to ask for the tests ($tflag).
compile() {
        c_mark='\002'; [ -z "$tflag" ] || c_mark='\001'
        { printf "$c_mark%s\n" "$1"; cat "$1"; printf '\004'; } > "$tmp.in"
        qemu bin/famc "$tmp.in" "$2" || { cat "$2" > "$tmp.msg"; return 1; }
}

# link BINARY OBJECT... -- bin/famld, then the core.  The runtime goes
# first, and the call of main (or the tests' report) last.
link() {
        l_out=$1; shift
        l_last=bin/rtmain.o; [ -z "$tflag" ] || l_last=bin/rttest.o
        { cat bin/rt.o "$@" $l_last; printf '\004\004\004\004'; } > "$tmp.in"
        qemu bin/famld "$tmp.in" "$tmp.core" || { cat "$tmp.core" > "$tmp.msg"; return 1; }
        printf '\004' >> "$tmp.core"
        qemu $core "$tmp.core" "$l_out" || { cat "$l_out" > "$tmp.msg"; return 1; }
}

# pack BINARY PACKED -- bin/fampack, which reads the size as four bytes,
# lowest first, and then the binary.
pack() {
        p_n=$(wc -c < "$1")
        { printf "$(printf '\\%03o' $((p_n & 255)) $(((p_n >> 8) & 255)) \
                        $(((p_n >> 16) & 255)) $(((p_n >> 24) & 255)))"
          cat "$1"
        } > "$tmp.in"
        qemu bin/fampack "$tmp.in" "$2"
}

# run BINARY -- run it with $win to read; what it writes is left in $tmp.txt.
run() {
        printf '%b\004' "$win" > "$tmp.in"
        qemu "$1" "$tmp.in" "$tmp.txt"
}

# object FILE OBJECT -- compile FILE; prints "error: ..." if that fails.
object() {
        compile "$1" "$2" || echo "error: $(cat "$tmp.msg")"
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
        link "$tmp" "$@" || { echo "error: $(cat "$tmp.msg")"; return; }
        run "$tmp"
        echo "exit: $?"
}

# tidy -- remove what a test leaves
tidy() {
        rm -f "$tmp" "$tmp".*.o "$tmp.in" "$tmp.msg" "$tmp.core" "$tmp.txt" \
                "$tmp.2" "$tmp.packed" "$tmp.fam" "$tmp.want"
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
        tidy
done

# raw NAME WANT BYTES -- give the linker BYTES (a printf format) as an object.
raw() {
        tflag=; win=
        printf "$3" > "$tmp.1.o"
        check "$1" "$2" "$(link_run "$tmp.1.o")"
        tidy
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
        tflag=; win=
        compile tests/print_int.fam "$tmp.1.o" && link "$tmp" "$tmp.1.o" &&
                pack "$tmp" "$tmp.packed" &&
                run "$tmp" && cat "$tmp.txt" > "$tmp.want" &&
                run "$tmp.packed" && cmp -s "$tmp.want" "$tmp.txt" &&
                [ "$(wc -c < "$tmp.packed")" -lt "$(wc -c < "$tmp")" ]
        check "(a packed program runs the same, and is smaller)" "exit: 0" "exit: $?"
        pack bin/fam "$tmp.fam" && core=$tmp.fam && link "$tmp.2" "$tmp.1.o" &&
                cmp -s "$tmp" "$tmp.2"
        check "(the core, packed, links the same binary)" "exit: 0" "exit: $?"
        core=bin/fam
        tidy
fi

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
