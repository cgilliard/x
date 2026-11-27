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
# famc -- the fam compiler's front end (docs/LANGUAGE.md, docs/OBJECT.md).
#
# Reads one source file from the UART (up to EOT) and writes its object.
# On an error, writes a message in place of the object and exits with 1.
#
# The language so far (every value is a 32-bit integer):
#     program   = { function | test }
#     function  = "fn" NAME "(" [ NAME { "," NAME } ] ")" block
#     test      = "test" STRING block
#     block     = "{" { statement } "}"
#     statement = "let" NAME "=" expr ";"
#               | NAME "=" expr ";"
#               | "if" expr block [ "else" ( block | if-statement ) ]
#               | "while" expr block
#               | "return" [ expr ] ";"
#               | "asm" "{" { HEXWORD } "}"
#               | "assert" expr ";"             in a test
#               | expr ";"
#     expr      = unary { OPERATOR unary }      by precedence, lowest first:
#                   ||   &&   == != < <= > >=   |   ^   &   << >>   + -
#                   * / %
#     unary     = ( "-" | "!" | "~" ) unary | NUMBER | STRING | NAME
#               | NAME "(" [ expr { "," expr } ] ")" | "(" expr ")"
#     NAME      = a letter or '_', then letters, digits, '_'
#     NUMBER    = decimal digits, or 0x and hex digits (up to 32 bits)
#     STRING    = "..." with \n \t \0 \\ \" for a newline, a tab, a zero
#                 byte, a backslash and a quote; its value is its address
#     HEXWORD   = eight uppercase hex digits: four bytes of code
#     // starts a comment that runs to the end of the line
#
# The code it writes (docs/OBJECT.md, "Calling convention"):
#   - A function keeps a frame, with s0 pointing at its top:
#         -4(s0)              the caller's s0
#         -8-4*i(s0)          slot i: a parameter, a local or a temporary
#         0(sp) ...           the ninth and later arguments of calls it makes
#     Slots are handed out as a stack while compiling: a `let` takes one
#     until its block ends, a temporary until it is used.
#   - An expression leaves its value in a0.  An operator saves its left
#     side in a temporary, computes the right side, and reloads the left
#     into a1.
#   - `*`, `/` and `%` are calls to __mul, __div and __rem (lib/rt.fam):
#     the CPU has no instructions for them.
#   - A string's bytes, and a zero byte, sit in the code where it is used,
#     behind a `jal a0` that jumps over them and so leaves their address.
#   - `return` jumps to the code at the function's end that drops the frame.
#     A function that runs off its end returns whatever is in a0.
#
# Tests.  If the source starts with the byte 0x01, that and the rest of its
# first line are not source: the line is the file's name, and the tests are
# wanted (`fam.sh cc --test`).  Each test block then becomes an init
# record, so it runs at startup, in order (lib/rt.fam has the functions):
#         __test_begin(name, file)
#         the block; a failed assert calls __test_fail(line) and jumps
#         to the end, as `return` does
#         __test_end()
# Otherwise test blocks are skipped.
#
# Built from this file by tools/s2fam0_fam.py into src/famc.fam0, which
# bin/fam0 turns into bin/famc.
#
# Memory and registers: see O_SETUP below, and after its source:
#   + 0x2000000         the compile stack, 64 KiB   (sp), for the parser
#   + 0x2010000         the locals in scope, 64 KiB: 12 bytes each, name
#                       start, name length, slot
# Variables, at these offsets from s4:
.equ V_LTOP,  -8        # the locals: next free entry
.equ V_LBASE, -12       # the locals: base
.equ V_CUR,   -16       # slots in use
.equ V_MAX,   -20       # the most slots in use at once in this function
.equ V_OUT,   -24       # the most stack arguments a call in it passes
.equ V_RET,   -28       # its last `return` jump, to patch (0: none); each
                        #   holds the address of the one before
.equ V_PRO,   -32       # where its first three instructions are
.equ V_TEST,  -36       # 1 while compiling a test block
.equ V_MODE,  -40       # 1 if tests are wanted
.equ V_FILE,  -44       # then: where the file's name starts
.equ V_FEND,  -48       #       and ends
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

# EMIT word -- append an instruction to the code.
.macro EMIT word
    li      a0, \word
    CALL    o_word
.endm

# EXPECT ch -- read a token; it must be the punctuation character ch.
.macro EXPECT ch
    CALL    lex
    li      t2, 3
    bne     a6, t2, err_syntax
    li      t2, 1
    bne     a1, t2, err_syntax
    lbu     t2, 0(a0)
    li      t3, \ch
    bne     t2, t3, err_syntax
.endm

# BINOP tok, prec, w1, w2 -- in binop: if the token (packed in a2) is tok,
#   return its precedence and its one or two instructions.
.macro BINOP tok, prec, w1, w2
    li      t2, \tok
    bne     a2, t2, .Lbo_\@
    li      a4, \prec
    li      a5, \w1
    li      a7, \w2
    RET
.Lbo_\@:
.endm

_start:
    O_SETUP
    li      t0, 0x2000000
    add     t0, s0, t0
    li      t1, 0x10000
    add     sp, t0, t1                  # the compile stack: top
    sw      sp, V_LBASE(s4)             # the locals, after it
    sw      zero, V_MODE(s4)
    bgeu    s1, s2, 3f                  # 0x01 and the file's name first?
    lbu     t2, 0(s1)
    li      t3, 1
    bne     t2, t3, 3f
    sw      t3, V_MODE(s4)
    addi    s1, s1, 1
    sw      s1, V_FILE(s4)
1:  bgeu    s1, s2, 2f
    lbu     t2, 0(s1)
    li      t3, 0x0A
    beq     t2, t3, 2f
    addi    s1, s1, 1
    j       1b
2:  sw      s1, V_FEND(s4)
    addi    s1, s1, 1
3:

    # function = "fn" NAME "(" [ NAME { "," NAME } ] ")" block
.Lf_next:
    CALL    lex
    beqz    a6, .Lf_done
    li      t2, 1
    bne     a6, t2, err_syntax
    CALL    pack_tok
    bnez    a3, err_syntax
    li      t2, 't' | 'e'<<8 | 's'<<16 | 't'<<24
    beq     a2, t2, .Lt_test
    li      t2, 'f' | 'n'<<8
    bne     a2, t2, err_syntax
    CALL    lex                         # the name
    CALL    chk_ident
    CALL    o_define
    beqz    a2, err_dup
    CALL    fn_begin
    EXPECT  0x28                        # (
    CALL    lex
    li      t2, 3
    bne     a6, t2, .Lf_param
    lbu     t2, 0(a0)
    li      t3, ')'
    beq     t2, t3, .Lf_body
    j       err_syntax
