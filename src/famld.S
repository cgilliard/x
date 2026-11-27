# MIT License
#
# Copyright (c) 2026 Christopher Gilliard
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# famld -- the fam linker (docs/OBJECT.md).
#
# Reads objects from the UART, one after another, up to the end marker (four
# EOT bytes), and writes text in the core's language: every function the
# init records reach as `: _NNNNNNN ... ;`, each before its first caller,
# then every init record as top-level code, in input order.  On an error, writes a message in place
# of the output and exits with 1.
#
# Functions that call each other in a cycle cannot all come before their
# callers.  When a function calls one that is still being written, the call
# goes through a stub instead, a word `>NNNNNNN` holding one jump:
#     : >NNNNNNN iiiiiiii mark 6F000000 , ;
# and the function it stands for starts with `iiiiiiii patch`, which points
# that jump at it.  `mark` and `patch` run in the core as it compiles; they
# and `allot`, which reserves the table they share, are defined at the top
# of the output (see preamble).
#
# Function ids.  An id site (a call site whose symbol index has its top bit
# set) is two instructions, `lui a0` and `addi a0`, that load the id of a
# function: a number from 1, given to each function some object takes the
# id of.  A call through an id is a call to `__call` with the id in t2.
# If an object calls `__call` and none defines it, the linker writes it:
# the dispatcher, a word that finds t2 among the ids by halving and calls
# the function, which so returns through it.  It keeps every function that
# has an id.
#
# Built from this file by tools/s2fam0.py into src/famld.fam0, which
# bin/fam0 turns into bin/famld.
#
# Memory, from the page after the code (base):
#   base                return ids, 64 KiB          (s10 floor, s11 pointer)
#   base + 0x10000      the emit stack, 64 KiB      (tp floor, sp pointer);
#                       its top words count the stubs, at -4(s3), and the
#                       function ids, at -8(s3)
#   base + 0x20000      the symbol table, 1 MiB     (s3 base, s4 next free)
#   base + 0x120000     the init list, 64 KiB       (s5 base, s6 next free)
#   base + 0x130000     the objects, 32 MiB         (s0 next free)
#   base + 0x2130000    the output, 32 MiB          (s7 base, s8 end, gp limit)
#
# An object stays as it was read, except that once checked:
#   - header word 1 (the version) holds the address of its call sites
#   - header word 2 (the size) holds the address of its code, which is also
#     where its call sites end
#   - word 1 of each of its symbols (the name offset) holds the address of
#     the linker's symbol for it, for functions and externals.  A local
#     function gets a linker symbol of its own, which no name finds.
#
# A linker symbol is 32 bytes: name start, name length, the object defining
#   it (0: none yet; 1: it is the dispatcher), its symbol there, state (0
#   not written, 1 being written, 2 written), number (from 1), its stub's
#   index + 1 (0: no stub), its function id (0: none).
# An init entry is 8 bytes: the object, the init symbol there.
#
# Other registers:
#   s9    = the function being written (0: none), for messages
#   ra    = the object being read, then the loop pointer of the top-level
#           loops (calls never use ra)
# ---------------------------------------------------------------------------

.altmacro

.macro LOAD_ADDRESS reg, label
_base\@:
        .equ _offset\@, (\label - _base\@)
        auipc   \reg, %hi(_offset\@)
        addi    \reg, \reg, %lo(_offset\@)
.endm

# --- calls without jalr: a return id on the s11 stack, a search tree at
# --- __dispatch (as in src/fam.S).  CALL clobbers t0; RET clobbers t0, t1.

.set    N_CALLS, 0

.macro EMIT_CALL id, target
    addi    s11, s11, -4
    bltu    s11, s10, __panic           # overflow: s11 dropped below stack base
    li      t0, \id
    sw      t0, 0(s11)
    j       \target
Lret_\id:
.endm

.macro CALL target
    EMIT_CALL %N_CALLS, \target
    .set    N_CALLS, N_CALLS + 1
.endm

.macro RET
    j       __dispatch
.endm

.macro BST lo, hi
    .if \lo > \hi
        j       __dispatch_trap            # empty subtree
    .else
        .if \lo == \hi
            j   Lret_\lo                   # leaf: id must equal lo
        .else
            BST_NODE %((\lo + \hi) / 2), \lo, \hi
        .endif
    .endif
.endm

.macro BST_NODE mid, lo, hi
    li      t1, \mid
    beq     t0, t1, Lret_\mid
    blt     t0, t1, Lleft_\mid
    BST     %(\mid + 1), \hi
Lleft_\mid:
    BST     \lo, %(\mid - 1)
.endm

# DEC_DIGIT pow -- write to the UART the digit of a4 at the power of ten
#   pow, and take it off a4.  Leading zeros are not written: a5 says whether
#   a digit has been.
.macro DEC_DIGIT pow
    li      t5, \pow
    li      a0, '0'
.Ldd_l\@:
    bltu    a4, t5, .Ldd_e\@
    sub     a4, a4, t5
    addi    a0, a0, 1
    j       .Ldd_l\@
.Ldd_e\@:
    li      t5, '0'
    bne     a0, t5, .Ldd_p\@
    beqz    a5, .Ldd_s\@
.Ldd_p\@:
    li      a5, 1
    CALL    uput4
.Ldd_s\@:
.endm

# O_SETUP -- for a program that writes an object (the o_ routines below):
#   lay out its memory, from the page after the code (base), and read the
#   source from the UART up to EOT.
#     base                return ids, 64 KiB        (s10 floor, s11 pointer)
#     base + 0x10000      16 words of variables (the last, at -4(s4),
#                         is the symbol count), then
#                         the symbols, 1 MiB        (s4 base, s5 next free)
#     base + 0x110000     the call sites, 1 MiB     (s6 base, s7 next free)
#     base + 0x210000     the names, 2 MiB          (gp base, tp next free)
#     base + 0x410000     the code, 16 MiB          (s8 base, s9 next free)
#     base + 0x1410000    the source, 32 MiB        (s0 base, s2 end)
#   Also: s1 = source cursor, s3 = line of the token last read, ra = the
#   symbol of the record being written (calls never use ra).
.macro O_SETUP
    LOAD_ADDRESS s10, data
    li      t0, 4095
    add     s10, s10, t0
    li      t0, -4096
    and     s10, s10, t0                # base: the page after the code
    li      t0, 0x10000
    add     s11, s10, t0                # return ids: top
    addi    s4, s11, 64                 # symbols, after the variables
    sw      zero, -4(s4)                # the symbol count
    mv      s5, s4
    li      t0, 0x100000
    add     s6, s11, t0                 # call sites
    mv      s7, s6
    add     gp, s6, t0                  # names
    mv      tp, gp
    li      t0, 0x200000
    add     s8, gp, t0                  # code
    mv      s9, s8
    li      t0, 0x1000000
    add     s0, s8, t0                  # source
    mv      s1, s0
    mv      s2, s0
    li      s3, 1                       # line 1
    li      ra, 0

    li      t0, 0x10000000              # UART base
    li      t2, 0x04                    # EOT
    li      t3, 0x2000000
    add     t3, s0, t3                  # source limit
