# fam object format, version 1 (draft)

Status: a draft, implemented by `src/famc.S` (the front end), `src/famas.S`
(the object assembler) and `src/famld.S` (the linker) except where noted.
Parts listed under "Open questions" are the ones most likely to change.

## Pipeline

```
lib/rt0.s ───famas──▶ rt0.o ────┐
source.fam ──famc───▶ source.o ─┤
source.fam ──famc───▶ source.o ─┼─▶ famld ──▶ core text ──▶ core ──▶ binary
lib/rt.fam ──famc───▶ rt.o ─────┤
lib/rtmain.s ─famas─▶ rtmain.o ─┘
```

- The **front end** (`famc`) compiles one source file to one object.
- The **object assembler** (`famas`) turns the text form of an object into
  an object. It exists for code written by hand: the startup code and the
  linker's tests.
- An **object** is binary: machine code, the names it defines and calls,
  and where the calls are.
- The **linker** (`famld`) reads the objects one after another and writes
  text in the core's language (`: name ... ;`, hex words, `,`), with every
  function given a short name and placed before its first caller.
- The **core** (`src/fam.S`) compiles that text to the final binary. Calls,
  return ids, islands and relays are the core's, unchanged.

Each of these is a program of its own, run under QEMU with its input on the
serial port and its output redirected to a file. `scripts/fam.sh` drives
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
of the core's call sequence, which the linker has the core put there. So
the code in an object is laid out exactly as it will be in memory, and the
front end can resolve every branch from offsets in its own output.

Call sites are in ascending order of offset and do not overlap. Each lies
wholly inside one record's code.

### Code

All branches and data references inside a record are PC-relative and
already resolved. The only thing left for the linker is the calls.

A function's code does not include its return: the linker ends each
function with the core's `;`. A function that returns early jumps to the
end of its own code.

## Text form

The text form says the same thing in a way a person can write. `famas`
turns it into an object, and `fam.sh dump` prints an object in it.

Tokens are separated by spaces, tabs or newlines. A token starting with `#`
begins a comment that runs to the end of the line. A record starts with
its keyword and runs to `end`:

| Record | Meaning |
|---|---|
| `fn NAME` | Defines the function `NAME`. |
| `local NAME` | Defines the local function `NAME`. |
| `init` | Code run once at startup. |

A body is a sequence of two kinds of token:

| Token | Meaning |
|---|---|
| `XXXXXXXX` | Eight uppercase hex digits: four bytes of code, in memory order. `addi sp,sp,-4` is the word `0xFFC10113`, written `1301C1FF`. |
| `@NAME` | A call to the function `NAME`: a call site, and its 28 bytes of code. |

In the text form a name cannot contain whitespace or `@`, or start with
`#`.

```
# math.answer returns 42 in a0 (addi a0,zero,42).
fn math.answer
1305A002
end
# main calls it and returns the same value.
fn main
@math.answer
end
```

As an object this is 124 bytes: the header, two symbols, one call site, 32
bytes of code (4 for `math.answer`, 28 for the call site in `main`) and 16
bytes of names.

## Linking

The linker's input is the objects, one after another, then an end marker
of four `0x04` bytes. It:

1. Reads and checks every object, in the order given.
2. Gives each name a short name the core accepts: `_` and seven hex digits
   (`_0000001`). The underscore keeps it from ever reading as a hex word.
3. Finds the functions the init records reach, directly or through other
   functions, and orders them so each is defined before any function that
   calls it. A function nothing reaches is left out of the binary.
4. Breaks each cycle (functions that call each other) with a stub: a word
   holding one jump, defined ahead of the cycle. Calls made before the real
   function is defined go to the stub, and the jump is pointed at the
   function when it is defined. Three small words at the top of the
   linker's output, run by the core as it compiles, do the recording and
   pointing. A function calling itself needs no stub.
5. Writes those functions, then every init record as top-level code, in
   input order. The core runs top-level code in order at startup, so the
   startup object (`lib/rt0.s`) goes first and the one that calls `main`
   (`lib/rtmain.s`) last, with the init records of the program's objects in
   between; `fam.sh ld` sees to that, and adds the runtime library. In a
   test build each `test` block is an init record, and `lib/rttest.s`,
   which reports the results, takes the place of `lib/rtmain.s`.

For the example above the linker writes:

```
: _0000001 1305A002 , ;
: _0000002 _0000001 ;
```

And for `a` and `b` that call each other, with `b` reached first through
`a`:

```
: >0000001 00000000 mark 6F000000 , ;
: _0000002 ... >0000001 ... ;
: _0000001 00000000 patch ... _0000002 ... ;
```

`>0000001` is the stub for `_0000001` and `00000000` its index. A stub's
jump is a plain `jal`, so the stub and its function must end up within
1 MiB of each other. If they do not, the link fails with a message saying
so.

Link errors are reported as text in place of the output, with exit code 1:

- a call, in a function that is kept, to a name no object defines (naming
  the caller)
- a name defined by two objects
- functions that call each other ending up over 1 MiB apart
- input that is not an object, or an object whose contents are inconsistent

## What the core imposes on generated code

These come from the core's call and return sequences and are not negotiable
without changing `src/fam.S`:

- `s10` and `s11` are the return-id stack's floor and pointer. The startup
  code sets them before the first call. Nothing else may touch them.
- A call and its return clobber `t0` and `t1`.
- A call is seven instructions, 28 bytes.
- On entry to the image, `gp` holds the address of the first byte past it.
- Calls reach any distance. A plain `jal` written by the front end reaches
  1 MiB, so a single function's code must stay under that.

## Calling convention

The standard RISC-V ILP32 integer convention, with two deviations forced by
the core's call sequence.

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
- **Function pointers.** A way to say "the id of function `NAME`", and the
  dispatcher the linker would generate.
- **Interfaces.** Types, constants and inlinable definitions exported for
  other compilations.
- **Debug information.** Source files and lines.

Each of these is a new part or a new symbol kind, under a new version.

## Open questions

1. **The linker's output is text.** Hex text is about 11 bytes per 4 bytes
   of code, and the core holds its whole input and output in a 5 MiB heap.
   If that becomes tight, the heap constant in `src/fam.S` is the first
   thing to raise.
2. **Far cycles.** A stub reaches 1 MiB. Everything a function in a cycle
   calls is written between its stub and itself, so a cycle near the root
   of a large program could exceed that. A chain of stubs would lift the
   limit.

## Decided

- Objects are binary. The text form is for code written by hand and for
  looking at an object.
- The linker is its own program and its own pass. A single driver that
  compiles or links depending on its inputs, the way `gcc` does, comes
  later and sits on top of the tools.
- The program starts in the startup object's init record (`lib/rt0.s`),
  which lays out memory. The last init record (`lib/rtmain.s`) calls
  `main`, then `exit` with its result.
