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
# famas -- the fam object assembler (docs/OBJECT.md, "Text form").
#
# Reads the text form of an object from the UART (up to EOT) and writes the
# object.  On an error, writes a message in place of the object and exits
# with 1.
#
# The text form:
#     fn NAME            a function: its body follows, up to `end`
#     local NAME         the same, for a function only this object can call
#     init               startup code: its body follows, up to `end`
#     XXXXXXXX           in a body: four bytes of code, in memory order
#     @NAME              in a body: a call to the function NAME
#     &NAME              in a body: the two instructions that load the
#                        function NAME's id into a0
#     # ...              a token starting with # is a comment to the line's end
#
# Built from this file by tools/s2fam0_fam.py into src/famas.fam0, which
# bin/fam0 turns into bin/famas.
#
# Memory and registers: see O_SETUP below.
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
    O_SETUP

.La_next:
    CALL    next_tok
    beqz    a1, .La_done
    CALL    pack_tok
    li      a7, 3
    li      t2, 'l' | 'o'<<8 | 'c'<<16 | 'a'<<24
    bne     a2, t2, 1f
    li      t2, 'l'
    beq     a3, t2, .La_fn
1:  bnez    a3, err_record
    li      a7, 1
    li      t2, 'f' | 'n'<<8
    beq     a2, t2, .La_fn
    li      t2, 'i' | 'n'<<8 | 'i'<<16 | 't'<<24
    beq     a2, t2, .La_init
    j       err_record
.La_fn:
    CALL    next_tok                    # the name
    beqz    a1, err_noend
    CALL    chk_name
    mv      a5, a7
    CALL    o_define
    beqz    a2, err_dup
    j       .La_body
.La_init:
    CALL    o_init
.La_body:
    CALL    next_tok
    beqz    a1, err_noend
    lbu     t2, 0(a0)
    li      t3, '@'
    bne     t2, t3, 1f
    addi    a0, a0, 1                   # a call
    addi    a1, a1, -1
    CALL    chk_name
    CALL    o_call
    j       .La_body
1:  li      t3, '&'
    bne     t2, t3, 1f
    addi    a0, a0, 1                   # an id
    addi    a1, a1, -1
    CALL    chk_name
    li      a5, 0
    CALL    o_ref
    CALL    o_idsite
    j       .La_body
1:  CALL    pack_tok
    li      t2, 'e' | 'n'<<8 | 'd'<<16
    bne     a2, t2, 2f
    bnez    a3, 2f
    CALL    o_end
    j       .La_next
2:  CALL    hex_word
    CALL    o_word
    j       .La_body
.La_done:
    CALL    o_write
    j       exit_ok

# next_tok -- the next token of [s1, s2): a0 = start, a1 = length (0 at the
#   end), s1 moved past it, s3 = its line.  Bytes up to the space are
#   separators; a token starting with '#' is a comment to the end of its
#   line.  Clobbers t2, t3.
next_tok:
1:  bgeu    s1, s2, 7f
    lbu     t2, 0(s1)
    li      t3, 0x0A
    bne     t2, t3, 2f
    addi    s3, s3, 1
2:  li      t3, ' '
    bgtu    t2, t3, 3f
    addi    s1, s1, 1
    j       1b
3:  li      t3, '#'
    bne     t2, t3, 5f
4:  addi    s1, s1, 1                   # a comment: to the end of the line
    bgeu    s1, s2, 7f
    lbu     t2, 0(s1)
    li      t3, 0x0A
    bne     t2, t3, 4b
    j       1b
5:  mv      a0, s1
6:  addi    s1, s1, 1
    bgeu    s1, s2, 8f
    lbu     t2, 0(s1)
    li      t3, ' '
    bgtu    t2, t3, 6b
8:  sub     a1, s1, a0
    RET
7:  mv      a0, s1
    li      a1, 0
    RET

# chk_name -- a0 = start, a1 = length; error unless it can be a name: 1 to
#   255 bytes, no '@'.  Clobbers t2, t3, t4.
chk_name:
    beqz    a1, err_name
    li      t2, 255
    bgtu    a1, t2, err_name
    li      t2, 0
1:  add     t3, a0, t2
    lbu     t3, 0(t3)
    li      t4, '@'
    beq     t3, t4, err_name
    addi    t2, t2, 1
    bltu    t2, a1, 1b
    RET

# --- errors: "famas: line N: <what>", then exit 1 --------------------------

