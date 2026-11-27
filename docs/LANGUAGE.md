# The fam language (so far)

Status: what `src/famc.S` compiles today. It grows step by step; "Not yet"
at the end lists what is planned and missing.

```
fn fib(n) {
    if n < 2 { return n; }
    return fib(n - 1) + fib(n - 2);
}

fn main() {
    let i = 1;
    let sum = 0;
    while i <= 10 {
        sum = sum + fib(i);
        i = i + 1;
    }
    return sum;
}
```

Build and run it with `scripts/fam.sh`:

```
sh scripts/fam.sh cc prog.fam prog.o
sh scripts/fam.sh ld prog bin/rt0.o prog.o
sh scripts/fam.sh run prog; echo $?
```

The program starts at `main`, and what `main` returns is the exit code.

## Values

Every value is a signed 32-bit integer. Arithmetic wraps around.

Numbers are decimal (`42`) or hex (`0x2A`), up to 32 bits.

## Functions

```
fn NAME(PARAMETER, ...) { STATEMENTS }
```

- A function can be called before it is defined, and from another file.
- A call must pass as many arguments as the function has parameters. This
  is not checked yet.
- A function that ends without `return` returns whatever its last
  computation left behind. Use `return` when the value matters.
- A function may call itself. Two functions calling each other are a link
  error for now.

## Statements

| Statement | Meaning |
|---|---|
| `let NAME = EXPR;` | A new local. It lasts to the end of its block and may hide an outer one of the same name. |
| `NAME = EXPR;` | Assign to a local or parameter. |
| `if EXPR { ... } else if EXPR { ... } else { ... }` | The `else` parts are optional. Zero is false; anything else is true. |
| `while EXPR { ... }` | Loop while the expression is not zero. |
| `return EXPR;` | Return a value. `return;` returns 0. |
| `EXPR;` | Compute and discard, usually a call. |
| `asm { HEXWORD ... }` | Put machine code in the function: see below. |

## Expressions

Operators, from the lowest precedence to the highest. Those on one line
have the same precedence and group left to right.

| Operators | Meaning |
|---|---|
| `\|\|` | or: 1 if either side is not zero; the right side is skipped if the left decides |
| `&&` | and: 1 if both sides are not zero; the right side is skipped if the left decides |
| `==` `!=` `<` `<=` `>` `>=` | comparisons (signed), giving 1 or 0 |
| `\|` | bitwise or |
| `^` | bitwise exclusive or |
| `&` | bitwise and |
| `<<` `>>` | shifts; `>>` keeps the sign |
| `+` `-` | add, subtract |
| `-x` `!x` `~x` | negate; 1 if zero, else 0; bitwise not |

Parentheses group. A call is `NAME(EXPR, ...)`.

## Machine code

`asm { ... }` puts instructions in the function as they are: each is eight
uppercase hex digits, four bytes in memory order, as in the text form of an
object (`docs/OBJECT.md`).

```
fn add3(x) {
    asm { 13053500 }        // addi a0, a0, 3
}
```

- If it is the first thing in a function, the arguments are still in `a0`
  to `a7`.
- What it leaves in `a0` is the function's result if the function ends
  there.
- It may use `a0` to `a7` and `t0` to `t6`. It must leave `sp`, `s0` to
  `s11`, `gp` and `tp` as they were.

## Comments

`//` starts a comment that runs to the end of the line.

## Errors

A compile error names the file and line and stops at the first problem:

```
prog.fam:3: unknown variable y
```

## Limits

- About 500 locals and temporaries alive at once in one function.
- A function's code must stay under 1 MiB.

## Not yet

- Multiply, divide and remainder (the CPU has no instructions for them;
  they come with the runtime library).
- Types other than the 32-bit integer; strings, arrays, pointers, structs.
- Global variables and constants.
- Checking the number of arguments of a call.
- Mutual recursion.
- Modules, tests, function pointers.
