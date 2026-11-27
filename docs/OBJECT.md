# fam object format, version 1 (draft)

Status: a draft, implemented by `src/famc.S` (the front end) and
`src/famld.forth` (the linker and back end). Parts listed under "Open
questions" are the ones most likely to change.

## Pipeline

```
lib/rt.fam ──famc───▶ rt.o ─────┐
source.fam ──famc───▶ source.o ─┤
source.fam ──famc───▶ source.o ─┼─▶ famld ──▶ binary
lib/rtmain.fam ─famc▶ rtmain.o ─┘
```

- The **front end** (`famc`) compiles one source file to one object.
- An **object** is binary: machine code, the names it defines and calls,
  and where the calls are.
- The **linker** (`famld`) reads the objects one after another and writes
  the binary: every function the program uses, each placed before its
  first caller, with the calls and returns filled in.

Each of these is a program of its own, run under QEMU with its input on the
serial port and its output redirected to a file. `tools/famc` drives
them.

## Layout

Every field is a 32-bit little-endian word. The parts follow one another
with no gaps:

| Part | Size in bytes | Contents |
|---|---|---|
| Header | 28 | see below |
| Symbols | 20 each | the names the object defines or calls, and its init records |
| Call sites | 8 each | where the code calls a symbol |
| Code | a multiple of 4 | the code of all the records |
| Names | a multiple of 4 | the bytes of the names, zero-padded at the end |

### Header

| Word | Contents |
|---|---|
| 0 | the magic: the bytes `F` `A` `M` `O` |
| 1 | the version: 1 |
| 2 | the size of the whole object in bytes |
| 3 | the number of symbols |
| 4 | the number of call sites |
| 5 | the size of the code in bytes |
| 6 | the size of the names in bytes |

The size lets a reader take objects one after another from a stream. The
parts must add up to it exactly.

A file that does not start with the magic is not an object. A tool that
fails writes its error message where the object would go, so the build can
show it.

### Symbols

| Word | Contents |
|---|---|
| 0 | the kind: 0 external, 1 function, 2 init, 3 local function |
| 1 | where the name starts, as an offset into the names |
| 2 | the length of the name in bytes |
| 3 | where the record's code starts, as an offset into the code |
| 4 | the size of the record's code in bytes |

- A **function** defines its name for the whole link. Its code is the
  function's body.
- A **local function** is the same, but only this object's call sites can
  reach it. Other objects may have a function of the same name.
- An **external** is a name this object calls and does not define. Its code
  fields are zero.
- An **init** record is code run once at startup. It has no name; its name
  fields are zero.

A name is 1 to 255 bytes. Function names are global across the link. The
front end prefixes a function's module, `math.add`, and makes a function
that is not `pub` a local one.

### Call sites

| Word | Contents |
|---|---|
| 0 | where the call is, as an offset into the code |
| 1 | the index of the symbol called: a function, a local function or an external |

A call site is 28 bytes of code, all zero in the object. That is the size
of the call sequence the linker puts there. So the code in an object is laid out exactly as it will be in memory, and the
front end can resolve every branch from offsets in its own output.

Call sites are in ascending order of offset and do not overlap. Each lies
wholly inside one record's code.

An **id site** is an entry of the same table with the top bit of word 1
set. It is 8 bytes of code, all zero in the object, where the linker puts
the two instructions (`lui a0` and `addi a0`) that load the function's id:
see "Function ids".

### Code

All branches and data references inside a record are PC-relative and
already resolved. The only thing left for the linker is the calls.

A function's code does not include its return: the linker ends each
function with a jump to where returns are handled. A function that returns
early jumps to the end of its own code.

## An example

An object with two functions: `math.answer`, whose code is the one word
`1305A002` (`addi a0,zero,42`), and `main`, whose code is one call site,
for `math.answer`.

It is 124 bytes: the header, two symbols, one call site, 32 bytes of code
(4 for `math.answer`, 28 for the call site in `main`) and 16 bytes of
names.

## Linking

The linker's input is the objects, one after another, then an end marker
of four `0x04` bytes. It:

1. Reads and checks every object, in the order given.
2. Finds the functions the init records reach, directly or through other
   functions, and orders them so each is written before any function that
   calls it. A function nothing reaches is left out of the binary.
3. Breaks each cycle (functions that call each other) with a stub: one
   jump, written ahead of the cycle. Calls made before the real function
   is written go to the stub, and the jump is pointed at the function when
   it is written. A function calling itself needs no stub.
4. Writes those functions, then every init record, in input order, as the
   code the binary starts running. So the runtime (`lib/rt.fam`, which
   begins with the startup code) goes first and the object that calls
   `main` (`lib/rtmain.fam`) last, with the init records of the program's
   objects in between; `tools/famc` sees to that. In a test build each
   `test` block is an init record, and `lib/rttest.fam`, which reports the
   results, takes the place of `lib/rtmain.fam`.

A stub's jump is a plain `jal`, so the stub and its function must end up
within 1 MiB of each other. If they do not, the link fails with a message
saying so.

Link errors are reported as text in place of the binary, with exit code 1:

- a call, in a function that is kept, to a name no object defines (naming
  the caller)