.Los_rd:
    lbu     t1, 5(t0)
    andi    t1, t1, 0x01                # a byte waiting?
    beqz    t1, .Los_rd
    lbu     t1, 0(t0)
    beq     t1, t2, .Los_end
    bgeu    s2, t3, err_big
    sb      t1, 0(s2)
    addi    s2, s2, 1
    j       .Los_rd
.Los_end:
.endm

_start:
    LOAD_ADDRESS s10, data
    li      t0, 4095
    add     s10, s10, t0
    li      t0, -4096
    and     s10, s10, t0                # base: the page after the code
    li      t0, 0x10000
    add     s11, s10, t0                # return ids: top
    mv      tp, s11                     # emit stack: floor
    add     s3, s11, t0                 # symbol table
    addi    sp, s3, -16                 # emit stack: top, under the stub count
    sw      zero, -4(s3)
    sw      zero, -8(s3)
    mv      s4, s3
    li      t0, 0x100000
    add     s5, s3, t0                  # init list
    mv      s6, s5
    li      t0, 0x10000
    add     s0, s5, t0                  # objects
    li      t0, 0x2000000
    add     s7, s0, t0                  # output
    mv      s8, s7
    add     gp, s7, t0                  # output limit
    li      s9, 0

    # --- pass 1: read and check each object, enter its symbols.
.Ll_next:
    mv      ra, s0
    addi    t2, s0, 12
    bgtu    t2, s7, err_big
    mv      a0, s0
    addi    a1, s0, 4
    CALL    rd                          # the magic, or the end marker
    lw      t2, 0(ra)
    li      t3, 0x04040404
    beq     t2, t3, .Lp_done
    li      t3, 'F' | 'A'<<8 | 'M'<<16 | 'O'<<24
    bne     t2, t3, err_noobj
    addi    a1, ra, 12
    CALL    rd                          # version, size
    lw      t2, 4(ra)
    li      t3, 1
    bne     t2, t3, err_version
    lw      t2, 8(ra)
    li      t3, 28
    bltu    t2, t3, err_bad
    andi    t3, t2, 3
    bnez    t3, err_bad
    sub     t3, s7, ra
    bgtu    t2, t3, err_big
    add     a1, ra, t2
    CALL    rd                          # the rest
    mv      s0, a1

    lw      t2, 12(ra)                  # symbols
    lw      t3, 16(ra)                  # call sites
    lw      t4, 20(ra)                  # bytes of code
    lw      t5, 24(ra)                  # bytes of names
    lw      t6, 8(ra)                   # size
    bgtu    t2, t6, err_bad
    bgtu    t3, t6, err_bad
    bgtu    t4, t6, err_bad
    bgtu    t5, t6, err_bad
    or      a0, t4, t5
    andi    a0, a0, 3
    bnez    a0, err_bad
    slli    a0, t2, 4
    slli    a1, t2, 2
    add     a0, a0, a1
    addi    a0, a0, 28                  # header and symbols
    add     a2, ra, a0                  # where the call sites start
    slli    a1, t3, 3
    add     a3, a2, a1                  # where the code starts
    add     a0, a0, a1
    add     a0, a0, t4
    add     a0, a0, t5
    bne     a0, t6, err_bad             # the parts must add up to the size
    sw      a2, 4(ra)
    sw      a3, 8(ra)

    addi    s1, ra, 28                  # each symbol
    mv      s2, a2
.Ls_next:
    bgeu    s1, s2, .Ls_done
    lw      t2, 0(s1)                   # kind
    li      t3, 3
    bgtu    t2, t3, err_bad
    li      t3, 2
    beq     t2, t3, .Ls_init
    lw      a0, 4(s1)                   # the name
    lw      a1, 8(s1)
    beqz    a1, err_bad
    li      t3, 255
    bgtu    a1, t3, err_bad
    lw      t3, 24(ra)
    bgtu    a0, t3, err_bad
    add     t4, a0, a1
    bgtu    t4, t3, err_bad
    lw      t3, 8(ra)
    add     a0, a0, t3
    lw      t3, 20(ra)
    add     a0, a0, t3                  # its address
    li      a2, 0
    lw      t2, 0(s1)
    li      t3, 3
    beq     t2, t3, 3f                  # local: its own symbol, whatever
    CALL    find_sym                    # other objects call their names
3:  bnez    a2, 2f
    addi    t2, s4, 32                  # a new name
    bgtu    t2, s5, err_big
    mv      a2, s4
    sw      a0, 0(a2)
    sw      a1, 4(a2)
    sw      zero, 8(a2)
    sw      zero, 12(a2)
    sw      zero, 16(a2)
    sw      zero, 24(a2)
    sw      zero, 28(a2)
    li      t3, 1                       # number: the one before's + 1
    beq     s4, s3, 1f
    lw      t3, -12(s4)
    addi    t3, t3, 1
1:  sw      t3, 20(a2)
    mv      s4, t2
2:  sw      a2, 4(s1)
    lw      t2, 0(s1)
    beqz    t2, .Ls_step                # external: nothing more
    lw      t2, 8(a2)
    bnez    t2, err_dup
    CALL    chk_code
    sw      ra, 8(a2)
    sw      s1, 12(a2)
    j       .Ls_step