err_pfx:
    # say "famas: "
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'a'<<24
    CALL    uput4
    li      a0, 's' | ':'<<8 | ' '<<16
    CALL    uput4
    RET

# err_tok -- finish a message with the token a6/a7, then leave.
err_tok:
    mv      a0, a6
    mv      a1, a7
    CALL    uput_tok
    j       err_end

err_record:                             # a0/a1 = the token
    mv      a6, a0
    mv      a7, a1
    CALL    err_line
    # say "not a record: "
    li      a0, 'n' | 'o'<<8 | 't'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'a' | ' '<<8 | 'r'<<16 | 'e'<<24
    CALL    uput4
    li      a0, 'c' | 'o'<<8 | 'r'<<16 | 'd'<<24
    CALL    uput4
    li      a0, ':' | ' '<<8
    CALL    uput4
    j       err_tok
err_name:                               # a0/a1 = the token
    mv      a6, a0
    mv      a7, a1
    CALL    err_line
    # say "not a name: "
    li      a0, 'n' | 'o'<<8 | 't'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'a' | ' '<<8 | 'n'<<16 | 'a'<<24
    CALL    uput4
    li      a0, 'm' | 'e'<<8 | ':'<<16 | ' '<<24
    CALL    uput4
    j       err_tok
err_dup:                                # a0/a1 = the name
    mv      a6, a0
    mv      a7, a1
    CALL    err_line
    # say "defined twice: "
    li      a0, 'd' | 'e'<<8 | 'f'<<16 | 'i'<<24
    CALL    uput4
    li      a0, 'n' | 'e'<<8 | 'd'<<16 | ' '<<24
    CALL    uput4
    li      a0, 't' | 'w'<<8 | 'i'<<16 | 'c'<<24
    CALL    uput4
    li      a0, 'e' | ':'<<8 | ' '<<16
    CALL    uput4
    j       err_tok
err_token:                              # a0/a1 = the token
    mv      a6, a0
    mv      a7, a1
    CALL    err_line
    # say "not a hex word or a call: "
    li      a0, 'n' | 'o'<<8 | 't'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'a' | ' '<<8 | 'h'<<16 | 'e'<<24
    CALL    uput4
    li      a0, 'x' | ' '<<8 | 'w'<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'r' | 'd'<<8 | ' '<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'r' | ' '<<8 | 'a'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'c' | 'a'<<8 | 'l'<<16 | 'l'<<24
    CALL    uput4
    li      a0, ':' | ' '<<8
    CALL    uput4
    j       err_tok
err_noend:
    CALL    err_line
    # say "record without end"
    li      a0, 'r' | 'e'<<8 | 'c'<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'r' | 'd'<<8 | ' '<<16 | 'w'<<24
    CALL    uput4
    li      a0, 'i' | 't'<<8 | 'h'<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'u' | 't'<<8 | ' '<<16 | 'e'<<24
    CALL    uput4
    li      a0, 'n' | 'd'<<8
    CALL    uput4
    j       err_end
err_big:
    # say "famas: out of memory"
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'a'<<24
    CALL    uput4
    li      a0, 's' | ':'<<8 | ' '<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'u' | 't'<<8 | ' '<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'f' | ' '<<8 | 'm'<<16 | 'e'<<24
    CALL    uput4
    li      a0, 'm' | 'o'<<8 | 'r'<<16 | 'y'<<24
    CALL    uput4
    j       err_end

# --- writing an object (docs/OBJECT.md); memory and registers as O_SETUP ----

# o_find -- a0 = name start, a1 = length (not 0); a2 = its symbol (0: none),
#   a3 = its index (none: the symbol count).  Clobbers t2-t6.
o_find:
    mv      a2, s4
    li      a3, 0
1:  bgeu    a2, s5, 4f
    lw      t2, 8(a2)
    bne     t2, a1, 3f
    lw      t3, 4(a2)
    add     t3, t3, gp
    li      t4, 0
2:  bgeu    t4, a1, 5f                  # every byte matched
    add     t5, t3, t4
    lbu     t5, 0(t5)
    add     t6, a0, t4
    lbu     t6, 0(t6)
    bne     t5, t6, 3f
    addi    t4, t4, 1
    j       2b
3:  addi    a2, a2, 20
    addi    a3, a3, 1
    j       1b
4:  li      a2, 0
5:  RET

