#!/bin/sh
# scripts/fam.sh -- compile, link and run fam programs (docs/OBJECT.md).
#
#   fam.sh cc   [--test] SOURCE OBJECT      compile one source file to an object
#   fam.sh as   TEXT OBJECT                 assemble the text form of an object
#   fam.sh ld   [--test] BINARY OBJECT...   link objects and the runtime to a binary
#   fam.sh run  BINARY                      run a binary; its exit code is ours
#   fam.sh test SOURCE...                   compile, link and run the sources' tests
#   fam.sh dump OBJECT                      print an object in its text form
#
# With --test, cc compiles the `test` blocks (otherwise skipped) and ld makes
# a binary that runs them all and reports, in place of calling main.
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
# four EOT bytes: one ends a text, all four end a list of objects.  If
# $s_pre is set, the input starts with it and a newline.
s_pre=
stage() {
        s_image=$1; s_out=$2; shift 2
        { [ -z "$s_pre" ] || printf '%s\n' "$s_pre"
          cat "$@"; printf '\004\004\004\004'; } > "$s_out.in"
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

# cc SOURCE OBJECT, ld BINARY OBJECT...; $testing says whether for tests.
# To famc, a first line of the byte 0x01 and the file's name asks for tests.
cc() {
        s_pre=; [ -z "$testing" ] || s_pre=$(printf '\001%s' "$1")
        stage bin/famc "$2" "$1"; c_rc=$?
        s_pre=
        return $c_rc
}
ld() {
        l_out=$1; shift
        l_last=bin/rtmain.o; [ -z "$testing" ] || l_last=bin/rttest.o
        # startup first and the call of main last: init records run in order
        stage bin/famld "$l_out.core" bin/rt0.o "$@" bin/rt.o $l_last || return 1
        stage bin/fam.uncompressed "$l_out" "$l_out.core"; l_rc=$?
        rm -f "$l_out.core"
        return $l_rc
}
run() {
        printf '\004' > "$1.in"
        qemu "$1" "$1.in" "$1.out"; r_rc=$?
        cat "$1.out"
        rm -f "$1.in" "$1.out"
        return $r_rc
}

cmd=$1; [ $# -gt 0 ] && shift
testing=
case $cmd in cc|ld) [ "$1" = --test ] && { testing=1; shift; } ;; esac
case $cmd in
cc)
        [ $# -eq 2 ] || { echo "usage: fam.sh cc [--test] SOURCE OBJECT" >&2; exit 2; }
        cc "$1" "$2" || exit 1
        ;;
as)
        [ $# -eq 2 ] || { echo "usage: fam.sh as TEXT OBJECT" >&2; exit 2; }
        stage bin/famas "$2" "$1" || exit 1
        ;;
ld)
        [ $# -ge 2 ] || { echo "usage: fam.sh ld [--test] BINARY OBJECT..." >&2; exit 2; }
        ld "$@" || exit 1
        ;;
run)
        [ $# -eq 1 ] || { echo "usage: fam.sh run BINARY" >&2; exit 2; }
        run "$1"
        exit $?
        ;;
test)
        [ $# -ge 1 ] || { echo "usage: fam.sh test SOURCE..." >&2; exit 2; }
        testing=1; t_tmp="bin/famtest.$$"; t_objs=; t_n=0; t_rc=0
        for t_src; do
                t_n=$((t_n + 1))
                cc "$t_src" "$t_tmp.$t_n.o" || { t_rc=1; break; }
                t_objs="$t_objs $t_tmp.$t_n.o"
        done
        [ $t_rc -ne 0 ] || ld "$t_tmp" $t_objs || t_rc=1
        [ $t_rc -ne 0 ] || { run "$t_tmp"; t_rc=$?; }
        rm -f "$t_tmp" "$t_tmp".*.o
        exit $t_rc
        ;;
dump)
        [ $# -eq 1 ] || { echo "usage: fam.sh dump OBJECT" >&2; exit 2; }
        od -An -v -tu1 "$1" | awk -f scripts/dump.awk
        ;;
*)
        echo "usage: fam.sh cc|as|ld|run|test|dump ..." >&2; exit 2
        ;;
esac
