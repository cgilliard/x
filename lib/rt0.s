# lib/rt0.s -- startup, written by hand until the language can express it
# (docs/OBJECT.md, "Text form").  scripts/build.sh assembles it to bin/rt0.o,
# which goes first on the link line.
#
# Sets up the return-id stack and the stack just past the image, calls main,
# and leaves QEMU with main's result as the exit code.
init
# addi s10,gp,15 ; andi s10,s10,-16     return ids: floor, the image's end
138DF100 137D0DFF
# lui t0,0x1 ; add s11,s10,t0           return ids: top, 4 KiB above
B7120000 B30D5D00
# lui t0,0x10 ; add sp,s11,t0           the stack: top, 64 KiB above that
B7020100 33815D00
@main
# lui t0,0x100                          the SiFive test finisher
B7021000
# beqz a0,pass ; slli a0,a0,16 ; lui t1,0x3 ; addi t1,t1,0x333 ; or a0,a0,t1
630E0500 13150501 37330000 13033333 33656500
# sw a0,0(t0) ; j .                     exit with code a0
23A0A200 6F000000
# pass: lui t1,0x5 ; addi t1,t1,0x555 ; sw t1,0(t0) ; j .       exit with 0
37530000 13035355 23A06200 6F000000
end