.Ls_init:
    CALL    chk_code
    addi    t2, s6, 8
    li      t3, 0x10000
    add     t3, s5, t3
    bgtu    t2, t3, err_big
    sw      ra, 0(s6)
    sw      s1, 4(s6)
    mv      s6, t2
.Ls_step:
    addi    s1, s1, 20
    j       .Ls_next
.Ls_done:

    lw      s1, 4(ra)                   # each call site
    lw      s2, 8(ra)
    lw      a4, 20(ra)                  # bytes of code
    lw      a5, 12(ra)                  # symbols
    li      a3, 0                       # where the one before ended
.Lc_next:
    bgeu    s1, s2, .Ll_next
    lw      t2, 0(s1)                   # its offset: after the one before,
    andi    t3, t2, 3                   # 28 bytes inside the code (8 for an
    bnez    t3, err_bad                 # id site)
    bltu    t2, a3, err_bad
    bgtu    t2, a4, err_bad
    lw      t3, 4(s1)
    srli    t5, t3, 31                  # t5 = 1 for an id site
    addi    a3, t2, 28
    beqz    t5, 1f
    addi    a3, t2, 8
1:  bgtu    a3, a4, err_bad
    slli    t3, t3, 1                   # its symbol: not an init record
    srli    t3, t3, 1
    bgeu    t3, a5, err_bad
    slli    t4, t3, 4
    slli    t3, t3, 2
    add     t3, t3, t4
    add     t3, t3, ra
    lw      t4, 28(t3)
    li      t6, 2
    beq     t4, t6, err_bad
    beqz    t5, 2f
    lw      t4, 32(t3)                  # an id site: the function gets an
    lw      t6, 28(t4)                  # id, if it has none
    bnez    t6, 2f
    lw      t6, -8(s3)
    addi    t6, t6, 1
    li      t5, 20000                   # (the dispatcher stays under 1 MiB)
    bgtu    t6, t5, err_ids
    sw      t6, -8(s3)
    sw      t6, 28(t4)
2:  addi    s1, s1, 8
    j       .Lc_next

    # --- pass 2: write every function an init record calls (emit_fn writes
    # --- its callees first), then the init records.  A function nothing
    # --- reaches is left out.
.Lp_done:
    li      t2, '_' | '_'<<8 | 'c'<<16 | 'a'<<24
    sw      t2, 0(tp)                   # (spelled at the emit stack's floor)
    li      t2, 'l' | 'l'<<8
    sw      t2, 4(tp)
    mv      a0, tp
    li      a1, 6
    CALL    find_sym                    # __call, called and not defined: the
    beqz    a2, 7f                      # dispatcher
    lw      t2, 8(a2)
    bnez    t2, 7f
    li      t2, 1
    sw      t2, 8(a2)
7:  mv      ra, s5
1:  bgeu    ra, s6, 3f
    lw      a5, 0(ra)
    lw      t2, 4(ra)
    lw      a2, 12(t2)
    lw      s2, 16(t2)
    add     s2, s2, a2                  # s2 = where the record's code ends
    CALL    first_call
    mv      s1, a6                      # s1 = the call site to look at next
2:  lw      a5, 0(ra)
    lw      t2, 8(a5)
    bgeu    s1, t2, 6f
    lw      t3, 0(s1)
    bgeu    t3, s2, 6f
    mv      a6, s1
    addi    s1, s1, 8
    lw      t3, 4(a6)
    bltz    t3, 2b                      # an id site calls nothing
    CALL    call_sym
    CALL    visit
    j       2b
6:  addi    ra, ra, 8
    j       1b
3:  mv      ra, s5
4:  bgeu    ra, s6, 5f
    lw      a5, 0(ra)
    lw      a1, 4(ra)
    CALL    emit_code
    li      a0, 0x0A
    CALL    out_ch
    addi    ra, ra, 8
    j       4b
5:  mv      ra, s8                      # the preamble is written last and
    CALL    preamble                    # sent first
    mv      a0, ra
    sub     a1, s8, ra
    CALL    uput_tok
    mv      a0, s7
    sub     a1, ra, s7
    CALL    uput_tok
    j       exit_ok

# rd -- read bytes from the UART into [a0, a1); a0 = a1 after.
#   Clobbers t2, t3.
rd:
    li      t2, 0x10000000              # UART base
1:  bgeu    a0, a1, 3f
2:  lbu     t3, 5(t2)
    andi    t3, t3, 0x01                # a byte waiting?
    beqz    t3, 2b
    lbu     t3, 0(t2)
    sb      t3, 0(a0)
    addi    a0, a0, 1
    j       1b
3:  RET

# chk_code -- s1 = a symbol of the object ra; error unless its code lies
#   inside the object's, in whole words.  Clobbers t2, t3, t4.
chk_code:
    lw      t2, 12(s1)
    lw      t3, 16(s1)
    or      t4, t2, t3
    andi    t4, t4, 3
    bnez    t4, err_bad
    lw      t4, 20(ra)
    bgtu    t2, t4, err_bad
    bgtu    t3, t4, err_bad
    add     t2, t2, t3
    bgtu    t2, t4, err_bad
    RET

# find_sym -- a0 = name start, a1 = length; a2 = its symbol, or 0.
#   Clobbers t2-t6.
find_sym:
    mv      a2, s3
1:  bgeu    a2, s4, 4f
    lw      t2, 4(a2)
    bne     t2, a1, 3f
    lw      t3, 0(a2)
    li      t4, 0
2:  bgeu    t4, a1, 5f                  # every byte matched
    add     t5, t3, t4
    lbu     t5, 0(t5)
    add     t6, a0, t4
    lbu     t6, 0(t6)
    bne     t5, t6, 3f
    addi    t4, t4, 1
    j       2b
3:  addi    a2, a2, 32
    j       1b
4:  li      a2, 0
5:  RET

# first_call -- a5 = object, a2 = code offset; a6 = its first call site at
#   or after that offset (the end of the call sites if none).  The call
#   sites are in ascending order.  Clobbers t2, t3, t4.
first_call:
    lw      a6, 4(a5)
    lw      t2, 8(a5)
1:  bgeu    a6, t2, 3f
    sub     t3, t2, a6
    srli    t3, t3, 4
    slli    t3, t3, 3
    add     t3, a6, t3                  # the middle one
    lw      t4, 0(t3)
    bgeu    t4, a2, 2f
    addi    a6, t3, 8
    j       1b
