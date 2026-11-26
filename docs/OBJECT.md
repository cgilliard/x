# fam object format, version 1 (draft)

Status: a draft. Nothing implements it yet. Parts marked *provisional* or
listed under "Open questions" are the ones most likely to change.

## Pipeline

```
source.fam ──front end──▶ source.o ─┐
source.fam ──front end──▶ source.o ─┼─cat──▶ linker ──▶ core text ──▶ core ──▶ binary
runtime.fam ─front end──▶ runtime.o ┘
```

- The **front end** compiles one source file to one object. It runs under
  QEMU on top of the core compiler and writes the object to the serial port.
- An **object** is text: machine code as hex words, plus calls to functions
  by their full names.
- The **linker** reads the concatenated objects and writes text in the core's
  language (`: name ... ;`, hex words, `,`), with every function given a short
  name and placed before its first caller.
- The **core** (`src/fam.S`) compiles that text to the final binary. Calls,
  return ids, islands and relays are the core's, unchanged.

## File structure

An object is ASCII text. It never contains the byte `0x04`, which ends the
core's input. Tokens are separated by spaces, tabs or newlines.

The first line is the header:

```
fam-obj 1
```

A file that starts with anything else is not an object; the front end writes
its error message there when a compile fails, so the build can show it.

After the header come records. Each starts with a keyword at the start of a
line and runs to a line holding only `end`.

| Record | Meaning |
|---|---|
| `fn NAME` | Defines the function `NAME`. |
| `init` | Code run once at startup, before anything else calls into this object. |

A line starting with `#` is a comment, anywhere outside a token. The front
end may use comments to carry source file and line for later tools.

## Record bodies

A body is a sequence of two kinds of token:

| Token | Meaning |
|---|---|
| `XXXXXXXX` | Eight uppercase hex digits: four bytes of code or data, in memory order. `addi sp,sp,-4` is the word `0xFFC10113`, written `1301C1FF`. |
| `@NAME` | A call to the function `NAME`, defined in this object or another. |

Nothing else may appear in a body. All branches and data references inside a
body are PC-relative and already resolved by the front end; the only thing
left for the linker is the calls.

## Names

A name is 1 to 255 bytes, none of them whitespace, control characters or
`@`. Names are global across the link. The front end makes them unique by
prefixing the module: `math.add`. Visibility between modules is the front
end's job, not the linker's.

## Example

```
fam-obj 1
# math.fam
fn math.answer
1305A002
end
fn main
@math.answer
end
```

`math.answer` returns 42 in `a0` (`addi a0,zero,42`). `main` calls it and
returns the same value.

## Linking

The linker:

1. Reads every record of every object, in the order the objects were given.
2. Gives each function a short name the core accepts: `_` and seven hex
   digits (`_0000001`). The underscore keeps it from ever reading as a hex
   word.
3. Orders the functions so each is defined before any function that calls it.
4. Breaks each cycle (mutual recursion) with a stub: a short word defined
   ahead of the cycle that jumps to the real function, patched when that
   function is defined. Two small immediate words in the linker's output do
   the recording and patching. *Provisional: designed, not yet tried.*
5. Writes all functions, then every `init` body as top-level code, in object
   order. The core runs top-level code in order at startup, so the runtime
   library's object goes first on the link line.

For the example above the linker writes:

```
: _0000001 1305A002 , ;
: _0000002 _0000001 ;
```

Link errors are reported as text in place of the output, with exit code 1:

- a call to a name no object defines (naming the caller)
- a name defined twice (naming both objects)
- a malformed record

## What the core imposes on generated code

These come from the core's call and return sequences and are not negotiable
without changing `src/fam.S`:

- `s10` and `s11` are the return-id stack's floor and pointer. The runtime's
  `init` sets them before the first call. Nothing else may touch them.
- A call and its return clobber `t0` and `t1`.
- On entry to the image, `gp` holds the address of the first byte past it.
- Calls reach any distance. A plain `jal` written by the front end reaches
  1 MiB, so a single function body must stay under that.

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
  there is a data record, an object exposes data through a function that
  returns its address.
- **Function pointers.** A token for "the id of function `NAME`", and the
  dispatcher the linker would generate.
- **Interfaces.** Types, constants and inlinable definitions exported for
  other compilations.
- **Debug information** beyond comments.

## Open questions

1. **Size.** Hex text is about 9 bytes per 4 bytes of code, and the core
   holds its whole input and output in a 5 MiB heap. If that becomes tight,
   the heap constant in `src/fam.S` is the first thing to raise.
2. **Cycle stubs.** The scheme in "Linking" step 4 is untried.

## Decided

- The linker is its own program and its own pass. A single driver that
  compiles or links depending on its inputs, the way `gcc` does, comes
  later and sits on top of the two.
- The program starts in the runtime's `init`, which calls `@main`.