.Lf_param:                              # parameter k goes to slot k
    CALL    chk_ident
    CALL    slot_new
    CALL    l_add
    li      t2, 8
    bgeu    a3, t2, 1f
    addi    a2, a3, 10                  # from its register, a0 to a7
    CALL    e_sw_slot
    j       2f
1:  addi    t2, a3, -8                  # or from the caller's frame:
    slli    t2, t2, 22                  # lw t2, 4*(k-8)(s0)
    li      a0, 0x00042383
    or      a0, a0, t2
    CALL    o_word
    li      a2, 7
    CALL    e_sw_slot
2:  CALL    lex
    li      t2, 3
    bne     a6, t2, err_syntax
    lbu     t2, 0(a0)
    li      t3, ')'
    beq     t2, t3, .Lf_body
    li      t3, ','
    bne     t2, t3, err_syntax
    CALL    lex
    j       .Lf_param
.Lf_body:
    CALL    block
    lw      a0, V_RET(s4)               # every `return` jumps here
1:  beqz    a0, 2f
    lw      a4, 0(a0)
    mv      a1, s9
    CALL    patch_j
    mv      a0, a4
    j       1b
2:  lw      t2, V_TEST(s4)
    beqz    t2, 3f
    li      t3, '_' | '_'<<8 | 't'<<16 | 'e'<<24
    li      t4, 's' | 't'<<8 | '_'<<16 | 'e'<<24
    li      t5, 'n' | 'd'<<8
    li      a1, 10
    CALL    call_rt                     # __test_end()
3:  EMIT    0x00040113                  # mv sp, s0
    EMIT    0xFFC12403                  # lw s0, -4(sp)
    lw      t2, V_MAX(s4)               # the frame: the saved s0, the slots
    lw      t3, V_OUT(s4)               # and the outgoing arguments, rounded
    add     t2, t2, t3                  # up to 16 bytes
    slli    t2, t2, 2
    addi    t2, t2, 4 + 15
    andi    t2, t2, -16
    li      t3, 2032
    bgtu    t2, t3, err_locals
    lw      a0, V_PRO(s4)
    sub     t3, zero, t2                # addi sp, sp, -frame
    slli    t3, t3, 20
    li      t4, 0x00010113
    or      t3, t3, t4
    sw      t3, 0(a0)
    addi    t3, t2, -4                  # sw s0, frame-4(sp)
    srli    t4, t3, 5
    slli    t4, t4, 25
    andi    t3, t3, 0x1F
    slli    t3, t3, 7
    or      t3, t3, t4
    li      t4, 0x00812023
    or      t3, t3, t4
    sw      t3, 4(a0)
    slli    t3, t2, 20                  # addi s0, sp, frame
    li      t4, 0x00010413
    or      t3, t3, t4
    sw      t3, 8(a0)
    CALL    o_end
    j       .Lf_next
.Lf_done:
    CALL    o_write
    j       exit_ok

    # test = "test" STRING block
.Lt_test:
    CALL    lex                         # the name
    li      t2, 4
    bne     a6, t2, err_syntax
    lw      t2, V_MODE(s4)
    beqz    t2, .Lt_skip
    addi    sp, sp, -8
    sw      a0, 0(sp)
    sw      a1, 4(sp)
    CALL    o_init
    CALL    fn_begin
    li      t2, 1
    sw      t2, V_TEST(s4)
    lw      a4, V_FILE(s4)              # __test_begin(name, file)
    lw      a5, V_FEND(s4)
    CALL    e_string
    EMIT    0x00050593                  # mv a1, a0
    lw      a4, 0(sp)
    lw      a5, 4(sp)
    addi    sp, sp, 8
    add     a5, a4, a5
    addi    a4, a4, 1                   # inside its quotes
    addi    a5, a5, -1
    CALL    e_string
    li      t3, '_' | '_'<<8 | 't'<<16 | 'e'<<24
    li      t4, 's' | 't'<<8 | '_'<<16 | 'b'<<24
    li      t5, 'e' | 'g'<<8 | 'i'<<16 | 'n'<<24
    li      a1, 12
    CALL    call_rt
    j       .Lf_body
.Lt_skip:                               # tests not wanted: past its block
    EXPECT  0x7B                        # {
    li      a4, 1                       # how many { are open
1:  CALL    lex
    beqz    a6, err_syntax
    li      t2, 3
    bne     a6, t2, 1b
    li      t2, 1
    bne     a1, t2, 1b
    lbu     t2, 0(a0)
    li      t3, '{'
    bne     t2, t3, 2f
    addi    a4, a4, 1
    j       1b
2:  li      t3, '}'
    bne     t2, t3, 1b
    addi    a4, a4, -1
    bnez    a4, 1b
    j       .Lf_next

# fn_begin -- start the code of a function or test: nothing in scope, no
#   slots, and room for the three instructions that make the frame, filled
#   in at the end.
fn_begin:
    lw      t2, V_LBASE(s4)
    sw      t2, V_LTOP(s4)
    sw      zero, V_CUR(s4)
    sw      zero, V_MAX(s4)
    sw      zero, V_OUT(s4)
    sw      zero, V_RET(s4)
    sw      zero, V_TEST(s4)
    sw      s9, V_PRO(s4)
    EMIT    0x13
    EMIT    0x13
    EMIT    0x13
    RET

# call_rt -- t3/t4/t5 = a runtime function's name, as up to 12 characters
#   in three words, a1 = its length; append a call to it.
call_rt:
    addi    sp, sp, -12
    sw      t3, 0(sp)
    sw      t4, 4(sp)
    sw      t5, 8(sp)
    mv      a0, sp
    CALL    o_call
    addi    sp, sp, 12
    RET

# block -- "{" { statement } "}".  The locals and slots of its `let`s go
#   when it ends.  Compile stack: [locals top, slots in use].
block:
    CALL    chk_deep
    EXPECT  0x7B                        # {
    addi    sp, sp, -8
    lw      t2, V_LTOP(s4)
    sw      t2, 0(sp)
    lw      t2, V_CUR(s4)
    sw      t2, 4(sp)
1:  CALL    lex
    li      t2, 3
    bne     a6, t2, 2f
    lbu     t2, 0(a0)
    li      t3, '}'
    beq     t2, t3, 3f
2:  mv      s1, a0                      # not the end: a statement
    CALL    stmt
    j       1b
