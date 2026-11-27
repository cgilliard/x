#!/bin/sh

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
        ([ $# -gt 0 ] && cat "$@"; printf '\004') > "$stream"
        serial_qemu "$stream" "$out" \
                -device loader,file="$asm",addr=0x80000000 \
                $disk_args
        rm -f "$stream"

        if [ $# -gt 0 ] && [ "$out" != bin/fam0 ] &&
		[ "$(head -c 4 "$out" | od -An -tx1 | tr -d ' \n')" != "13000000" ]; then
                echo "build.sh: $out: compile error: $(head -c 80 "$out" | tr -d '\0')" >&2
                rm -f "$out"   # (not taken for a fresh build next time)
                exit 1
        fi
}

compile bin/fam0 fam0.seed src/fam0.fam0
cmp ./bin/fam0 ./fam0.seed
compile bin/fam.uncompressed bin/fam0 src/fam.fam0
compile bin/famc bin/fam0 src/famc.fam0
compile bin/famas bin/fam0 src/famas.fam0
compile bin/famld bin/fam0 src/famld.fam0
# the runtime: startup, library and the last step (fam.sh ld adds them to
# every link)
for o in rt0 rtmain rttest; do
        fresh bin/$o.o bin/famas lib/$o.s ||
                sh "$(dirname "$0")/fam.sh" as lib/$o.s bin/$o.o || exit 1
done
fresh bin/rt.o bin/famc lib/rt.fam ||
        sh "$(dirname "$0")/fam.sh" cc lib/rt.fam bin/rt.o || exit 1