# o_new -- a0 = name start, a1 = length (0: no name), a4 = kind; append a
#   symbol with no code; a2 = the symbol, a3 = its index.  Clobbers t2, t3.
o_new:
    addi    t2, s5, 20
    bgtu    t2, s6, err_big
    add     t2, tp, a1
    bgtu    t2, s8, err_big
    mv      a2, s5
    addi    s5, s5, 20
    sw      a4, 0(a2)
    sub     t2, tp, gp
    sw      t2, 4(a2)
    sw      a1, 8(a2)
    sw      zero, 12(a2)
    sw      zero, 16(a2)
    li      t2, 0
1:  bgeu    t2, a1, 2f
    add     t3, a0, t2
    lbu     t3, 0(t3)
    sb      t3, 0(tp)
    addi    tp, tp, 1
    addi    t2, t2, 1
    j       1b
2:  lw      a3, -4(s4)
    addi    t2, a3, 1
    sw      t2, -4(s4)
    RET

# o_define -- a0 = name start, a1 = length, a5 = kind (1 a function, 3 a
#   local function); start the record of that function.  a2 = its symbol,
#   or 0 if the name is defined already.  Clobbers a3, a4, t2-t6.
o_define:
    CALL    o_find
    bnez    a2, 1f
    mv      a4, a5
    CALL    o_new
    j       3f
1:  lw      t2, 0(a2)
    beqz    t2, 2f
    li      a2, 0                       # defined already
    RET
2:  sw      a5, 0(a2)                   # called earlier: now defined
3:  sub     t2, s9, s8
    sw      t2, 12(a2)
    mv      ra, a2
    RET

# o_init -- start an init record.  Clobbers a1-a4, t2, t3.
o_init:
    li      a1, 0
    li      a4, 2
    CALL    o_new
    sub     t2, s9, s8
    sw      t2, 12(a2)
    mv      ra, a2
    RET

# o_end -- end the record: its code is what was appended since it started.
#   Clobbers t2, t3.
o_end:
    sub     t2, s9, s8
    lw      t3, 12(ra)
    sub     t2, t2, t3
    sw      t2, 16(ra)
    li      ra, 0
    RET

# o_word -- a0 = a word; append it to the code.  Clobbers t2.
o_word:
    addi    t2, s9, 4
    bgtu    t2, s0, err_big
    sw      a0, 0(s9)
    mv      s9, t2
    RET

# o_ref -- a0 = name start, a1 = length, a5 = the kind to give the symbol
#   if the name is new (0: external until defined); a2 = the symbol of that
#   name, a3 = its index.  Clobbers a4, t2-t6.
o_ref:
    CALL    o_find
    bnez    a2, 1f
    mv      a4, a5
    CALL    o_new
1:  RET

# o_call -- a0 = name start, a1 = length; append a call to that function.
#   Clobbers a2-a5, t2-t6.
o_call:
    li      a5, 0
    CALL    o_ref                       # then o_site

# o_site -- a3 = a symbol's index; append a call to it: a call site and its
#   28 zero bytes of code.  Clobbers t2, t3, t4.
o_site:
    addi    t2, s7, 8
    bgtu    t2, gp, err_big
    addi    t3, s9, 28
    bgtu    t3, s0, err_big
    sub     t4, s9, s8
    sw      t4, 0(s7)
    sw      a3, 4(s7)
    mv      s7, t2
2:  sw      zero, 0(s9)
    addi    s9, s9, 4
    bltu    s9, t3, 2b
    RET

# o_idsite -- a3 = a symbol's index; append the loading of that function's
#   id into a0: an id site (a call site with the index's top bit set) and
#   its 8 zero bytes of code.  Clobbers t2, t3, t4.
o_idsite:
    addi    t2, s7, 8
    bgtu    t2, gp, err_big
    addi    t3, s9, 8
    bgtu    t3, s0, err_big
    sub     t4, s9, s8
    sw      t4, 0(s7)
    li      t4, 0x80000000
    or      t4, t4, a3
    sw      t4, 4(s7)
    mv      s7, t2
    sw      zero, 0(s9)
    sw      zero, 4(s9)
    mv      s9, t3
    RET

# uput_w -- a0 = a word; write its four bytes to the UART, lowest first.
#   Clobbers a0, t2, t3, t4.
uput_w:
    li      t2, 0x10000000
    li      t3, 4
1:  lbu     t4, 5(t2)
    andi    t4, t4, 0x20
    beqz    t4, 1b
    sb      a0, 0(t2)
    srli    a0, a0, 8
    addi    t3, t3, -1
    bnez    t3, 1b
    RET