3:  lw      t2, 0(sp)
    sw      t2, V_LTOP(s4)
    lw      t2, 4(sp)
    sw      t2, V_CUR(s4)
    addi    sp, sp, 8
    RET

# stmt -- one statement.
stmt:
    CALL    chk_deep
    CALL    lex
    li      t2, 1
    bne     a6, t2, .Ls_expr
    CALL    pack_tok
    li      t2, 'l' | 'e'<<8 | 't'<<16
    bne     a2, t2, 1f
    beqz    a3, .Ls_let
1:  li      t2, 'i' | 'f'<<8
    bne     a2, t2, 1f
    beqz    a3, .Ls_if
1:  li      t2, 'a' | 's'<<8 | 'm'<<16
    bne     a2, t2, 1f
    beqz    a3, .Ls_asm
1:  li      t2, 'w' | 'h'<<8 | 'i'<<16 | 'l'<<24
    bne     a2, t2, 1f
    li      t2, 'e'
    beq     a3, t2, .Ls_while
1:  li      t2, 'r' | 'e'<<8 | 't'<<16 | 'u'<<24
    bne     a2, t2, 1f
    li      t2, 'r' | 'n'<<8
    beq     a3, t2, .Ls_return
1:  li      t2, 'a' | 's'<<8 | 's'<<16 | 'e'<<24
    bne     a2, t2, 1f
    li      t2, 'r' | 't'<<8
    beq     a3, t2, .Ls_assert
1:  addi    sp, sp, -12                 # a name: `NAME = ...` or an
    sw      a0, 0(sp)                   # expression.  Look one token on.
    sw      a1, 4(sp)
    sw      s3, 8(sp)
    CALL    lex
    li      t2, 3
    bne     a6, t2, 2f
    li      t2, 1
    bne     a1, t2, 2f
    lbu     t2, 0(a0)
    li      t3, '='
    bne     t2, t3, 2f
    lw      a0, 0(sp)                   # NAME = expr ;
    lw      a1, 4(sp)
    li      a6, 1
    CALL    chk_ident
    CALL    l_find
    sw      a3, 0(sp)
    li      a4, 1
    CALL    expr
    EXPECT  0x3B                        # ;
    lw      a3, 0(sp)
    addi    sp, sp, 12
    li      a2, 10
    j       e_sw_slot                   # (its RET returns for us)
2:  lw      s1, 0(sp)                   # an expression: back to the name
    lw      s3, 8(sp)
    addi    sp, sp, 12
    j       1f
.Ls_expr:
    mv      s1, a0
1:  li      a4, 1
    CALL    expr
    EXPECT  0x3B                        # ;
    RET

.Ls_let:                                # let NAME = expr ;
    CALL    lex
    CALL    chk_ident
    addi    sp, sp, -8
    sw      a0, 0(sp)
    sw      a1, 4(sp)
    EXPECT  0x3D                        # =
    li      a4, 1
    CALL    expr
    EXPECT  0x3B                        # ;
    lw      a0, 0(sp)                   # in scope from here on, not in
    lw      a1, 4(sp)                   # its own expression
    addi    sp, sp, 8
    CALL    slot_new
    CALL    l_add
    li      a2, 10
    j       e_sw_slot

.Ls_if:                                 # if expr block [ else ... ]
    li      a4, 1
    CALL    expr
    EMIT    0x00051463                  # bnez a0, +8
    CALL    e_jph                       # j <past the block>
    addi    sp, sp, -4
    sw      a0, 0(sp)
    CALL    block
    CALL    lex
    li      t2, 1
    bne     a6, t2, 1f
    CALL    pack_tok
    li      t2, 'e' | 'l'<<8 | 's'<<16 | 'e'<<24
    bne     a2, t2, 1f
    beqz    a3, 2f
1:  mv      s1, a0                      # no else
    j       4f
2:  CALL    e_jph                       # j <past the else part>
    mv      a4, a0
    lw      a0, 0(sp)
    sw      a4, 0(sp)
    mv      a1, s9
    CALL    patch_j
    CALL    lex                         # else if ..., or else { ... }
    mv      s1, a0
    li      t2, 1
    bne     a6, t2, 3f
    CALL    pack_tok
    li      t2, 'i' | 'f'<<8
    bne     a2, t2, 3f
    bnez    a3, 3f
    CALL    stmt
    j       4f
3:  CALL    block
4:  lw      a0, 0(sp)
    addi    sp, sp, 4
    mv      a1, s9
    j       patch_j

.Ls_while:                              # while expr block
    addi    sp, sp, -8
    sw      s9, 0(sp)
    li      a4, 1
    CALL    expr
    EMIT    0x00051463                  # bnez a0, +8
    CALL    e_jph                       # j <past the block>
    sw      a0, 4(sp)
    CALL    block
    CALL    e_jph                       # j <the condition>
    lw      a1, 0(sp)
    CALL    patch_j
    lw      a0, 4(sp)
    addi    sp, sp, 8
    mv      a1, s9
    j       patch_j

.Ls_return:                             # return [ expr ] ;
    CALL    lex
    li      t2, 3
    bne     a6, t2, 1f
    lbu     t2, 0(a0)
    li      t3, ';'
    bne     t2, t3, 1f
    EMIT    0x00000513                  # li a0, 0
    j       2f
1:  mv      s1, a0
    li      a4, 1
    CALL    expr
    EXPECT  0x3B                        # ;
2:  CALL    e_jph                       # j <the end>, patched there
    lw      t2, V_RET(s4)
    sw      t2, 0(a0)
    sw      a0, V_RET(s4)
    RET

.Ls_assert:                             # assert expr ;
    lw      t2, V_TEST(s4)
    beqz    t2, err_assert
    addi    sp, sp, -4
    sw      s3, 0(sp)                   # its line
    li      a4, 1
    CALL    expr
    EXPECT  0x3B                        # ;
    EMIT    0x00050463                  # beqz a0, +8
    CALL    e_jph                       # j <past the failure>
    lw      a3, 0(sp)
    sw      a0, 0(sp)
    CALL    emit_li_a0                  # __test_fail(line)
    li      t3, '_' | '_'<<8 | 't'<<16 | 'e'<<24
    li      t4, 's' | 't'<<8 | '_'<<16 | 'f'<<24
    li      t5, 'a' | 'i'<<8 | 'l'<<16
    li      a1, 11
    CALL    call_rt
    CALL    e_jph                       # j <the end>, as `return` does
    lw      t2, V_RET(s4)
    sw      t2, 0(a0)
    sw      a0, V_RET(s4)
    lw      a0, 0(sp)
    addi    sp, sp, 4
    mv      a1, s9
    j       patch_j