2:  mv      t2, t3
    j       1b
3:  RET

# call_sym -- a5 = object, a6 = call site; a2 = the symbol it calls.
#   Clobbers t2, t3.
call_sym:
    lw      t2, 4(a6)
    slli    t2, t2, 1                   # (less an id site's mark)
    srli    t2, t2, 1
    slli    t3, t2, 4
    slli    t2, t2, 2
    add     t2, t2, t3
    add     t2, t2, a5
    lw      a2, 32(t2)
    RET

# out_name -- a2 = symbol; append its short name: '_' and its number as
#   seven hex digits.  Clobbers a0, a1, t2, t3, t4.
out_name:
    li      a0, '_'
    lw      a1, 20(a2)
    j       out_num                     # (its RET returns for us)

# out_num -- a0 = a character, a1 = a number; append the character and the
#   number's low 28 bits as seven hex digits.  Clobbers a0, t2, t3, t4.
out_num:
    CALL    out_ch
    slli    t2, a1, 4                   # the low 28 bits, top first
    li      t3, 7
1:  srli    a0, t2, 28
    slli    t2, t2, 4
    li      t4, 10
    blt     a0, t4, 2f
    addi    a0, a0, 'A' - '0' - 10
2:  addi    a0, a0, '0'
    CALL    out_ch
    addi    t3, t3, -1
    bnez    t3, 1b
    RET

# out_word -- a0 = a word of code; append it as `XXXXXXXX , `, the digits
#   in memory order (lowest byte first).  Clobbers a0, t2-t5.
out_word:
    mv      t2, a0
    li      t3, 4
1:  andi    t4, t2, 0xFF
    srli    a0, t4, 4
    CALL    out_hex1
    andi    a0, t4, 0x0F
    CALL    out_hex1
    srli    t2, t2, 8
    addi    t3, t3, -1
    bnez    t3, 1b
    li      a0, ' ' | ','<<8 | ' '<<16
    j       out4                        # (its RET returns for us)

# out_hex1 -- a0 = 0..15; append it as one hex digit.  Clobbers a0, t5.
out_hex1:
    li      t5, 10
    blt     a0, t5, 1f
    addi    a0, a0, 'A' - '0' - 10
1:  addi    a0, a0, '0'
    j       out_ch                      # (its RET returns for us)

# visit -- a2 = a symbol the function being written (s9; 0: an init
#   record) calls.  If it is not written yet, write it now, so it comes
#   first.  If it is being written -- this call closes a cycle -- give it a
#   stub, if it has none.  (A call to itself needs none: the core defines a
#   name before its body.)  Undefined is an error.
visit:
    lw      t3, 8(a2)
    beqz    t3, err_undef
    beq     a2, s9, 2f                  # itself
    lw      t3, 16(a2)
    li      t4, 1
    beq     t3, t4, 1f
    j       emit_fn                     # (its RET returns for us)
1:  lw      t3, 24(a2)                  # being written: through its stub
    bnez    t3, 2f
    lw      t3, -4(s3)                  # a new stub, the next index
    addi    t3, t3, 1
    li      t4, 0xE000                  # (the core has room for these many)
    bgtu    t3, t4, err_stubs
    sw      t3, -4(s3)
    sw      t3, 24(a2)
    mv      a4, a2
    li      a0, ':' | ' '<<8
    CALL    out4
    li      a0, '>'
    lw      a1, 20(a4)
    CALL    out_num
    li      a0, ' '
    CALL    out_ch
    li      a0, '0'
    lw      a1, 24(a4)
    addi    a1, a1, -1
    CALL    out_num
    # append " mark 6F000000 , ;\n"
    li      a0, ' ' | 'm'<<8 | 'a'<<16 | 'r'<<24
    CALL    out4
    li      a0, 'k' | ' '<<8 | '6'<<16 | 'F'<<24
    CALL    out4
    li      a0, '0' | '0'<<8 | '0'<<16 | '0'<<24
    CALL    out4
    li      a0, '0' | '0'<<8 | ' '<<16 | ','<<24
    CALL    out4
    li      a0, ' ' | ';'<<8 | 0x0A<<16
    CALL    out4
2:  RET

# out_callee -- a2 = a symbol the function being written (s9) calls;
#   append the name to call it by, and a space: its stub's if it is being
#   written (and is not s9 itself), else its own.  Clobbers a0, a1, t2-t4.
out_callee:
    lw      t2, 16(a2)
    li      t3, 1
    bne     t2, t3, 1f
    beq     a2, s9, 1f
    li      a0, '>'
    lw      a1, 20(a2)
    CALL    out_num
    j       2f
1:  CALL    out_name
2:  li      a0, ' '
    j       out_ch                      # (its RET returns for us)

# emit_fn -- a2 = symbol (defined, not being written).  Write the function,
#   after the functions it calls (visit).
#   Frame on the emit stack: [s1, s2, s9]; s1 = the call site to look at
#   next, s2 = the offset where the function's code ends.
emit_fn:
    lw      t2, 16(a2)
    li      t3, 2
    beq     t2, t3, 3f                  # written already
    li      t2, 1
    sw      t2, 16(a2)
    addi    sp, sp, -12
    bltu    sp, tp, err_deep
    sw      s1, 0(sp)
    sw      s2, 4(sp)
    sw      s9, 8(sp)
    mv      s9, a2
    lw      a5, 8(s9)                   # first its callees
    li      t2, 1
    beq     a5, t2, .Ld_callees
    lw      t2, 12(s9)
    lw      a2, 12(t2)
    lw      s2, 16(t2)
    add     s2, s2, a2
    CALL    first_call
    mv      s1, a6
1:  lw      a5, 8(s9)
    lw      t2, 8(a5)
    bgeu    s1, t2, 2f
    lw      t3, 0(s1)
    bgeu    t3, s2, 2f
    mv      a6, s1
    addi    s1, s1, 8
    lw      t3, 4(a6)
    bltz    t3, 1b                      # an id site calls nothing
    CALL    call_sym
    CALL    visit
    j       1b
