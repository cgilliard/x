#!/bin/sh
# scripts/test_compilers.sh -- check that the compiler (src/famc/,
# bin/famc) writes what the stage compiler, the one in Forth that builds
# it (src/famc.forth, bin/famc0), writes.  Exit 0 if it does.
#
# Every .fam file in tests/, src/ and lib/ is given to both, once as
# tools/famc gives it and once as `tools/famc --test` does.  The two must
# write the same bytes and exit with the same code: the same object, or
# the same message for a file that must not compile.
#
# Then bin/famc compiles its own source and its runtime, and the compiler
# linked from that must be bin/famc itself, byte for byte.
#
# Last, the checks on jumps (src/famc/emit.fam).  No macro the compiler
# has trips them, so a compiler is linked here with four that can:
#       mark;   make a label and place it       back;   jump to it
#       fwd;    make a label and jump to it     land;   place it
# and given functions that use them wrongly.
#
# The comparing is done by bin/same, a fam program.

cd "$(dirname "$0")/.." || exit 1
sh scripts/build.sh || exit 1

: "${MEM:=128M}"
: "${CPU:=rv32,zicsr=true,m=false,a=false,f=false,d=false,c=false,\
zawrs=false,zfa=false,zfh=false,zfhmin=false,zcb=false,\
zcd=false,zcf=false,zcmp=false,zcmt=false,zifencei=false}"

# run PROGRAM OUT -- run PROGRAM under QEMU: it reads bin/test.in, and what
# it writes is OUT.  Its exit status is the program's.
run() {
        qemu-system-riscv32 \
                -machine virt -m "$MEM" -cpu "$CPU" \
                -display none -bios none \
                -chardev file,id=ser0,path="$2",input-path=bin/test.in \
                -serial chardev:ser0 \
                -device loader,file="$1",addr=0x80000000
}

# same A B -- are the files A and B identical?
same() { cat "$1" "$2" bin/end.bin | tools/q32 bin/same; }

pass=0; fail=0

for f in tests/*.fam tests/*/*.fam src/*.fam src/*/*.fam lib/*.fam; do
        for mark in '\001' '\002'; do
                { printf "$mark%s\n" "$f"; cat "$f"; printf '\004'; } > bin/test.in
                run bin/famc0 bin/test.a; echo "exit $?" >> bin/test.a
                run bin/famc  bin/test.b; echo "exit $?" >> bin/test.b
                if same bin/test.a bin/test.b; then
                        pass=$((pass + 1))
                else
                        fail=$((fail + 1))
                        case $mark in *1) echo "FAIL  $f (with its tests)" ;;
                                      *)  echo "FAIL  $f" ;; esac
                fi
        done
done
echo "ok    $pass files compile the same"

# bin/famc compiles itself (bin/rt.o and bin/rtmain.o are its work already)
objs=
for m in lex obj emit parse std main; do
        { cat src/famc/$m.fam; printf '\004'; } > bin/test.in
        run bin/famc bin/test.$m.o || fail=$((fail + 1))
        objs="$objs bin/test.$m.o"
done
cat bin/rt.o $objs bin/rtmain.o bin/end.bin > bin/test.in
run bin/famld bin/test.famc || fail=$((fail + 1))
if same bin/test.famc bin/famc; then
        pass=$((pass + 1)); echo "ok    bin/famc builds itself"
else
        fail=$((fail + 1)); echo "FAIL  bin/famc builds itself"
fi

# the checks on jumps
cat > bin/test.in <<'END'
module wrong;
import lex; import emit; import parse;
let l = 0;
fn mark() { lex.expect(59); l = emit.label(); emit.place(l); }
fn back() { lex.expect(59); emit.jump(l); }
fn fwd() { lex.expect(59); l = emit.label(); emit.jump(l); }
fn land() { lex.expect(59); emit.place(l); }
init {
    parse.define("mark", &mark); parse.define("back", &back);
    parse.define("fwd", &fwd); parse.define("land", &land);
}
END
printf '\004' >> bin/test.in
run bin/famc bin/test.wrong.o || fail=$((fail + 1))
cat bin/rt.o bin/famc.lex.o bin/famc.obj.o bin/famc.emit.o \
    bin/famc.parse.o bin/famc.std.o bin/test.wrong.o bin/famc.main.o \
    bin/rtmain.o bin/end.bin > bin/test.in
run bin/famld bin/test.famcw || fail=$((fail + 1))

# expect MESSAGE SOURCE -- that compiler, given SOURCE, must fail with
# exactly MESSAGE; or, if MESSAGE is empty, compile it.
expect() {
        printf '%s\n\004' "$2" > bin/test.in
        run bin/test.famcw bin/test.a
        got="exit $?: $(cat bin/test.a | tr -d '\000')"
        case $got in "exit 0: FAMO"*) got="exit 0: " ;; esac
        want="exit 1: famc: line 1: $1"; [ -n "$1" ] || want="exit 0: "
        if [ "$got" = "$want" ]; then
                pass=$((pass + 1)); echo "ok    $2"
        else
                fail=$((fail + 1)); echo "FAIL  $2"; echo "        got: $got"
        fi
}
expect "" \
        'fn f() { mark; back; }'
expect "" \
        'fn f() { mark; if 1 { let a = 1; back; } }'
expect "" \
        'fn f() { fwd; land; }'
expect "a jump into a block, past a let, or to another function" \
        'fn f() { if 1 { mark; } back; }'
expect "a jump into a block, past a let, or to another function" \
        'fn f() { mark; } fn g() { back; }'
expect "a label is placed outside where it was made" \
        'fn f() { fwd; let x = 1; land; }'
expect "a label is placed outside where it was made" \
        'fn f() { fwd; if 1 { land; } }'
expect "a label is placed twice" \
        'fn f() { mark; land; }'
expect "a label is never placed" \
        'fn f() { fwd; }'

rm -f bin/test.in bin/test.a bin/test.b bin/test.famc bin/test.famcw \
      bin/test.wrong.o $objs

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
