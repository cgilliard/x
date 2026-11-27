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
                -serial chardev:ser0 \
                -device loader,file="$r_program",addr=0x80000000
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

# the core of fam: the back end, the compiler and the linker, each built by
# the seed from its hex
compile bin/fam   fam0.seed src/fam.fam0
compile bin/famc  fam0.seed src/famc.fam0
compile bin/famld fam0.seed src/famld.fam0

# the runtime, which tools/famc adds to every link: startup and library,
# and the last step (call main, or report the tests)
compile bin/rt.o      bin/famc lib/rt.fam
compile bin/rtmain.o  bin/famc lib/rtmain.fam
compile bin/rttest.o  bin/famc lib/rttest.fam

# the packer (tools/famc --pack), a fam program: compile, link, and the
# core makes the binary
compile bin/fampack.o    bin/famc  src/fampack.fam
compile bin/fampack.core bin/famld bin/rt.o bin/fampack.o bin/rtmain.o
compile bin/fampack      bin/fam bin/fampack.core

# a check: the seed, given its own source, builds itself
compile bin/fam0      fam0.seed src/fam0.fam0
compile bin/same.o    bin/famc  src/same.fam
compile bin/same.core bin/famld bin/rt.o bin/same.o bin/rtmain.o
compile bin/same      bin/fam   bin/same.core
verify  bin/fam0      fam0.seed
