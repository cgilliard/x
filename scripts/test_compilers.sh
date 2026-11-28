#!/bin/sh
# scripts/test_compilers.sh -- check that the compiler written in fam
# (src/famc/, bin/famc2) writes what the one in Forth (src/famc.forth,
# bin/famc) writes.  Exit 0 if it does.
#
# Every .fam file in tests/, src/ and lib/ is given to both, once as
# tools/famc gives it and once as `tools/famc --test` does.  The two must
# write the same bytes and exit with the same code: the same object, or
# the same message for a file that must not compile.
#
# Then bin/famc2 compiles its own source, and the compiler linked from
# that must be bin/famc2 itself, byte for byte.
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
                run bin/famc  bin/test.a; echo "exit $?" >> bin/test.a
                run bin/famc2 bin/test.b; echo "exit $?" >> bin/test.b
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

# bin/famc2 compiles itself
objs=
for m in lex obj emit parse main; do
        { cat src/famc/$m.fam; printf '\004'; } > bin/test.in
        run bin/famc2 bin/test.$m.o || fail=$((fail + 1))
        objs="$objs bin/test.$m.o"
done
cat bin/rt.o $objs bin/rtmain.o bin/end.bin > bin/test.in
run bin/famld bin/test.famc2 || fail=$((fail + 1))
if same bin/test.famc2 bin/famc2; then
        pass=$((pass + 1)); echo "ok    bin/famc2 builds itself"
else
        fail=$((fail + 1)); echo "FAIL  bin/famc2 builds itself"
fi
rm -f bin/test.in bin/test.a bin/test.b bin/test.famc2 $objs

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