2:  li      a0, ':' | ' '<<8            # then its text
    CALL    out4
    mv      a2, s9
    CALL    out_name
    li      a0, ' '
    CALL    out_ch
    lw      a1, 24(s9)                  # its stub, if it has one, jumps here
    beqz    a1, 5f
    addi    a1, a1, -1
    li      a0, '0'
    CALL    out_num
    # append " patch "
    li      a0, ' ' | 'p'<<8 | 'a'<<16 | 't'<<24
    CALL    out4
    li      a0, 'c' | 'h'<<8 | ' '<<16
    CALL    out4
5:  lw      a5, 8(s9)
    li      t2, 1
    beq     a5, t2, .Ld_text
    lw      a1, 12(s9)
    CALL    emit_code
4:  li      a0, ';' | 0x0A<<8
    CALL    out4
    li      t2, 2
    sw      t2, 16(s9)
    lw      s1, 0(sp)
    lw      s2, 4(sp)
    lw      s9, 8(sp)
    addi    sp, sp, 12
3:  RET

    # The dispatcher.  Its callees: every function with an id.
.Ld_callees:
    mv      s1, s3
1:  bgeu    s1, s4, 2b
    mv      a2, s1
    addi    s1, s1, 32
    lw      t2, 28(a2)
    beqz    t2, 1b
    CALL    visit
    j       1b
    # Its text: an illegal instruction unless 1 <= t2 <= the last id, then
    # the tree (gen).  s1 = bytes of tree written, s2 = bytes in all.
.Ld_text:
    li      a0, 0x00039463              # bnez t2, +8
    CALL    out_word
    li      a0, 0
    CALL    out_word
    lw      t2, -8(s3)
    beqz    t2, 4b                      # no ids at all: every call is bad
    addi    t2, t2, 1
    CALL    out_li_t3
    li      a0, 0x01C3E463              # bltu t2, t3, +8
    CALL    out_word
    li      a0, 0
    CALL    out_word
    lw      a5, -8(s3)
    slli    s2, a5, 5
    slli    t2, a5, 4
    add     s2, s2, t2
    addi    s2, s2, -16                 # 48 a function, less 16
    li      s1, 0
    li      a4, 1
    CALL    gen
    j       4b

# gen -- a4/a5 = the first and last of a run of ids; append the code that
#   calls the function whose id t2 holds, known to be in the run.  For one
#   id, 32 bytes:   <call it> ; j <the tree's end>
#   For more, with m the middle id, 16 bytes and the two halves:
#       li t3, m ; bltu t2, t3, +8 ; j <second half> ; <first half>
#   so a run of n ids is 48n - 16 bytes.
#   Frame on the emit stack: [first, last, middle].
gen:
    bne     a4, a5, 3f
    mv      a2, s3                      # one id: find whose
1:  lw      t2, 28(a2)
    beq     t2, a4, 2f
    addi    a2, a2, 32
    j       1b
2:  CALL    out_callee
    addi    s1, s1, 28
    sub     t2, s2, s1
    CALL    out_j
    addi    s1, s1, 4
    RET
3:  addi    sp, sp, -12
    bltu    sp, tp, err_deep
    sw      a4, 0(sp)
    sw      a5, 4(sp)
    add     t2, a4, a5
    addi    t2, t2, 1
    srli    t2, t2, 1
    sw      t2, 8(sp)
    CALL    out_li_t3
    li      a0, 0x01C3E463              # bltu t2, t3, +8
    CALL    out_word
    lw      t2, 8(sp)                   # past the first half: 48 for each
    lw      t3, 0(sp)                   # of its ids, less 16, and this jump
    sub     t2, t2, t3
    slli    t3, t2, 5
    slli    t2, t2, 4
    add     t2, t2, t3
    addi    t2, t2, -12
    CALL    out_j
    addi    s1, s1, 16
    lw      a4, 0(sp)
    lw      a5, 8(sp)
    addi    a5, a5, -1
    CALL    gen
    lw      a4, 8(sp)
    lw      a5, 4(sp)
    CALL    gen
    addi    sp, sp, 12
    RET

# out_li_t3 -- t2 = a number; append `lui t3` and `addi t3, t3` that load
#   it.  Clobbers a0, a1, t2-t5.
out_li_t3:
    mv      a1, t2
    li      t3, 0x800
    add     t2, t2, t3
    srli    t2, t2, 12
    slli    a0, t2, 12
    ori     a0, a0, 0x637               # lui t3, 0  (0xE37)
    li      t3, 0x800
    or      a0, a0, t3
    CALL    out_word
    slli    a0, a1, 20
    li      t3, 0x000E0E13              # addi t3, t3, 0
    or      a0, a0, t3
    j       out_word

# out_j -- t2 = a distance; append `jal x0` over it.  Clobbers a0, t2-t5.
out_j:
    srli    t3, t2, 20                  # offset bit 20 -> bit 31
    andi    t3, t3, 1
    slli    t3, t3, 31
    srli    t4, t2, 1                   # bits 10:1 -> 30:21
    andi    t4, t4, 0x3FF
    slli    t4, t4, 21
    or      t3, t3, t4
    srli    t4, t2, 11                  # bit 11 -> 20
    andi    t4, t4, 1
    slli    t4, t4, 20
    or      t3, t3, t4
    srli    t4, t2, 12                  # bits 19:12 stay
    andi    t4, t4, 0xFF
    slli    t4, t4, 12
    or      t3, t3, t4
    ori     a0, t3, 0x6F
    j       out_word

# emit_code -- a5 = object, a1 = one of its symbols; write that record's
#   code in the core's language: a word as `XXXXXXXX ,`, a call site as the
#   callee's short name, an id site as the two instructions that load the
#   id.  a3 = offset, a4 = where it ends, a6 = the next call site, a7 = the
#   code (and the end of the call sites).
emit_code:
    lw      a3, 12(a1)
    lw      a4, 16(a1)
    add     a4, a4, a3
    mv      a2, a3
    CALL    first_call
    lw      a7, 8(a5)
1:  bgeu    a3, a4, 3f
    bgeu    a6, a7, 2f
    lw      t2, 0(a6)
    bne     t2, a3, 2f
    lw      t2, 4(a6)
    bltz    t2, 4f
    addi    a3, a3, 28                  # a call site
    bgtu    a3, a4, err_bad
    CALL    call_sym
    lw      t2, 8(a2)
    beqz    t2, err_undef
    addi    a6, a6, 8
    CALL    out_callee
    j       1b
