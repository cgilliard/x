#!/bin/sh
# scripts/build.sh -- build everything in bin/ from fam0.seed.
#
# It needs qemu-system-riscv32, this shell, cat and cmp.  (printf, which it
# uses once, is part of the shell: dash, bash and BusyBox all have it.)

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

# compile OUT PROGRAM IN... -- run PROGRAM under QEMU with the INs, one
# after another, as what it reads from the serial port; what it writes is
# OUT.  Skipped if OUT is fresh.  bin/build.in is where the input is put
# together; it is left there.
compile() {
        out=$1; program=$2; shift 2
        if fresh "$out" "$program" "$@"; then return 0; fi
        echo "Building $* → $out" >&2
        # the input ends with 0x04; the linker wants four of them after its
        # last object, and the others stop at the first.  bin/end.bin is
        # those four bytes, made here the first time.
        [ -s bin/end.bin ] || printf '\004\004\004\004' > bin/end.bin
        cat "$@" bin/end.bin > bin/build.in
        qemu-system-riscv32 \
                -machine virt -m "$MEM" -cpu "$CPU" \
                -display none -bios none \
                -chardev file,id=ser0,path="$out",input-path=bin/build.in \
                -serial chardev:ser0 \
                -device loader,file="$program",addr=0x80000000

        # A program that fails exits with 1, its message where its output
        # goes.  Show it, and empty OUT so it is not taken for fresh.
        if [ $? -ne 0 ]; then
                echo "build.sh: $out: error:" >&2
                cat "$out" >&2
                : > "$out"
                exit 1
        fi
}

compile bin/fam0 fam0.seed src/fam0.fam0
cmp ./bin/fam0 ./fam0.seed # verify they're identical

# the core of fam
compile bin/fam bin/fam0 src/fam.fam0
compile bin/famc bin/fam0 src/famc.fam0
compile bin/famld bin/fam0 src/famld.fam0

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