.Ls_asm:                                # asm { HEXWORD ... }
    EXPECT  0x7B                        # {
1:  CALL    lex
    beqz    a6, err_syntax
    li      t2, 3
    bne     a6, t2, 2f
    lbu     t2, 0(a0)
    li      t3, '}'
    beq     t2, t3, 3f
2:  CALL    hex_word
    CALL    o_word
    j       1b
3:  RET

# expr -- a4 = the lowest precedence of operator to take (1: any).  Write
#   the code that leaves the expression's value in a0.
#   Compile stack: [a4, instruction 1 or the jump to patch, instruction 2,
#   the operator's precedence].
expr:
    CALL    chk_deep
    addi    sp, sp, -16
    sw      a4, 0(sp)
    CALL    unary
.Le_next:
    CALL    lex
    CALL    binop
    beqz    a4, .Le_done
    lw      t2, 0(sp)
    bltu    a4, t2, .Le_done
    sw      a4, 12(sp)
    li      t2, 3
    bgeu    a4, t2, .Le_arith
    li      t2, 1                       # || and && skip their right side
    bne     a4, t2, 1f
    EMIT    0x00A03533                  # ||: snez a0, a0
    EMIT    0x00050463                  #     beqz a0, +8
    j       2f
1:  EMIT    0x00051463                  # &&: bnez a0, +8
2:  CALL    e_jph                       # j <past the right side>
    sw      a0, 4(sp)
    lw      a4, 12(sp)
    addi    a4, a4, 1
    CALL    expr
    EMIT    0x00A03533                  # snez a0, a0
    lw      a0, 4(sp)
    mv      a1, s9
    CALL    patch_j
    j       .Le_next
.Le_arith:
    sw      a5, 4(sp)
    sw      a7, 8(sp)
    CALL    slot_new                    # the left side waits in a temporary
    li      a2, 10
    CALL    e_sw_slot
    lw      a4, 12(sp)
    addi    a4, a4, 1
    CALL    expr
    lw      t2, 4(sp)
    li      t3, 16
    bltu    t2, t3, .Le_call
    li      a3, 1
    CALL    slot_drop                   # a3 = the temporary
    li      a2, 11
    CALL    e_lw_slot                   # the left side, into a1
    lw      a0, 4(sp)
    CALL    o_word
    lw      a0, 8(sp)
    beqz    a0, .Le_next
    CALL    o_word
    j       .Le_next
.Le_call:                               # * / %: a call, left side in a0 and
    EMIT    0x00050593                  # right in a1.  mv a1, a0
    li      a3, 1
    CALL    slot_drop
    li      a2, 10
    CALL    e_lw_slot
    lw      t2, 4(sp)
    li      t3, '_' | '_'<<8 | 'm'<<16 | 'u'<<24
    li      t4, 'l'
    li      t5, 1
    beq     t2, t5, 1f
    li      t3, '_' | '_'<<8 | 'd'<<16 | 'i'<<24
    li      t4, 'v'
    li      t5, 2
    beq     t2, t5, 1f
    li      t3, '_' | '_'<<8 | 'r'<<16 | 'e'<<24
    li      t4, 'm'
1:  li      t5, 0
    li      a1, 5
    CALL    call_rt
    j       .Le_next
.Le_done:
    mv      s1, a0                      # not ours: leave the token unread
    addi    sp, sp, 16
    RET

# binop -- a0/a1/a6 = a token; a4 = its precedence as a binary operator
#   (0: it is not one), a5/a7 = its instructions, which compute a0 from
#   a1 (the left side) and a0 (the right); a7 = 0 if there is only one.
#   For * / % a5 is 1, 2, 3: they are calls.
#   Clobbers a2, a3, t2, t3, t4.
binop:
    li      a4, 0
    li      t2, 3
    bne     a6, t2, 1f
    CALL    pack_tok
    BINOP   0x7C7C, 1, 0, 0                     # ||
    BINOP   0x2626, 2, 0, 0                     # &&
    BINOP   0x3D3D, 3, 0x40A58533, 0x00153513   # ==  sub a0,a1,a0 ; seqz a0,a0
    BINOP   0x3D21, 3, 0x40A58533, 0x00A03533   # !=  sub a0,a1,a0 ; snez a0,a0
    BINOP   0x3C,   3, 0x00A5A533, 0            # <   slt a0,a1,a0
    BINOP   0x3E,   3, 0x00B52533, 0            # >   slt a0,a0,a1
    BINOP   0x3D3C, 3, 0x00B52533, 0x00154513   # <=  slt a0,a0,a1 ; xori a0,a0,1
    BINOP   0x3D3E, 3, 0x00A5A533, 0x00154513   # >=  slt a0,a1,a0 ; xori a0,a0,1
    BINOP   0x7C,   4, 0x00A5E533, 0            # |   or  a0,a1,a0
    BINOP   0x5E,   5, 0x00A5C533, 0            # ^   xor a0,a1,a0
    BINOP   0x26,   6, 0x00A5F533, 0            # &   and a0,a1,a0
    BINOP   0x3C3C, 7, 0x00A59533, 0            # <<  sll a0,a1,a0
    BINOP   0x3E3E, 7, 0x40A5D533, 0            # >>  sra a0,a1,a0
    BINOP   0x2B,   8, 0x00A58533, 0            # +   add a0,a1,a0
    BINOP   0x2D,   8, 0x40A58533, 0            # -   sub a0,a1,a0
    BINOP   0x2A,   9, 1, 0                     # *   __mul
    BINOP   0x2F,   9, 2, 0                     # /   __div
    BINOP   0x25,   9, 3, 0                     # %   __rem
1:  RET

# unary -- ( "-" | "!" | "~" ) unary | NUMBER | STRING | NAME | a call
#   | "(" expr ")"
unary:
    CALL    chk_deep
    CALL    lex
    li      t2, 2
    beq     a6, t2, .Lu_num
    li      t2, 4
    beq     a6, t2, .Lu_str
    li      t2, 1
    beq     a6, t2, .Lu_name
    beqz    a6, err_syntax
    li      t2, 1
    bne     a1, t2, err_syntax
    lbu     t2, 0(a0)
    li      t3, '('
    beq     t2, t3, .Lu_paren
    li      t3, '-'
    bne     t2, t3, 1f
    CALL    unary
    EMIT    0x40A00533                  # neg a0, a0
    RET
1:  li      t3, '!'
    bne     t2, t3, 1f
    CALL    unary
    EMIT    0x00153513                  # seqz a0, a0
    RET
1:  li      t3, '~'
    bne     t2, t3, err_syntax
    CALL    unary
    EMIT    0xFFF54513                  # not a0, a0
    RET
