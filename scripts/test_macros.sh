#!/bin/sh
# scripts/test_macros.sh -- check the checks on jumps (src/famc/emit.fam).
# Exit 0 if every one answers as expected.
#
# What controls flow in fam is built by macros from labels and jumps, and
# the compiler checks every jump a macro makes.  No macro the compiler has
# trips those checks, so a compiler is linked here with four that can:
#       mark;   make a label and place it       back;   jump to it
#       fwd;    make a label and jump to it     land;   place it
# and given functions that use them wrongly.
#
# The macros, like the compiler, are in the stage compiler's language, and
# bin/famc0 compiles them.
#
# Then one check of `tools/famc --macros`, which does the same for a
# program that brings macros of its own.

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

pass=0; fail=0

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
run bin/famc0 bin/test.wrong.o || fail=$((fail + 1))
cat bin/famc0.rt.o bin/famc.lex.o bin/famc.obj.o bin/famc.types.o \
    bin/famc.emit.o bin/famc.parse.o bin/famc.std.o bin/test.wrong.o \
    bin/famc.main.o bin/famc0.rtmain.o bin/end.bin > bin/test.in
run bin/famld bin/test.famc || fail=$((fail + 1))

# expect MESSAGE SOURCE -- that compiler, given SOURCE, must fail with
# exactly MESSAGE; or, if MESSAGE is empty, compile it.
expect() {
        printf '%s\n\004' "$2" > bin/test.in
        run bin/test.famc bin/test.out
        got="exit $?: $(cat bin/test.out | tr -d '\000')"
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
        'fn f() { mark; if true { let a = 1; back; } }'
expect "" \
        'fn f() { fwd; land; }'
expect "a jump into a block, past a let, or to another function" \
        'fn f() { if true { mark; } back; }'
expect "a jump into a block, past a let, or to another function" \
        'fn f() { mark; } fn g() { back; }'
expect "a label is placed outside where it was made" \
        'fn f() { fwd; let x = 1; land; }'
expect "a label is placed outside where it was made" \
        'fn f() { fwd; if true { land; } }'
expect "a label is placed twice" \
        'fn f() { mark; land; }'
expect "a label is never placed" \
        'fn f() { fwd; }'

# A program's own macros: tools/famc --macros.  `unless` is `if` turned
# round.
cat > bin/test.macros.fam <<'END'
module unless;
import lex; import emit; import parse;
fn unless_macro() {
    let past = emit.label();
    parse.condition();
    emit.jump_if_nonzero(past);
    parse.block();
    emit.place(past);
}
init { parse.define("unless", &unless_macro); }
END
cat > bin/test.unless.fam <<'END'
fn main() -> i32 {
    unless 1 > 2 { return 7; }
    return 0;
}
END
tools/famc --macros bin/test.macros.fam bin/test.unless.fam -o bin/test.bin &&
        tools/q32 bin/test.bin
if [ $? -eq 7 ]; then
        pass=$((pass + 1)); echo "ok    famc --macros: unless"
else
        fail=$((fail + 1)); echo "FAIL  famc --macros: unless"
fi
got=$(tools/famc bin/test.unless.fam -o bin/test.bin 2>&1)
if [ "$got" = "bin/test.unless.fam:2: unknown variable unless" ]; then
        pass=$((pass + 1)); echo "ok    without --macros: no unless"
else
        fail=$((fail + 1)); echo "FAIL  without --macros: no unless"; echo "        got: $got"
fi

rm -f bin/test.in bin/test.out bin/test.famc bin/test.wrong.o bin/test.bin \
      bin/test.macros.fam bin/test.unless.fam

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