4:  addi    a3, a3, 8                   # an id site
    bgtu    a3, a4, err_bad
    CALL    call_sym
    addi    a6, a6, 8
    lw      a1, 28(a2)
    li      t3, 0x800
    add     t2, a1, t3
    srli    t2, t2, 12
    slli    a0, t2, 12
    ori     a0, a0, 0x537               # lui a0, 0
    CALL    out_word
    slli    a0, a1, 20
    li      t3, 0x00050513              # addi a0, a0, 0
    or      a0, a0, t3
    CALL    out_word
    j       1b
2:  add     t2, a7, a3                  # a word
    lw      a0, 0(t2)
    CALL    out_word
    addi    a3, a3, 4
    j       1b
3:  RET

# preamble -- if there are stubs, append the definitions of the words they
#   use, which run in the core as it compiles (there: tp = its stack of
#   numbers, gp = where the next word of output goes, s8 = the start of its
#   region for such words: the region's next free address, a spare word,
#   then the words' code).  `allot` must be the first of them: its code is
#   6 instructions and the core's return, 28 bytes, so the table it reserves
#   is at 36(s8).
preamble:
    lw      t2, -4(s3)
    beqz    t2, 1f
    # append ":I allot "
    li      a0, ':' | 'I'<<8 | ' '<<16 | 'a'<<24
    CALL    out4
    li      a0, 'l' | 'l'<<8 | 'o'<<16 | 't'<<24
    CALL    out4
    li      a0, ' '
    CALL    out4
    # allot ( n -- ): reserve a table of n words in the region
    #       lw      t2, 0(tp)
    #       addi    tp, tp, 4
    #       slli    t2, t2, 2
    #       lw      t3, 0(s8)
    #       add     t3, t3, t2
    #       sw      t3, 0(s8)
    li      a0, 0x00022383
    CALL    out_word
    li      a0, 0x00420213
    CALL    out_word
    li      a0, 0x00239393
    CALL    out_word
    li      a0, 0x000C2E03
    CALL    out_word
    li      a0, 0x007E0E33
    CALL    out_word
    li      a0, 0x01CC2023
    CALL    out_word
    # append ";\n"
    li      a0, ';' | 0x0A<<8
    CALL    out4
    li      a0, '0'
    lw      a1, -4(s3)
    CALL    out_num
    # append " allot\n:I mark "
    li      a0, ' ' | 'a'<<8 | 'l'<<16 | 'l'<<24
    CALL    out4
    li      a0, 'o' | 't'<<8 | 0x0A<<16 | ':'<<24
    CALL    out4
    li      a0, 'I' | ' '<<8 | 'm'<<16 | 'a'<<24
    CALL    out4
    li      a0, 'r' | 'k'<<8 | ' '<<16
    CALL    out4
    # mark ( i -- ): table[i] = where the next word goes, the stub's jump
    #       lw      t2, 0(tp)
    #       addi    tp, tp, 4
    #       slli    t2, t2, 2
    #       add     t2, t2, s8
    #       sw      gp, 36(t2)
    li      a0, 0x00022383
    CALL    out_word
    li      a0, 0x00420213
    CALL    out_word
    li      a0, 0x00239393
    CALL    out_word
    li      a0, 0x018383B3
    CALL    out_word
    li      a0, 0x0233A223
    CALL    out_word
    # append ";\n:I patch "
    li      a0, ';' | 0x0A<<8 | ':'<<16 | 'I'<<24
    CALL    out4
    li      a0, ' ' | 'p'<<8 | 'a'<<16 | 't'<<24
    CALL    out4
    li      a0, 'c' | 'h'<<8 | ' '<<16
    CALL    out4
    # patch ( i -- ): make the jump at table[i] come here.  If that is over
    # 1 MiB, write a message to the UART and leave QEMU with exit code 1.
    #       lw      t2, 0(tp)
    #       addi    tp, tp, 4
    #       slli    t2, t2, 2
    #       add     t2, t2, s8
    #       lw      t3, 36(t2)
    #       sub     t2, gp, t3
    #       srli    t4, t2, 20
    #       bnez    t4, far
    #       srli    t4, t2, 1
    #       andi    t4, t4, 0x3FF
    #       slli    t4, t4, 21
    #       srli    t5, t2, 11
    #       andi    t5, t5, 1
    #       slli    t5, t5, 20
    #       or      t4, t4, t5
    #       srli    t5, t2, 12
    #       andi    t5, t5, 0xFF
    #       slli    t5, t5, 12
    #       or      t4, t4, t5
    #       ori     t4, t4, 0x6F
    #       sw      t4, 0(t3)
    #       j       done
    #   msg:
    #       .ascii  "famld: functions that call each other are over 1 MiB apart\n\0"
    #       .balign 4
    #   far:
    #       lla     t2, msg
    #       li      t3, 0x10000000
    #   1:  lbu     t4, 0(t2)
    #       beqz    t4, 3f
    #   2:  lbu     t5, 5(t3)
    #       andi    t5, t5, 0x20
    #       beqz    t5, 2b
    #       sb      t4, 0(t3)
    #       addi    t2, t2, 1
    #       j       1b
    #   3:  li      t3, 0x100000
    #       li      t4, 0x13333
    #       sw      t4, 0(t3)
    #   4:  j       4b
    li      a0, 0x00022383
    CALL    out_word
    li      a0, 0x00420213
    CALL    out_word
    li      a0, 0x00239393
    CALL    out_word
    li      a0, 0x018383B3
    CALL    out_word
    li      a0, 0x0243AE03
    CALL    out_word
    li      a0, 0x41C183B3
    CALL    out_word
    li      a0, 0x0143DE93
    CALL    out_word
    li      a0, 0x060E9C63
    CALL    out_word
    li      a0, 0x0013DE93
    CALL    out_word
    li      a0, 0x3FFEFE93
    CALL    out_word
    li      a0, 0x015E9E93
    CALL    out_word
    li      a0, 0x00B3DF13
    CALL    out_word
    li      a0, 0x001F7F13
    CALL    out_word
    li      a0, 0x014F1F13
    CALL    out_word
    li      a0, 0x01EEEEB3
    CALL    out_word
    li      a0, 0x00C3DF13
    CALL    out_word
    li      a0, 0x0FFF7F13
    CALL    out_word
    li      a0, 0x00CF1F13
    CALL    out_word
    li      a0, 0x01EEEEB3
    CALL    out_word
    li      a0, 0x06FEEE93
    CALL    out_word
    li      a0, 0x01DE2023
    CALL    out_word
    li      a0, 0x0800006F
    CALL    out_word
    li      a0, 0x6C6D6166
    CALL    out_word
    li      a0, 0x66203A64
    CALL    out_word
    li      a0, 0x74636E75
    CALL    out_word
    li      a0, 0x736E6F69
    CALL    out_word
    li      a0, 0x61687420
    CALL    out_word
    li      a0, 0x61632074
    CALL    out_word
    li      a0, 0x65206C6C
    CALL    out_word
    li      a0, 0x20686361
    CALL    out_word
    li      a0, 0x6568746F
    CALL    out_word
    li      a0, 0x72612072
    CALL    out_word
    li      a0, 0x766F2065
    CALL    out_word
    li      a0, 0x31207265
    CALL    out_word
    li      a0, 0x42694D20
    CALL    out_word
    li      a0, 0x61706120
    CALL    out_word
    li      a0, 0x000A7472
    CALL    out_word
    li      a0, 0x00000397
    CALL    out_word
    li      a0, 0xFC438393
    CALL    out_word
    li      a0, 0x10000E37
    CALL    out_word
    li      a0, 0x0003CE83
    CALL    out_word
    li      a0, 0x000E8E63
    CALL    out_word
    li      a0, 0x005E4F03
    CALL    out_word
    li      a0, 0x020F7F13
    CALL    out_word
    li      a0, 0xFE0F0CE3
    CALL    out_word
    li      a0, 0x01DE0023
    CALL    out_word
    li      a0, 0x00138393
    CALL    out_word
    li      a0, 0xFE5FF06F
    CALL    out_word
    li      a0, 0x00100E37
    CALL    out_word
    li      a0, 0x00013EB7
    CALL    out_word
    li      a0, 0x333E8E93
    CALL    out_word
    li      a0, 0x01DE2023
    CALL    out_word
    li      a0, 0x0000006F
    CALL    out_word
    # append ";\n"
    li      a0, ';' | 0x0A<<8
    CALL    out4