.Lu_paren:
    li      a4, 1
    CALL    expr
    EXPECT  0x29                        # )
    RET
.Lu_num:
    CALL    parse_num
    j       emit_li_a0                  # (its RET returns for us)
.Lu_str:
    addi    a4, a0, 1                   # inside its quotes
    add     a5, a0, a1
    addi    a5, a5, -1
    j       e_string                    # (its RET returns for us)
.Lu_name:
    CALL    chk_ident
    addi    sp, sp, -12                 # [name start, name length, arguments]
    sw      a0, 0(sp)
    sw      a1, 4(sp)
    CALL    lex                         # a call if ( follows
    li      t2, 3
    bne     a6, t2, 1f
    lbu     t2, 0(a0)
    li      t3, '('
    beq     t2, t3, .Lu_call
1:  mv      s1, a0                      # else a local
    lw      a0, 0(sp)
    lw      a1, 4(sp)
    addi    sp, sp, 12
    CALL    l_find
    li      a2, 10
    j       e_lw_slot

    # A call: each argument's value into a temporary; then the first eight
    # into a0 to a7 and the rest into the frame's low end; then the call.
.Lu_call:
    sw      zero, 8(sp)
    CALL    lex
    li      t2, 3
    bne     a6, t2, 1f
    lbu     t2, 0(a0)
    li      t3, ')'
    beq     t2, t3, 3f
1:  mv      s1, a0
2:  li      a4, 1
    CALL    expr
    CALL    slot_new
    li      a2, 10
    CALL    e_sw_slot
    lw      t2, 8(sp)
    addi    t2, t2, 1
    sw      t2, 8(sp)
    CALL    lex
    li      t2, 3
    bne     a6, t2, err_syntax
    lbu     t2, 0(a0)
    li      t3, ','
    beq     t2, t3, 2b
    li      t3, ')'
    bne     t2, t3, err_syntax
3:  lw      a3, 8(sp)
    mv      a7, a3                      # a7 = how many
    CALL    slot_drop
    mv      a6, a3                      # a6 = the first one's slot
    li      a5, 0                       # a5 = which
4:  bgeu    a5, a7, 6f
    add     a3, a6, a5
    li      t2, 8
    bgeu    a5, t2, 5f
    addi    a2, a5, 10
    CALL    e_lw_slot                   # lw a<k>, slot
    j       7f
5:  li      a2, 7
    CALL    e_lw_slot                   # lw t2, slot
    addi    t2, a5, -8                  # sw t2, 4*(k-8)(sp)
    slli    t2, t2, 2
    srli    t3, t2, 5
    slli    t3, t3, 25
    andi    t2, t2, 0x1F
    slli    t2, t2, 7
    or      t2, t2, t3
    li      a0, 0x00712023
    or      a0, a0, t2
    CALL    o_word
7:  addi    a5, a5, 1
    j       4b
6:  addi    t2, a7, -8                  # note the most stack arguments
    lw      t3, V_OUT(s4)
    ble     t2, t3, 8f
    sw      t2, V_OUT(s4)
8:  lw      a0, 0(sp)
    lw      a1, 4(sp)
    addi    sp, sp, 12
    j       o_call

# e_string -- a4/a5 = the start and end of a string's text, as written
#   (with its \ escapes); append `jal a0, <past it>`, its bytes, a zero
#   byte, and zero bytes up to a whole word: code that leaves the string's
#   address in a0.  a6 = the word being filled, a7 = how many bytes it has.
e_string:
    li      a0, 0x56F                   # jal a0, 0
    CALL    o_word
    addi    sp, sp, -4
    addi    t2, s9, -4
    sw      t2, 0(sp)
    li      a6, 0
    li      a7, 0
1:  li      t3, 0
    bltu    a4, a5, 9f
    addi    a4, a5, 1                   # the text is done: the zero byte,
    j       4f                          # and this is the last time round
9:  lbu     t3, 0(a4)
    addi    a4, a4, 1
    li      t4, 0x5C                    # a backslash: the next says what
    bne     t3, t4, 4f
    lbu     t3, 0(a4)
    addi    a4, a4, 1
    beq     t3, t4, 4f
    li      t4, '"'
    beq     t3, t4, 4f
    li      t4, 'n'
    bne     t3, t4, 2f
    li      t3, 0x0A
    j       4f
2:  li      t4, 't'
    bne     t3, t4, 3f
    li      t3, 0x09
    j       4f
3:  li      t4, '0'
    bne     t3, t4, err_escape
    li      t3, 0
4:  slli    t4, a7, 3                   # the byte into the word
    sll     t4, t3, t4
    or      a6, a6, t4
    addi    a7, a7, 1
    li      t4, 4
    bltu    a7, t4, 5f
    mv      a0, a6
    CALL    o_word
    li      a6, 0
    li      a7, 0
5:  bleu    a4, a5, 1b
    beqz    a7, 8f
    mv      a0, a6
    CALL    o_word
8:  lw      a0, 0(sp)
    addi    sp, sp, 4
    mv      a1, s9
    li      a2, 0x56F
    j       patch_jal

# chk_deep -- error if the compile stack or the return ids are nearly
#   used up.  Clobbers t2.
chk_deep:
    li      t2, 0x2000000
    add     t2, s0, t2
    addi    t2, t2, 256
    bltu    sp, t2, err_deep
    addi    t2, s10, 256
    bltu    s11, t2, err_deep
    RET

# chk_ident -- a0/a1/a6 = a token; error unless it is a name and not a
#   keyword.  Clobbers a2, a3, t2, t3, t4.
chk_ident:
    li      t2, 1
    bne     a6, t2, err_syntax
    CALL    pack_tok
    li      t2, 'r' | 'e'<<8 | 't'<<16 | 'u'<<24
    bne     a2, t2, 1f
    li      t2, 'r' | 'n'<<8
    beq     a3, t2, err_syntax
1:  li      t2, 'a' | 's'<<8 | 's'<<16 | 'e'<<24
    bne     a2, t2, 1f
    li      t2, 'r' | 't'<<8
    beq     a3, t2, err_syntax
1:  li      t2, 'w' | 'h'<<8 | 'i'<<16 | 'l'<<24
    bne     a2, t2, 1f
    li      t2, 'e'
    beq     a3, t2, err_syntax
