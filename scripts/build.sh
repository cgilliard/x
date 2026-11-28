#!/bin/sh
# scripts/build.sh -- build everything in bin/ from fam0.seed.
#
# It needs qemu-system-riscv32, this shell and cat.  (printf, which it uses
# once, is part of the shell: dash, bash and BusyBox all have it.)

# to the repository's root, from wherever this is run
case $0 in */*) cd "${0%/*}/.." ;; *) cd .. ;; esac || exit 1

: "${CPU:=rv32,zicsr=true,m=false,a=false,f=false,d=false,c=false,\
zawrs=false,zfa=false,zfh=false,zfhmin=false,zcb=false,\
zcd=false,zcf=false,zcmp=false,zcmt=false,zifencei=false}"
: "${MEM:=128M}"

# fresh OUT IN... -- is OUT there, not empty, and newer than every IN?
# (BUILD_ALL=1 says no: build everything again.)
fresh() {
        [ -z "$BUILD_ALL" ] && [ -s "$1" ] || return 1
        f_out=$1; shift
        for f_in; do [ "$f_in" -nt "$f_out" ] && return 1; done
        return 0
}

# run PROGRAM OUT IN... -- run PROGRAM under QEMU with the INs, one after
# another, as what it reads from the serial port; what it writes is OUT.
# $input, if set, is more for QEMU's command line, for this run only.
# Its exit status is the program's.  bin/build.in is where the input is put
# together; it is left there.
run() {
        r_program=$1; r_out=$2; shift 2
        # the input ends with 0x04; the linker wants four of them after its
        # last object, and the others stop at the first.  bin/end.bin is
        # those four bytes, made here the first time.
        [ -s bin/end.bin ] || printf '\004\004\004\004' > bin/end.bin
        cat "$@" bin/end.bin > bin/build.in
        qemu-system-riscv32 \
                -machine virt -m "$MEM" -cpu "$CPU" \
                -display none -bios none \
                -chardev file,id=ser0,path="$r_out",input-path=bin/build.in \
                -serial chardev:ser0 $input \
                -device loader,file="$r_program",addr=0x80000000
        r_status=$?; input=
        return $r_status
}

# compile OUT PROGRAM IN... -- make OUT by running PROGRAM over the INs.
# Skipped if OUT is fresh.
compile() {
        out=$1; program=$2; shift 2
        if fresh "$out" "$program" "$@"; then return 0; fi
        echo "Building $* → $out" >&2
        # A program that fails exits with 1, its message where its output
        # goes.  Show it, empty OUT so it is not taken for fresh, and stop.
        if ! run "$program" "$out" "$@"; then
                echo "build.sh: $out: error:" >&2
                cat "$out" >&2
                : > "$out"
                exit 1
        fi
}

# program OBJECT SOURCE -- compile a fam program with bin/famc, which is
# given the runtime (lib/rt.fam, the prelude) and then the source, each
# after a line that says what it is and its name (src/famc/lex.fam,
# "reading the source").  The object is the whole program: the linker
# makes the binary of it alone.
program() {
        out=$1; src=$2
        if fresh "$out" bin/famc lib/rt.fam "$src"; then return 0; fi
        echo "Building $src → $out" >&2
        printf '\005lib/rt.fam\n' > bin/build.rt
        printf '\002%s\n' "$src" > bin/build.name
        # the same in memory, after "FAMI", which is where bin/famc looks
        # first (src/famc/rt.fam, getc): the serial port is slow
        input=
        if [ "$MEM" = 128M ]; then
                printf 'FAMI' > bin/build.fami
                cat bin/build.fami bin/build.rt lib/rt.fam bin/build.name "$src" \
                        bin/end.bin > bin/build.mem
                input="-device loader,file=bin/build.mem,addr=0x87000000,force-raw=on"
        fi
        if ! run bin/famc "$out" bin/build.rt lib/rt.fam bin/build.name "$src"; then
                echo "build.sh: $out: error:" >&2
                cat "$out" >&2
                : > "$out"
                exit 1
        fi
}

# verify A B -- stop the build unless the files A and B are identical.
# bin/same, a fam program, compares them: it exits with 1 if they differ and
# writes nothing.  A note in bin/<A's name>.same says the check was made;
# then it is made again only when A, B or bin/same changes.
verify() {
        note=bin/${1##*/}.same
        if fresh "$note" bin/same "$1" "$2"; then return 0; fi
        echo "Verifying $1 = $2" >&2
        if ! run bin/same "$note" "$1" "$2"; then
                echo "ERROR: Build failed! Root of trust was tampered with?" >&2
                : > "$note"
                exit 1
        fi
        echo "$1 and $2 are identical" > "$note"
}

# the core, a minimal macro compiler, built by the seed from its hex
compile bin/fam   fam0.seed src/fam.fam0

# the stage compiler and the linker (which is the back end too).  Both
# are Forth, which the core compiles, their library first.  The stage
# compiler, bin/famc0, is here to build the compiler and nothing else.
compile bin/famc0 bin/fam lib/compiler.lib src/famc.forth
compile bin/famld.unpacked bin/fam lib/compiler.lib src/famld.forth

# the fam compiler (src/famc/), and the runtime it is linked with.  They
# are written in the stage compiler's language, which has no types, and it
# compiles them.
compile bin/famc0.rt.o      bin/famc0 src/famc/rt.fam
compile bin/famc0.rtmain.o  bin/famc0 src/famc/rtmain.fam
compile bin/famc.lex.o      bin/famc0 src/famc/lex.fam
compile bin/famc.obj.o      bin/famc0 src/famc/obj.fam
compile bin/famc.types.o    bin/famc0 src/famc/types.fam
compile bin/famc.emit.o     bin/famc0 src/famc/emit.fam
compile bin/famc.parse.o    bin/famc0 src/famc/parse.fam
compile bin/famc.std.o      bin/famc0 src/famc/std.fam
compile bin/famc.main.o     bin/famc0 src/famc/main.fam
compile bin/famc  bin/famld.unpacked bin/famc0.rt.o bin/famc.lex.o \
                  bin/famc.obj.o bin/famc.types.o bin/famc.emit.o \
                  bin/famc.parse.o bin/famc.std.o bin/famc.main.o \
                  bin/famc0.rtmain.o

# the packer, a fam program: compile, then link.  Then the linker, packed:
# a quarter of the size, and it unpacks itself each time it runs.  It links
# everything from here on.
program bin/fampack.o src/fampack.fam
compile bin/fampack   bin/famld.unpacked bin/fampack.o
compile bin/famld     bin/fampack bin/famld.unpacked

# a check: the seed, given its own source, builds itself
compile bin/fam0      fam0.seed src/fam0.fam0
program bin/same.o    src/same.fam
compile bin/same      bin/famld bin/same.o
verify  bin/fam0      fam0.seed
