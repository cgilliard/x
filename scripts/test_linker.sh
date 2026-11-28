#!/bin/sh
# scripts/test_linker.sh -- give the linker things that are not objects, or
# objects that are wrong, and check what it says.  Exit 0 if every answer is
# as expected.
#
# The compiler never writes such objects, so these cannot be tests in
# tests/: the bytes are written out here, as printf formats.  A tool that
# makes objects from a description would make this cleaner.

cd "$(dirname "$0")/.." || exit 1
sh scripts/build.sh || exit 1

: "${MEM:=128M}"
: "${CPU:=rv32,zicsr=true,m=false,a=false,f=false,d=false,c=false,\
zawrs=false,zfa=false,zfh=false,zfhmin=false,zcb=false,\
zcd=false,zcf=false,zcmp=false,zcmt=false,zifencei=false}"

pass=0; fail=0

# expect MESSAGE BYTES -- the linker, given BYTES (a printf format) as its
# only object, must fail with exactly MESSAGE.
expect() {
        { printf "$2"; printf '\004\004\004\004'; } > bin/test.in
        qemu-system-riscv32 \
                -machine virt -m "$MEM" -cpu "$CPU" \
                -display none -bios none \
                -chardev file,id=ser0,path=bin/test.out,input-path=bin/test.in \
                -serial chardev:ser0 \
                -device loader,file=bin/famld,addr=0x80000000
        got="exit $?: $(cat bin/test.out)"
        if [ "$got" = "exit 1: $1" ]; then
                pass=$((pass + 1)); echo "ok    $1"
        else
                fail=$((fail + 1)); echo "FAIL  $1"; echo "        got: $got"
        fi
}

# a text
expect "famld: the input is not a fam object" \
        'fn main() { return 1; }\n'

# a header that says version 2, the format before this one
expect "famld: unknown object version" \
        'FAMO\002\000\000\000\034\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000'

# a header that says one symbol, in an object too small to hold one
expect "famld: bad object" \
        'FAMO\003\000\000\000\034\000\000\000\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000'

# one external symbol "x" and a call site for it, but no code for the site
expect "famld: bad object" \
        'FAMO\003\000\000\000\074\000\000\000\001\000\000\000\001\000\000\000\000\000\000\000\004\000\000\000\000\000\000\000\000\000\000\000\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000x\000\000\000'

# a function "x" whose 16 bytes of code are a call site for itself, but the
# first word there is an instruction (a nop), not zero
expect "famld: bad object" \
        'FAMO\003\000\000\000\114\000\000\000\001\000\000\000\001\000\000\000\020\000\000\000\004\000\000\000\001\000\000\000\000\000\000\000\001\000\000\000\000\000\000\000\020\000\000\000\000\000\000\000\000\000\000\000\023\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000x\000\000\000'

rm -f bin/test.in bin/test.out
echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