1:  RET

# out_ch -- a0 = character; append it to the output buffer [s7, gp).
out_ch:
    bgeu    s8, gp, err_big
    sb      a0, 0(s8)
    addi    s8, s8, 1
    RET

# out4 -- a0 = up to four characters, the first in the low byte, ended early
#   by a zero byte; append them to the output buffer.  Clobbers a0, t2.
out4:
1:  andi    t2, a0, 0xFF
    beqz    t2, 2f
    bgeu    s8, gp, err_big
    sb      t2, 0(s8)
    addi    s8, s8, 1
    srli    a0, a0, 8
    j       1b
2:  RET

# --- errors: "famld: <what>[: <name>][ in <function>]", then exit 1 --------

# err_in -- finish a message with " in <function>" if one is being written
#   (s9), then leave.
err_in:
    beqz    s9, err_end
    # say " in "
    li      a0, ' ' | 'i'<<8 | 'n'<<16 | ' '<<24
    CALL    uput4
    lw      a0, 0(s9)
    lw      a1, 4(s9)
    CALL    uput_tok
    j       err_end

err_noobj:
    # say "famld: the input is not a fam object"
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'l'<<24
    CALL    uput4
    li      a0, 'd' | ':'<<8 | ' '<<16 | 't'<<24
    CALL    uput4
    li      a0, 'h' | 'e'<<8 | ' '<<16 | 'i'<<24
    CALL    uput4
    li      a0, 'n' | 'p'<<8 | 'u'<<16 | 't'<<24
    CALL    uput4
    li      a0, ' ' | 'i'<<8 | 's'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'n' | 'o'<<8 | 't'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'a' | ' '<<8 | 'f'<<16 | 'a'<<24
    CALL    uput4
    li      a0, 'm' | ' '<<8 | 'o'<<16 | 'b'<<24
    CALL    uput4
    li      a0, 'j' | 'e'<<8 | 'c'<<16 | 't'<<24
    CALL    uput4
    j       err_end
err_version:
    # say "famld: unknown object version"
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'l'<<24
    CALL    uput4
    li      a0, 'd' | ':'<<8 | ' '<<16 | 'u'<<24
    CALL    uput4
    li      a0, 'n' | 'k'<<8 | 'n'<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'w' | 'n'<<8 | ' '<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'b' | 'j'<<8 | 'e'<<16 | 'c'<<24
    CALL    uput4
    li      a0, 't' | ' '<<8 | 'v'<<16 | 'e'<<24
    CALL    uput4
    li      a0, 'r' | 's'<<8 | 'i'<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'n'
    CALL    uput4
    j       err_end
err_bad:
    # say "famld: bad object"
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'l'<<24
    CALL    uput4
    li      a0, 'd' | ':'<<8 | ' '<<16 | 'b'<<24
    CALL    uput4
    li      a0, 'a' | 'd'<<8 | ' '<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'b' | 'j'<<8 | 'e'<<16 | 'c'<<24
    CALL    uput4
    li      a0, 't'
    CALL    uput4
    j       err_end
err_big:
    # say "famld: out of memory"
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'l'<<24
    CALL    uput4
    li      a0, 'd' | ':'<<8 | ' '<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'u' | 't'<<8 | ' '<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'f' | ' '<<8 | 'm'<<16 | 'e'<<24
    CALL    uput4
    li      a0, 'm' | 'o'<<8 | 'r'<<16 | 'y'<<24
    CALL    uput4
    j       err_end
