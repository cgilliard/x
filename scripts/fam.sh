#!/bin/sh
# scripts/fam.sh -- compile, link and run fam programs (docs/OBJECT.md).
#
#   fam.sh cc   SOURCE OBJECT       compile one source file to an object
#   fam.sh as   TEXT OBJECT         assemble the text form of an object
#   fam.sh ld   BINARY OBJECT...    link objects and the runtime to a binary
#   fam.sh run  BINARY              run a binary; its exit code is ours
#   fam.sh dump OBJECT              print an object in its text form
#
# On an error the message is printed, as FILE:LINE: WHAT where there is a
# line, and the output file is not left behind.  MEM and CPU as for scripts/build.sh, which must have run.

cd "$(dirname "$0")/.." || exit 1

: "${CPU:=rv32,zicsr=true,m=false,a=false,f=false,d=false,c=false,\
zawrs=false,zfa=false,zfh=false,zfhmin=false,zcb=false,\
zcd=false,zcf=false,zcmp=false,zcmt=false,zifencei=false}"
: "${MEM:=128M}"

qemu() {  # qemu IMAGE INFILE OUTFILE
        qemu-system-riscv32 \
                -machine virt -m "$MEM" -cpu "$CPU" \
                -display none -bios none \
                -chardev file,id=ser0,path="$3",input-path="$2" \
                -serial chardev:ser0 \
                -device loader,file="$1",addr=0x80000000
}

# stage IMAGE OUTFILE INFILE...   run IMAGE over the INFILEs; on failure
# print what it wrote (its message) and remove OUTFILE.  The input ends with
# four EOT bytes: one ends a text, all four end a list of objects.
stage() {
        s_image=$1; s_out=$2; shift 2
        { cat "$@"; printf '\004\004\004\004'; } > "$s_out.in"
        qemu "$s_image" "$s_out.in" "$s_out"
        s_rc=$?
        rm -f "$s_out.in"
        if [ $s_rc -ne 0 ]; then
                # "famc: line 3: what" becomes "FILE:3: what"
                sed "s|^fam[a-z]*: line \\([0-9]*\\): |$1:\\1: |" "$s_out" >&2
                rm -f "$s_out"
                return 1
        fi
}

cmd=$1; [ $# -gt 0 ] && shift
case $cmd in
cc)
        [ $# -eq 2 ] || { echo "usage: fam.sh cc SOURCE OBJECT" >&2; exit 2; }
        stage bin/famc "$2" "$1" || exit 1
        ;;
as)
        [ $# -eq 2 ] || { echo "usage: fam.sh as TEXT OBJECT" >&2; exit 2; }
        stage bin/famas "$2" "$1" || exit 1
        ;;
ld)
        [ $# -ge 2 ] || { echo "usage: fam.sh ld BINARY OBJECT..." >&2; exit 2; }
        out=$1; shift
        # startup first: its init record must run first; then the library
        stage bin/famld "$out.core" bin/rt0.o "$@" bin/rt.o || exit 1
        stage bin/fam.uncompressed "$out" "$out.core"
        rc=$?
        rm -f "$out.core"
        exit $rc
        ;;
run)
        [ $# -eq 1 ] || { echo "usage: fam.sh run BINARY" >&2; exit 2; }
        printf '\004' > "$1.in"
        qemu "$1" "$1.in" "$1.out"
        rc=$?
        cat "$1.out"
        rm -f "$1.in" "$1.out"
        exit $rc
        ;;
dump)
        [ $# -eq 1 ] || { echo "usage: fam.sh dump OBJECT" >&2; exit 2; }
        od -An -v -tu1 "$1" | awk -f scripts/dump.awk
        ;;
*)
        echo "usage: fam.sh cc|as|ld|run|dump ..." >&2; exit 2
        ;;
esac