1:  bnez    a3, 2f
    li      t2, 'f' | 'n'<<8
    beq     a2, t2, err_syntax
    li      t2, 'i' | 'f'<<8
    beq     a2, t2, err_syntax
    li      t2, 'l' | 'e'<<8 | 't'<<16
    beq     a2, t2, err_syntax
    li      t2, 'a' | 's'<<8 | 'm'<<16
    beq     a2, t2, err_syntax
    li      t2, 'e' | 'l'<<8 | 's'<<16 | 'e'<<24
    beq     a2, t2, err_syntax
2:  RET

# slot_new -- take the next slot: a3.  Clobbers t2, t3.
slot_new:
    lw      a3, V_CUR(s4)
    addi    t2, a3, 1
    li      t3, 500
    bgtu    t2, t3, err_locals
    sw      t2, V_CUR(s4)
    lw      t3, V_MAX(s4)
    bgeu    t3, t2, 1f
    sw      t2, V_MAX(s4)
1:  RET

# slot_drop -- a3 = how many; give back the last that many slots: a3 = the
#   lowest of them.  Clobbers t2.
slot_drop:
    lw      t2, V_CUR(s4)
    sub     a3, t2, a3
    sw      a3, V_CUR(s4)
    RET

# l_add -- a0/a1 = name, a3 = slot; put the local in scope.
#   Clobbers t2, t3, t4.
l_add:
    lw      t2, V_LTOP(s4)
    lw      t3, V_LBASE(s4)
    li      t4, 0x10000
    add     t3, t3, t4
    addi    t4, t2, 12
    bgtu    t4, t3, err_big
    sw      a0, 0(t2)
    sw      a1, 4(t2)
    sw      a3, 8(t2)
    sw      t4, V_LTOP(s4)
    RET

# l_find -- a0/a1 = name; a3 = the slot of the local of that name, the
#   latest if several.  None is an error.  Clobbers a2, t2-t6.
l_find:
    lw      a2, V_LTOP(s4)
1:  lw      t2, V_LBASE(s4)
    bgeu    t2, a2, err_unknown
    addi    a2, a2, -12
    lw      t2, 4(a2)
    bne     t2, a1, 1b
    lw      t3, 0(a2)
    li      t4, 0
2:  bgeu    t4, a1, 3f
    add     t5, t3, t4
    lbu     t5, 0(t5)
    add     t6, a0, t4
    lbu     t6, 0(t6)
    bne     t5, t6, 1b
    addi    t4, t4, 1
    j       2b
3:  lw      a3, 8(a2)
    RET

# e_sw_slot -- a2 = a register's number, a3 = slot; append
#   `sw <register>, <slot>(s0)`.  Clobbers a0, t2, t3.
e_sw_slot:
    slli    t2, a3, 2
    addi    t2, t2, 8
    sub     t2, zero, t2                # the slot's offset: -8 - 4*slot
    srli    t3, t2, 5
    andi    t3, t3, 0x7F
    slli    t3, t3, 25
    andi    t2, t2, 0x1F
    slli    t2, t2, 7
    or      t3, t3, t2
    slli    t2, a2, 20
    or      t3, t3, t2
    li      a0, 0x00042023              # sw x0, 0(s0)
    or      a0, a0, t3
    j       o_word                      # (its RET returns for us)

# e_lw_slot -- a2 = a register's number, a3 = slot; append
#   `lw <register>, <slot>(s0)`.  Clobbers a0, t2, t3.
e_lw_slot:
    slli    t2, a3, 2
    addi    t2, t2, 8
    sub     t2, zero, t2
    slli    t2, t2, 20
    slli    t3, a2, 7
    or      t2, t2, t3
    li      a0, 0x00042003              # lw x0, 0(s0)
    or      a0, a0, t2
    j       o_word

# e_jph -- append a jump to be patched (patch_j): a0 = where it is.
#   Clobbers t2.
e_jph:
    li      a0, 0x6F                    # jal x0, 0
    CALL    o_word
    addi    a0, s9, -4
    RET

# patch_j -- a0 = where a jump is, a1 = where it must go; make it
#   `jal x0, <there>`.  Clobbers a2, t2, t3, t4.
# patch_jal -- the same with a2 = the jal's low 12 bits (its register).
patch_j:
    li      a2, 0x6F
patch_jal:
    sub     t2, a1, a0
    srai    t3, t2, 20                  # jal reaches 1 MiB either way
    beqz    t3, 1f
    li      t4, -1
    bne     t3, t4, err_far
1:  srli    t3, t2, 20                  # offset bit 20 -> bit 31
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
    or      t3, t3, a2
    sw      t3, 0(a0)
    RET

# cls -- t2 = a byte; t5 = its class: 2 a digit, 1 a letter or '_', 0 other.
#   Clobbers t3.
cls:
    li      t5, 2
    li      t3, '0'
    blt     t2, t3, 1f
    li      t3, '9'
    ble     t2, t3, 2f
    li      t5, 1
    li      t3, 'A'
    blt     t2, t3, 1f
    li      t3, 'Z'
    ble     t2, t3, 2f
    li      t3, '_'
    beq     t2, t3, 2f
    li      t3, 'a'
    blt     t2, t3, 1f
    li      t3, 'z'
    ble     t2, t3, 2f
1:  li      t5, 0
2:  RET

# lex -- the next token: a0 = start, a1 = length, a6 = kind (0 the end of
#   the source, 1 a name, 2 a number, 3 punctuation: one character, or one
#   of == != <= >= << >> && ||, 4 a string, quotes and all), s1 moved past
#   it, s3 = its line.
#   Clobbers t2-t5.  To leave a token unread: mv s1, a0.
lex:
1:  bgeu    s1, s2, 8f
    lbu     t2, 0(s1)
    li      t3, 0x0A
    bne     t2, t3, 2f
    addi    s3, s3, 1
2:  li      t3, ' '
    bgtu    t2, t3, 3f
    addi    s1, s1, 1
    j       1b
3:  li      t3, '/'                     # a // comment?
    bne     t2, t3, 5f
    addi    t4, s1, 1
    bgeu    t4, s2, 5f
    lbu     t4, 0(t4)
    bne     t4, t3, 5f
4:  addi    s1, s1, 1                   # to the end of the line
    bgeu    s1, s2, 8f
    lbu     t2, 0(s1)
    li      t3, 0x0A
    bne     t2, t3, 4b
    j       1b
5:  mv      a0, s1
    CALL    cls
    beqz    t5, 7f
    mv      a6, t5                      # a number or a name: while letters,
6:  addi    s1, s1, 1                   # digits and '_' follow
    bgeu    s1, s2, 9f
    lbu     t2, 0(s1)
    CALL    cls
    bnez    t5, 6b
    j       9f
7:  li      t3, '"'
    bne     t2, t3, 14f
    li      a6, 4                       # a string: to its closing quote, on
