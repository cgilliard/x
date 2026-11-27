#!/bin/sh
# scripts/build.sh -- build everything in bin/ from fam0.seed.

cd "$(dirname "$0")/.." || exit 1

: "${CPU:=rv32,zicsr=true,m=false,a=false,f=false,d=false,c=false,\
zawrs=false,zfa=false,zfh=false,zfhmin=false,zcb=false,\
zcd=false,zcf=false,zcmp=false,zcmt=false,zifencei=false}"
: "${MEM:=128M}"


serial_qemu() {  # serial_qemu INFILE OUTFILE [extra qemu args...]
        sin=$1; sout=$2; shift 2
        qemu-system-riscv32 \
                -machine virt -m "$MEM" -cpu "$CPU" \
                -display none -bios none \
                -chardev file,id=ser0,path="$sout",input-path="$sin" \
                -serial chardev:ser0 \
                "$@"
}

fresh() {
        [ -z "$BUILD_ALL" ] && [ -e "$1" ] || return 1
        f_out=$1; shift
        for f_in; do [ "$f_in" -nt "$f_out" ] && return 1; done
        return 0
}

compile() {
        out=$1; asm=$2; shift 2
        disk_args=""; disk=""
        if [ "$1" = "--disk" ]; then
                disk=$2
                disk_args="-drive file=$disk,format=raw,if=none,id=hd0 \
-device virtio-blk-device,drive=hd0"
                shift 2
        fi
        if [ $# -gt 0 ] && fresh "$out" "$asm" "$@"; then return 0; fi
        [ $# -gt 0 ] && echo "Building $* → $out" >&2
        stream="$out.in.$$"
        # the input ends with 0x04; the linker wants four of them after its
        # last object, and the others stop at the first
        ([ $# -gt 0 ] && cat "$@"; printf '\004\004\004\004') > "$stream"
        serial_qemu "$stream" "$out" \
                -device loader,file="$asm",addr=0x80000000 \
                $disk_args
        rc=$?
        rm -f "$stream"

        # a program that fails exits with 1, its message where its output goes
        if [ $rc -ne 0 ]; then
                echo "build.sh: $out: error: $(head -c 200 "$out" | tr -d '\0')" >&2
                rm -f "$out"   # (not taken for a fresh build next time)
                exit 1
        fi
}

# pack OUT IN -- pack the binary IN into OUT, which unpacks itself
# (src/fampack.fam).  The packer reads the size of IN, as four bytes lowest
# first, and then IN.
pack() {
        out=$1; in=$2
        if fresh "$out" "$in" bin/fampack; then return 0; fi
        echo "Packing $in → $out" >&2
        n=$(wc -c < "$in")
        stream="$out.in.$$"
        { printf "$(printf '\\%03o' $((n & 255)) $(((n >> 8) & 255)) \
                        $(((n >> 16) & 255)) $(((n >> 24) & 255)))"
          cat "$in"
        } > "$stream"
        serial_qemu "$stream" "$out" -device loader,file=bin/fampack,addr=0x80000000
        rc=$?
        rm -f "$stream"
        if [ $rc -ne 0 ]; then
                echo "build.sh: $out: error: $(head -c 200 "$out" | tr -d '\0')" >&2
                rm -f "$out"
                exit 1
        fi
}

# the root of trust
compile bin/fam0 fam0.seed src/fam0.fam0
cmp ./bin/fam0 ./fam0.seed # verify they're identical

# the core of fam
compile bin/fam.uncompressed bin/fam0 src/fam.fam0
compile bin/famc bin/fam0 src/famc.fam0
compile bin/famld bin/fam0 src/famld.fam0

# the runtime, which tools/famc adds to every link: startup and library,
# and the last step (call main, or report the tests)
compile bin/rt.o      bin/famc lib/rt.fam
compile bin/rtmain.o  bin/famc lib/rtmain.fam
compile bin/rttest.o  bin/famc lib/rttest.fam

# the packer, a fam program: compile, link, and the core makes the binary
compile bin/fampack.o    bin/famc  src/fampack.fam
compile bin/fampack.core bin/famld bin/rt.o bin/fampack.o bin/rtmain.o
compile bin/fampack      bin/fam.uncompressed bin/fampack.core

# the core, packed
pack bin/fam bin/fam.uncompressed
