# lib/rt0.s -- startup, in the text form of an object (docs/OBJECT.md)
# because fam cannot express it.  scripts/build.sh assembles it to
# bin/rt0.o, and `fam.sh ld` puts it first in every link.
#
# It lays out memory and guards against the two stacks running out.  Then
# it runs into the init records of the objects after it, the last of which
# is lib/rtmain.s (call main and exit) or lib/rttest.s (report the tests).
# The rest of the runtime is lib/rt.fam.
#
#   image | variables | return ids | guard page | ... stack ... | device tree
#         tp          s10          s11 at first                sp at first
#
# On entry gp = the image's end (the core's doing) and a1 = the address of
# the device tree, which QEMU puts just under the top of RAM.
init

# The runtime's variables are the first whole page after the image, zeroed,
# and tp points at them for good (lib/rt.fam says what is where).
B7130000    # lui t2,0x1
9383F3FF    # addi t2,t2,-1
338D7100    # add s10,gp,t2
B7F3FFFF    # lui t2,0xfffff
337D7D00    # and s10,s10,t2
13020D00    # mv tp,s10
B7130000    # lui t2,0x1
330D7D00    # add s10,s10,t2        (the return ids start after them)
93030200    # mv t2,tp
# clear:
23A00300    # sw zero,0(t2)
93834300    # addi t2,t2,4
E3ECA3FF    # bltu t2,s10,clear

# The stack starts just under the device tree.  If a1 is not at least 1 MiB
# above the image (something other than QEMU started us), assume 1 MiB.
370E1000    # lui t3,0x100
330ECD01    # add t3,s10,t3
63F4C501    # bgeu a1,t3,sized
93050E00    # mv a1,t3
# sized:
13F105FF    # andi sp,a1,-16

# The return ids get a sixteenth of the space, in whole pages.
B383A541    # sub t2,a1,s10
93D30301    # srli t2,t2,0x10
9393C300    # slli t2,t2,0xc
B30D7D00    # add s11,s10,t2

# The page above them is a guard: a locked PMP entry makes any access to it
# trap, so a stack that grows down into it is caught.  The trap code finds
# the page again through mscratch.
73900D34    # csrw mscratch,s11
93D32D00    # srli t2,s11,0x2
93E3F31F    # ori t2,t2,511         (a 4 KiB region at s11)
7390033B    # csrw pmpaddr0,t2
93038009    # li t2,152             (locked, no read, write or execute)
7390033A    # csrw pmpcfg0,t2

# Traps come to the code below.
97030000    # auipc t2,0x0
93830301    # addi t2,t2,16
73905330    # csrw mtvec,t2
6F000004    # j done

# trap: a call nested too deep (the core's call sequence executes ebreak),
# a stack overflow (the guard page), or any other fault.  Nothing can be
# resumed: take a fresh piece of both stacks and report it.
#   __trap(cause, pc, address, guard page)
73252034    # csrr a0,mcause
F3251034    # csrr a1,mepc
73263034    # csrr a2,mtval
F3260034    # csrr a3,mscratch
B7230000    # lui t2,0x2
33817600    # add sp,a3,t2          (the stack's lowest page)
930D0D10    # addi s11,s10,256      (the lowest 64 return ids)
@__trap
6F000000    # j .
# done:
end