12: addi    s1, s1, 1                   # this line
    bgeu    s1, s2, err_string
    lbu     t2, 0(s1)
    li      t3, 0x0A
    beq     t2, t3, err_string
    li      t3, 0x5C                    # a backslash takes the next with it
    bne     t2, t3, 13f
    addi    s1, s1, 1
    bgeu    s1, s2, err_string
    lbu     t2, 0(s1)
    li      t3, 0x0A
    beq     t2, t3, err_string
    j       12b
13: li      t3, '"'
    bne     t2, t3, 12b
    addi    s1, s1, 1
    j       9f
14: li      a6, 3
    addi    s1, s1, 1
    bgeu    s1, s2, 9f
    lbu     t3, 0(s1)                   # the character after it
    li      t4, '='
    bne     t3, t4, 10f
    beq     t2, t4, 11f                 # == != <= >=
    li      t4, '!'
    beq     t2, t4, 11f
    li      t4, '<'
    beq     t2, t4, 11f
    li      t4, '>'
    beq     t2, t4, 11f
    j       9f
10: bne     t3, t2, 9f                  # << >> && ||
    li      t4, '<'
    beq     t2, t4, 11f
    li      t4, '>'
    beq     t2, t4, 11f
    li      t4, '&'
    beq     t2, t4, 11f
    li      t4, '|'
    bne     t2, t4, 9f
11: addi    s1, s1, 1
9:  sub     a1, s1, a0
    RET
8:  mv      a0, s1
    li      a1, 0
    li      a6, 0
    RET

# parse_num -- a0 = start, a1 = length of a number token; a3 = its value.
#   Decimal digits, or 0x and one to eight hex digits.  Anything else, or
#   over 32 bits, is an error.  Clobbers t2, t3, t4.
parse_num:
    li      a3, 0
    li      t2, 2
    bleu    a1, t2, .Lpn_dec
    lbu     t3, 1(a0)
    li      t4, 'x'
    bne     t3, t4, .Lpn_dec
    lbu     t3, 0(a0)
    li      t4, '0'
    bne     t3, t4, err_number
    li      t3, 10
    bgtu    a1, t3, err_number
1:  bgeu    t2, a1, 4f                  # hex: t2 = index, from 2
    add     t3, a0, t2
    lbu     t3, 0(t3)
    addi    t4, t3, -'0'
    sltiu   t4, t4, 10
    beqz    t4, 2f
    addi    t3, t3, -'0'
    j       3f
2:  ori     t3, t3, 0x20                # a letter, either case
    addi    t3, t3, -'a'
    sltiu   t4, t3, 6
    beqz    t4, err_number
    addi    t3, t3, 10
3:  slli    a3, a3, 4
    or      a3, a3, t3
    addi    t2, t2, 1
    j       1b
.Lpn_dec:
    li      t2, 0
1:  bgeu    t2, a1, 4f
    add     t3, a0, t2
    lbu     t3, 0(t3)
    addi    t3, t3, -'0'
    li      t4, 10
    bgeu    t3, t4, err_number
    li      t4, 0x1999999A              # 10 times this would not fit
    bgeu    a3, t4, err_number
    slli    t4, a3, 3
    slli    a3, a3, 1
    add     a3, a3, t4                  # a3 * 10
    add     t4, a3, t3
    bltu    t4, a3, err_number
    mv      a3, t4
    addi    t2, t2, 1
    j       1b
4:  RET

# emit_li_a0 -- a3 = value; append the code that loads it into a0: one
#   `addi a0,zero,v` if it fits 12 signed bits, else `lui` and `addi`.
emit_li_a0:
    li      t2, -2048
    blt     a3, t2, 1f
    li      t2, 2047
    bgt     a3, t2, 1f
    slli    a0, a3, 20
    li      t2, 0x513                   # addi a0, zero, 0
    or      a0, a0, t2
    j       o_word
1:  li      t2, 0x800
    add     t2, a3, t2
    srli    t2, t2, 12
    slli    t2, t2, 12                  # the upper 20 bits, rounded for addi
    li      t3, 0x537                   # lui a0, 0
    or      a0, t2, t3
    CALL    o_word
    slli    a0, a3, 20
    li      t3, 0x50513                 # addi a0, a0, 0
    or      a0, a0, t3
    j       o_word

# --- errors: "famc: line N: <what>", then exit 1 ---------------------------

err_pfx:
    # say "famc: "
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'c'<<24
    CALL    uput4
    li      a0, ':' | ' '<<8
    CALL    uput4
    RET

# err_tok -- finish a message with the token a2/a3, then leave.
err_tok:
    mv      a0, a2
    mv      a1, a3
    CALL    uput_tok
    j       err_end

err_syntax:                             # a0/a1/a6 = the token
    mv      a2, a0
    mv      a3, a1
    CALL    err_line
    bnez    a6, 1f
    # say "unexpected end of file"
    li      a0, 'u' | 'n'<<8 | 'e'<<16 | 'x'<<24
    CALL    uput4
    li      a0, 'p' | 'e'<<8 | 'c'<<16 | 't'<<24
    CALL    uput4
    li      a0, 'e' | 'd'<<8 | ' '<<16 | 'e'<<24
    CALL    uput4
    li      a0, 'n' | 'd'<<8 | ' '<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'f' | ' '<<8 | 'f'<<16 | 'i'<<24
    CALL    uput4
    li      a0, 'l' | 'e'<<8
    CALL    uput4
    j       err_end
1:
    # say "unexpected "
    li      a0, 'u' | 'n'<<8 | 'e'<<16 | 'x'<<24
    CALL    uput4
    li      a0, 'p' | 'e'<<8 | 'c'<<16 | 't'<<24
    CALL    uput4
    li      a0, 'e' | 'd'<<8 | ' '<<16
    CALL    uput4
    j       err_tok
err_number:                             # a0/a1 = the token
    mv      a2, a0
    mv      a3, a1
    CALL    err_line
    # say "bad number "
    li      a0, 'b' | 'a'<<8 | 'd'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'n' | 'u'<<8 | 'm'<<16 | 'b'<<24
    CALL    uput4
    li      a0, 'e' | 'r'<<8 | ' '<<16
    CALL    uput4
    j       err_tok
err_token:                              # a0/a1 = the token
    mv      a2, a0
    mv      a3, a1
    CALL    err_line
    # say "bad hex word "
    li      a0, 'b' | 'a'<<8 | 'd'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'h' | 'e'<<8 | 'x'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'w' | 'o'<<8 | 'r'<<16 | 'd'<<24
    CALL    uput4
    li      a0, ' '
    CALL    uput4
    j       err_tok