- a name defined by two objects
- functions that call each other ending up over 1 MiB apart
- input that is not an object, or an object whose contents are inconsistent
- not enough memory for the link

## The binary

```
nop                          the mark of a fam binary
j +12                        over the next two words
j <the first island>         functions before the first island return here
j .
auipc gp, 0 ; addi gp, gp, 0     gp = the address just past the binary
<functions, stubs and islands>
<the init records>           where the program starts running
j .
<the last island>
```

It runs at whatever address it is loaded: every jump in it is relative.

**A function** is a jump over itself, its code, and a jump to the island
it returns through. (The jump over it is there because the binary runs
from the top, through the functions, to reach the init records.)

**A call** is seven instructions in the 28 bytes of a call site:

```
addi s11, s11, -4 ; bgeu s11, s10, +8 ; ebreak     room for a return id?
lui t0, id ; addi t0, t0, id                       this call's return id
sw t0, 0(s11)
j <the function, or a relay for it>
```

Return ids are numbered through the binary in the order the calls are
written.

**An island** is where functions return. There is one about every 256 KiB,
between functions, and one at the end. It pops the return id and jumps to
the instruction after that call, finding it by halving through the ids of
the calls since the island before; an id outside those is passed to the
island before or after. Every island but the last also has a relay, one
jump, for every function written so far: a call too far from its function
jumps to the nearest relay behind it, which jumps to the function or to
the relay before that.

No jump in the binary is a `jalr`.

## Function ids

Compiled code has no `jalr`, so it cannot jump to an address held in a
register. A function that is to be called through a value has an **id**
instead: a small number, from 1, that the linker gives to every function
some object has an id site for. Zero is no function's id.

A call through an id is an ordinary call site for the name `__call`, with
the id in `t2` and the arguments where they would be for a direct call.
When an object calls `__call` and none defines it, the linker writes it:
the **dispatcher**, which finds `t2` among the ids by halving and calls the
function. The function returns to the dispatcher and the dispatcher to the
caller, so such a call costs two calls and about as many comparisons as
the number of ids has bits. A number that is no function's id runs into an
illegal instruction, which the runtime reports.

Every function with an id is kept in a binary that has the dispatcher,
whether or not anything calls it directly.

## What the calls impose on generated code

These come from the call and return sequences above:

- `s10` and `s11` are the return-id stack's floor and pointer. The startup
  code sets them before the first call. Nothing else may touch them.
- A call and its return clobber `t0` and `t1`.
- A call is seven instructions, 28 bytes.
- On entry to the image, `gp` holds the address of the first byte past it.
- Calls reach any distance. A plain `jal` written by the front end reaches
  1 MiB, so a single function's code must stay under that.

## Calling convention

The standard RISC-V ILP32 integer convention, with two deviations forced by
the call sequence.

As in the standard:

- The first eight arguments go in `a0` to `a7`. Further arguments go on the
  stack, the ninth at `0(sp)`, the tenth at `4(sp)`, and so on; the caller
  reserves and releases that space.
- The result comes back in `a0` (`a0` and `a1` for a 64-bit value).
- `sp` is the stack pointer, 16-byte aligned at every call.
- `s0` to `s9` are preserved by the callee. `a0` to `a7` and `t0` to `t6`
  are not preserved.
- `gp` and `tp` are not available to compiled code; they belong to the
  runtime.

The deviations:

- **No return address in `ra`.** A call pushes a return id on the return-id
  stack and a return pops it and dispatches through an island. Compiled code
  never contains `jalr`, and `ra` is one more scratch register.
- **`s10` and `s11` are reserved** for that return-id stack, where the
  standard has them as callee-saved registers.

## Not in version 1

- **Shared data.** Globals and constants visible to other objects. Until
  there is a data part, an object exposes data through a function that
  returns its address.
- **Interfaces.** Types, constants and inlinable definitions exported for
  other compilations.
- **Debug information.** Source files and lines.

Each of these is a new part or a new symbol kind, under a new version.

## Open questions

1. **Size.** The linker has room for 32 MiB of objects and a 32 MiB
   binary, 32,768 symbols and 262,144 calls. Every island carries a relay
   for every function before it, so that part grows with the square of the
   program. And the init records are written with no island among them,
   so all of them together (every `test` block is one) must stay within a
   jump's reach, about 1 MiB.
2. **Far cycles.** A stub reaches 1 MiB. Everything a function in a cycle
   calls is written between its stub and itself, so a cycle near the root
   of a large program could exceed that. A chain of stubs would lift the
   limit.

## Decided

- Objects are binary. Code that must be written by hand, such as the
  startup code, is written in fam with `asm` and `init asm`.
- The linker is its own program and its own pass, and it is the back end
  too: it writes the binary. `tools/famc` is the driver that compiles or
  links depending on what it is given, the way `gcc` does.
- The compiler's own programs are written in the Forth of
  `lib/compiler.lib` and compiled by the core (`src/fam.S`), which the
  seed builds. The linker is; the front end is still assembly.
- The program starts in the runtime's init record (in `lib/rt.fam`),
  which lays out memory. The last init record (`lib/rtmain.fam`) calls
  `main`, then `exit` with its result.