# o_write -- write the object to the UART: header, symbols, call sites,
#   code, names.
o_write:
1:  sub     t2, tp, gp                  # pad the names to a multiple of 4
    andi    t2, t2, 3
    beqz    t2, 2f
    bgeu    tp, s8, err_big
    sb      zero, 0(tp)
    addi    tp, tp, 1
    j       1b
2:  li      a0, 'F' | 'A'<<8 | 'M'<<16 | 'O'<<24
    CALL    uput_w
    li      a0, 1                       # version
    CALL    uput_w
    sub     a0, s5, s4                  # size of the whole object
    sub     t2, s7, s6
    add     a0, a0, t2
    sub     t2, s9, s8
    add     a0, a0, t2
    sub     t2, tp, gp
    add     a0, a0, t2
    addi    a0, a0, 28
    CALL    uput_w
    lw      a0, -4(s4)                  # symbols
    CALL    uput_w
    sub     a0, s7, s6                  # call sites
    srli    a0, a0, 3
    CALL    uput_w
    sub     a0, s9, s8                  # bytes of code
    CALL    uput_w
    sub     a0, tp, gp                  # bytes of names
    CALL    uput_w
    mv      a0, s4
    sub     a1, s5, s4
    CALL    uput_tok
    mv      a0, s6
    sub     a1, s7, s6
    CALL    uput_tok
    mv      a0, s8
    sub     a1, s9, s8
    CALL    uput_tok
    mv      a0, gp
    sub     a1, tp, gp
    CALL    uput_tok
    RET

# err_line -- write "<program>: line N: " for the line in s3 (err_pfx
#   writes the program's part).  Clobbers a0, a4, a5, t2-t5.
err_line:
    CALL    err_pfx
    # say "line "
    li      a0, 'l' | 'i'<<8 | 'n'<<16 | 'e'<<24
    CALL    uput4
    li      a0, ' '
    CALL    uput4
    mv      a4, s3
    li      a5, 0
    DEC_DIGIT 1000000000
    DEC_DIGIT 100000000
    DEC_DIGIT 10000000
    DEC_DIGIT 1000000
    DEC_DIGIT 100000
    DEC_DIGIT 10000
    DEC_DIGIT 1000
    DEC_DIGIT 100
    DEC_DIGIT 10
    addi    a0, a4, '0'
    CALL    uput4
    # say ": "
    li      a0, ':' | ' '<<8
    CALL    uput4
    RET

# hex_word -- a0 = start, a1 = length of a token; a0 = the word it spells
#   as eight uppercase hex digits in memory order (the first two digits are
#   the lowest byte).  Anything else is an error (err_token).
#   Clobbers t2-t6.
hex_word:
    li      t2, 8
    bne     a1, t2, err_token
    li      t2, 0                       # digit index
    li      t5, 0                       # the word
1:  add     t3, a0, t2
    lbu     t3, 0(t3)
    addi    t4, t3, -'0'
    li      t6, 10
    bltu    t4, t6, 2f
    addi    t4, t3, -'A'
    li      t6, 6
    bgeu    t4, t6, err_token
    addi    t4, t4, 10
2:  srli    t6, t2, 1                   # shift: 8 * its byte, + 4 for the
    slli    t6, t6, 3                   # first digit of the pair
    andi    t3, t2, 1
    bnez    t3, 3f
    addi    t6, t6, 4
3:  sll     t4, t4, t6
    or      t5, t5, t4
    addi    t2, t2, 1
    li      t6, 8
    bltu    t2, t6, 1b
    mv      a0, t5
    RET

# pack_tok -- a0 = start, a1 = length; a2/a3 = the token's first/last four
#   bytes as two zero-padded words (for comparing with a keyword).  A token
#   over 8 bytes gives -1/-1, which matches no keyword.  Clobbers t2, t3, t4.
pack_tok:
    li      a2, -1
    li      a3, -1
    li      t2, 8
    bgtu    a1, t2, 4f
    li      a2, 0
    li      a3, 0
    li      t2, 0                       # byte index
1:  bgeu    t2, a1, 4f
    add     t3, a0, t2
    lbu     t3, 0(t3)
    andi    t4, t2, 3
    slli    t4, t4, 3
    sll     t3, t3, t4
    li      t4, 4
    bgeu    t2, t4, 2f
    or      a2, a2, t3
    j       3f
2:  or      a3, a3, t3
3:  addi    t2, t2, 1
    j       1b
4:  RET


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