err_dup:                                # a0/a1 = the name
    mv      a2, a0
    mv      a3, a1
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
err_unknown:                            # a0/a1 = the name
    mv      a2, a0
    mv      a3, a1
    CALL    err_line
    # say "unknown variable "
    li      a0, 'u' | 'n'<<8 | 'k'<<16 | 'n'<<24
    CALL    uput4
    li      a0, 'o' | 'w'<<8 | 'n'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'v' | 'a'<<8 | 'r'<<16 | 'i'<<24
    CALL    uput4
    li      a0, 'a' | 'b'<<8 | 'l'<<16 | 'e'<<24
    CALL    uput4
    li      a0, ' '
    CALL    uput4
    j       err_tok
err_string:
    CALL    err_line
    # say "string without its closing quote"
    li      a0, 's' | 't'<<8 | 'r'<<16 | 'i'<<24
    CALL    uput4
    li      a0, 'n' | 'g'<<8 | ' '<<16 | 'w'<<24
    CALL    uput4
    li      a0, 'i' | 't'<<8 | 'h'<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'u' | 't'<<8 | ' '<<16 | 'i'<<24
    CALL    uput4
    li      a0, 't' | 's'<<8 | ' '<<16 | 'c'<<24
    CALL    uput4
    li      a0, 'l' | 'o'<<8 | 's'<<16 | 'i'<<24
    CALL    uput4
    li      a0, 'n' | 'g'<<8 | ' '<<16 | 'q'<<24
    CALL    uput4
    li      a0, 'u' | 'o'<<8 | 't'<<16 | 'e'<<24
    CALL    uput4
    j       err_end
err_escape:
    CALL    err_line
    # say "unknown \\ in a string"
    li      a0, 'u' | 'n'<<8 | 'k'<<16 | 'n'<<24
    CALL    uput4
    li      a0, 'o' | 'w'<<8 | 'n'<<16 | ' '<<24
    CALL    uput4
    li      a0, 0x5C | ' '<<8 | 'i'<<16 | 'n'<<24
    CALL    uput4
    li      a0, ' ' | 'a'<<8 | ' '<<16 | 's'<<24
    CALL    uput4
    li      a0, 't' | 'r'<<8 | 'i'<<16 | 'n'<<24
    CALL    uput4
    li      a0, 'g'
    CALL    uput4
    j       err_end
err_assert:
    CALL    err_line
    # say "assert outside a test"
    li      a0, 'a' | 's'<<8 | 's'<<16 | 'e'<<24
    CALL    uput4
    li      a0, 'r' | 't'<<8 | ' '<<16 | 'o'<<24
    CALL    uput4
    li      a0, 'u' | 't'<<8 | 's'<<16 | 'i'<<24
    CALL    uput4
    li      a0, 'd' | 'e'<<8 | ' '<<16 | 'a'<<24
    CALL    uput4
    li      a0, ' ' | 't'<<8 | 'e'<<16 | 's'<<24
    CALL    uput4
    li      a0, 't'
    CALL    uput4
    j       err_end
err_locals:
    CALL    err_line
    # say "function needs too many locals"
    li      a0, 'f' | 'u'<<8 | 'n'<<16 | 'c'<<24
    CALL    uput4
    li      a0, 't' | 'i'<<8 | 'o'<<16 | 'n'<<24
    CALL    uput4
    li      a0, ' ' | 'n'<<8 | 'e'<<16 | 'e'<<24
    CALL    uput4
    li      a0, 'd' | 's'<<8 | ' '<<16 | 't'<<24
    CALL    uput4
    li      a0, 'o' | 'o'<<8 | ' '<<16 | 'm'<<24
    CALL    uput4
    li      a0, 'a' | 'n'<<8 | 'y'<<16 | ' '<<24
    CALL    uput4
    li      a0, 'l' | 'o'<<8 | 'c'<<16 | 'a'<<24
    CALL    uput4
    li      a0, 'l' | 's'<<8
    CALL    uput4
    j       err_end
err_deep:
    CALL    err_line
    # say "nested too deep"
    li      a0, 'n' | 'e'<<8 | 's'<<16 | 't'<<24
    CALL    uput4
    li      a0, 'e' | 'd'<<8 | ' '<<16 | 't'<<24
    CALL    uput4
    li      a0, 'o' | 'o'<<8 | ' '<<16 | 'd'<<24
    CALL    uput4
    li      a0, 'e' | 'e'<<8 | 'p'<<16
    CALL    uput4
    j       err_end
err_far:
    CALL    err_line
    # say "function too large"
    li      a0, 'f' | 'u'<<8 | 'n'<<16 | 'c'<<24
    CALL    uput4
    li      a0, 't' | 'i'<<8 | 'o'<<16 | 'n'<<24
    CALL    uput4
    li      a0, ' ' | 't'<<8 | 'o'<<16 | 'o'<<24
    CALL    uput4
    li      a0, ' ' | 'l'<<8 | 'a'<<16 | 'r'<<24
    CALL    uput4
    li      a0, 'g' | 'e'<<8
    CALL    uput4
    j       err_end
err_big:
    # say "famc: out of memory"
    li      a0, 'f' | 'a'<<8 | 'm'<<16 | 'c'<<24
    CALL    uput4
    li      a0, ':' | ' '<<8 | 'o'<<16 | 'u'<<24
    CALL    uput4
    li      a0, 't' | ' '<<8 | 'o'<<16 | 'f'<<24
    CALL    uput4
    li      a0, ' ' | 'm'<<8 | 'e'<<16 | 'm'<<24
    CALL    uput4
    li      a0, 'o' | 'r'<<8 | 'y'<<16
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

# o_define -- a0 = name start, a1 = length; start the record of that
#   function.  a2 = its symbol, or 0 if the name is defined already.
#   Clobbers a3, a4, t2-t6.
o_define:
    CALL    o_find
    bnez    a2, 1f
    li      a4, 1
    CALL    o_new
    j       3f
1:  lw      t2, 0(a2)
    beqz    t2, 2f
    li      a2, 0                       # defined already
    RET
2:  li      t2, 1                       # called earlier: now defined
    sw      t2, 0(a2)
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

# o_call -- a0 = name start, a1 = length; append a call to that function:
#   a call site and its 28 zero bytes of code.  Clobbers a2-a4, t2-t6.
o_call:
    CALL    o_find
    bnez    a2, 1f
    li      a4, 0                       # not seen yet: external until defined
    CALL    o_new
1:  addi    t2, s7, 8
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
