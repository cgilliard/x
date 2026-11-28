# The next compiler: a small core and macros

Status: a plan, of which the start is built. The compiler, `src/famc/`,
is written in fam. It compiles today's language (`docs/LANGUAGE.md`) to the
same bytes as the stage compiler, `src/famc.forth`, which builds it and is
frozen; `scripts/test_compilers.sh` checks that. In it `if`, `while`,
`return`, `||` and `&&` are already macros (`src/famc/std.fam`), built from
the labels and jumps of `src/famc/emit.fam`, with the checks on jumps
below. They are functions registered by name; there is no `macro` keyword
yet, and nothing else here is built.

The compiler is to understand very little itself:
definitions, expressions and assignment. Everything that controls flow
(`if`, loops, `return`, `&&`) is a macro in the library, built from labels
and jumps that only macros can reach.

## One compilation is one tree of files

The compiler is given one root file and finds the others itself. It
compiles them together and writes one object.

```
use logging::logger;
use config::configurator;
```

- `use` both finds a file and brings a name into scope. There is no `mod`.
- In a path, the leading parts name a file relative to the root file's
  directory (`a.fam`, or `a/b.fam`); the rest names something in it.
  `use driver;` includes a file for its start-up code alone.
- Files join the compilation in the order of their first `use`, followed
  from the root. The order comes from the source and never from a
  directory listing (rule 5 of `docs/DESIGN.md`).
- A file is a module. There are no modules inside a file.
- A file that nothing uses is not compiled.
- Names, `pub`, types and constants are checked by the compiler, with a
  file and a line. The object format carries no type information.

Macros are the exception to one command, one object: a macro must be built
and linked into the compiler before the code that uses it, so macros are
compiled as a tree of their own, first.

## What the compiler understands

- **Items:** `fn`, `macro`, global `let` and `const`, type definitions,
  `use`, and `#[name(...)]`.
- **Statements:** `let`, assignment, an expression followed by `;`, and
  `{ }` as a scope.
- **Expressions:** literals, names, calls, field access, parentheses and
  operators. The core knows how each operator is spelled and how tightly
  it binds, not what it does.

Assignment is a statement, so `x = y = 0;` is an error, and an expression
can change a variable only through a call. `x += e` is a statement too,
read as `x = x + e`.

The core has no `if`, no loop, no `return`, no `&&` and no `goto`.

Types and their sizes belong to the core. They are not designed yet.

## Macros

```
macro while(p) {
    let top = label(p);
    let end = label(p);
    place(p, top);
    expr(p);
    jump_if_zero(p, end);
    push_loop(top, end);
    block(p);
    pop_loop();
    jump(p, top);
    place(p, end);
}
```

A macro is a fam function that is linked into the compiler. It is given
the parser, reads what follows its name, and tells the compiler what to
emit. It returns nothing.

A macro is called in one of two ways:

- **By its name**, where an item, a statement or an operand can begin:
  `while i < 10 { ... }`. There is no `!`.
- **As an attribute** on the item that follows: `#[test] fn empty() { ... }`.

A file sees the macros it imports and a small standard set.

The standard macros are part of this compiler's source and are compiled
with it by the stage compiler, which has `if` and `while` built in. So
they can be written with the things they define.

### What the compiler offers a macro

| Group | Calls | For |
|---|---|---|
| Reading | `peek` `next` `accept` `expect` | looking at and taking tokens |
| Compiling | `expr` `block` `statement` | compiling the next piece; `expr` gives its type and leaves the value in the result register |
| Flow | `label` `place` `jump` `jump_if_zero` `jump_if_nonzero` `exit_label` | all of control flow |
| Deferral | `capture` `replay` `at_scope_exit` | reading a statement without compiling it, and compiling it later, as often as needed |
| Other | `flag` `error` `register` | build flags, errors, and code to run at start-up |

A label is a value the compiler hands out, not a name in the source, so
two macros can never pick the same one.

### What the compiler checks on every jump

1. The label is in the scope of the jump or in one that encloses it, and
   no `let` lies between them. A jump cannot arrive where a variable is in
   scope and was never given a value.
2. The same number of temporaries is on the stack at the jump and at the
   label. A jump cannot leave the middle of an expression.
3. Every label is placed exactly once by the end of its function.
4. A jump that leaves scopes first runs what was deferred in them, the
   innermost first. `defer` cannot be bypassed.

These checks do not make the flow well nested: a wrong macro could build a
loop with two entries. That is left to be shown about the binary
(`docs/DESIGN.md`, "To prove later").

## In the library

| Construct | Built from |
|---|---|
| `if` / `else` | a condition, `jump_if_zero` to the else part, a jump over it |
| `a ? b : c`, `&&`, `\|\|` | operator macros |
| `+`, `<`, ... | operator functions, one for each type |
| `loop`, `while`, `for` | two labels, kept on a stack of open loops |
| `break`, `continue` | a jump to a label from that stack |
| `return` | the value, then a jump to `exit_label` |
| `defer` | `capture`, then `at_scope_exit` |
| `cfg`, `test` | `flag` and `register` |
| `assert`, `assert_eq`, printing | `if` and calls |

An operator is defined in one of two ways:

- **As a function**, when both sides are always evaluated. `+` on a type
  is an inline function for that type.
- **As a macro**, when the right side may be skipped. The macro is called
  once the left side is compiled, and jumps around the right side.

## Tests and build flags

```
fn packed_size(input, n) {
    return pack(input, n, alloc(room(n)));
}

#[cfg(test)]
{
    #[test]
    fn empty() {
        assert(packed_size("", 0) == 0, "nothing packs to nothing");
    }
}
```

- A test is a function marked `#[test]`, in the file it tests. Its name is
  the function's name. `test` registers it to be run at start-up, with the
  `init` records the object format already has.
- `#[cfg(NAME)]` lets the next item through when the flag is set and
  otherwise skips it unparsed, so a mistake inside shows only in a build
  with the flag.
- The braces after `#[cfg(...)]` group; they are not a scope. What is
  inside is in the file's names like anything else.
- `famc --cfg NAME` sets a flag. `famc --test` sets `test`.
- `assert` and `assert_eq` take an optional reason, and report the file
  and line.

## Open

- **Types.** Which there are, how a macro asks about them, and whether
  `match` on a tagged union is in the core or a macro.
- **Naming a loop:** `'a: while ...` or `while 'a ...`. The second needs
  nothing from the core.
- **Values wider than a word.** "The value is in the result register"
  covers one word.
- **Libraries:** compiled from source into each program, or compiled once
  with their types written out. From source first.
- **The path separator:** `::` above; today's compiler uses `.`.

## Order of work

1. This compiler, written in fam and built by the stage compiler, first
   compiling today's language to the same bytes. (Done.)
2. The interface for macros, then `if`, the loops and `return` moved out
   to the library. (Done, as `src/famc/std.fam`.)
3. `use`, attributes, flags and tests.
4. Types, and operators as library functions.