err_ids:
    # say "famld: too many functions have their id taken"
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'l'<<24
    CALL    uput4
    li      a0, 'd' | ':'<<8 | ' '<<16 | 't'<<24
    CALL    uput4
    li      a0, 'o' | 'o'<<8 | ' '<<16 | 'm'<<24
    CALL    uput4
    li      a0, 'a' | 'n'<<8 | 'y'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'f' | 'u'<<8 | 'n'<<16 | 'c'<<24
    CALL    uput4
    li      a0, 't' | 'i'<<8 | 'o'<<16 | 'n'<<24
    CALL    uput4
    li      a0, 's' | ' '<<8 | 'h'<<16 | 'a'<<24
    CALL    uput4
    li      a0, 'v' | 'e'<<8 | ' '<<16 | 't'<<24
    CALL    uput4
    li      a0, 'h' | 'e'<<8 | 'i'<<16 | 'r'<<24
    CALL    uput4
    li      a0, ' ' | 'i'<<8 | 'd'<<16 | ' '<<24
    CALL    uput4
    li      a0, 't' | 'a'<<8 | 'k'<<16 | 'e'<<24
    CALL    uput4
    li      a0, 'n'
    CALL    uput4
    j       err_end
err_stubs:
    # say "famld: too many functions call each other"
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'l'<<24
    CALL    uput4
    li      a0, 'd' | ':'<<8 | ' '<<16 | 't'<<24
    CALL    uput4
    li      a0, 'o' | 'o'<<8 | ' '<<16 | 'm'<<24
    CALL    uput4
    li      a0, 'a' | 'n'<<8 | 'y'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'f' | 'u'<<8 | 'n'<<16 | 'c'<<24
    CALL    uput4
    li      a0, 't' | 'i'<<8 | 'o'<<16 | 'n'<<24
    CALL    uput4
    li      a0, 's' | ' '<<8 | 'c'<<16 | 'a'<<24
    CALL    uput4
    li      a0, 'l' | 'l'<<8 | ' '<<16 | 'e'<<24
    CALL    uput4
    li      a0, 'a' | 'c'<<8 | 'h'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'o' | 't'<<8 | 'h'<<16 | 'e'<<24
    CALL    uput4
    li      a0, 'r'
    CALL    uput4
    j       err_end
err_deep:
    # say "famld: calls nested too deep"
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'l'<<24
    CALL    uput4
    li      a0, 'd' | ':'<<8 | ' '<<16 | 'c'<<24
    CALL    uput4
    li      a0, 'a' | 'l'<<8 | 'l'<<16 | 's'<<24
    CALL    uput4
    li      a0, ' ' | 'n'<<8 | 'e'<<16 | 's'<<24
    CALL    uput4
    li      a0, 't' | 'e'<<8 | 'd'<<16 | ' '<<24
    CALL    uput4
    li      a0, 't' | 'o'<<8 | 'o'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'd' | 'e'<<8 | 'e'<<16 | 'p'<<24
    CALL    uput4
    j       err_end
err_dup:                                # a0/a1 = the name
    mv      a4, a0
    mv      a5, a1
    # say "famld: defined twice: "
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'l'<<24
    CALL    uput4
    li      a0, 'd' | ':'<<8 | ' '<<16 | 'd'<<24
    CALL    uput4
    li      a0, 'e' | 'f'<<8 | 'i'<<16 | 'n'<<24
    CALL    uput4
    li      a0, 'e' | 'd'<<8 | ' '<<16 | 't'<<24
    CALL    uput4
    li      a0, 'w' | 'i'<<8 | 'c'<<16 | 'e'<<24
    CALL    uput4
    li      a0, ':' | ' '<<8
    CALL    uput4
    mv      a0, a4
    mv      a1, a5
    CALL    uput_tok
    j       err_end
err_undef:                              # a2 = the symbol
    mv      a4, a2
    # say "famld: undefined: "
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'l'<<24
    CALL    uput4
    li      a0, 'd' | ':'<<8 | ' '<<16 | 'u'<<24
    CALL    uput4
    li      a0, 'n' | 'd'<<8 | 'e'<<16 | 'f'<<24
    CALL    uput4
    li      a0, 'i' | 'n'<<8 | 'e'<<16 | 'd'<<24
    CALL    uput4
    li      a0, ':' | ' '<<8
    CALL    uput4
    lw      a0, 0(a4)
    lw      a1, 4(a4)
    CALL    uput_tok
    j       err_in

# --- shared routines ------------------------------------------------------

# uput4 -- a0 = up to four characters (as out4); write them to the UART.
#   Clobbers a0, t2, t3, t4.
uput4:
    li      t2, 0x10000000              # UART base
1:  andi    t3, a0, 0xFF
    beqz    t3, 3f
2:  lbu     t4, 5(t2)
    andi    t4, t4, 0x20                # LSR THR-empty
    beqz    t4, 2b
    sb      t3, 0(t2)
    srli    a0, a0, 8
    j       1b
3:  RET

# uput_tok -- a0 = start, a1 = length; write those bytes to the UART.
#   Clobbers t2, t3, t4, t5.
uput_tok:
    li      t2, 0x10000000
    li      t5, 0
1:  bgeu    t5, a1, 3f
    add     t3, a0, t5
    lbu     t3, 0(t3)
2:  lbu     t4, 5(t2)
    andi    t4, t4, 0x20
    beqz    t4, 2b
    sb      t3, 0(t2)
    addi    t5, t5, 1
    j       1b
3:  RET

# exit_ok / err_end -- leave QEMU through the SiFive test finisher: exit
#   code 0, or a newline and exit code 1.
exit_ok:
    li      t0, 0x100000
    li      t1, 0x5555
    sw      t1, 0(t0)
1:  j       1b

err_end:
    li      a0, 0x0A
    CALL    uput4
    li      t0, 0x100000
    li      t1, 0x00013333
    sw      t1, 0(t0)
1:  j       1b

# __panic -- the return-id stack overflowed.  No CALL here.
__panic:
    li      t0, 0x10000000
    li      t1, 0x3F                    # '?'
1:  lbu     t2, 5(t0)
    andi    t2, t2, 0x20
    beqz    t2, 1b
    sb      t1, 0(t0)
    li      t0, 0x100000
    li      t1, 0x00013333
    sw      t1, 0(t0)
2:  j       2b

__dispatch:
    lw      t0, 0(s11)                  # pop return id
    addi    s11, s11, 4
    li      t1, N_CALLS
    bgeu    t0, t1, __dispatch_trap     # out-of-range id -> trap
    BST     0, %(N_CALLS - 1)
__dispatch_trap:
1:  j       1b

data:
