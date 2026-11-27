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
    while i <= 10 {
        print_int(fib(i));
        print("\n");
        i = i + 1;
    }
    return 0;
}
```

Compile it with `tools/famc`, which is used like `gcc`, and run it with
`tools/q32`:

```
tools/famc prog.fam -o prog
tools/q32 prog; echo $?
```

The program starts at `main`, and what `main` returns is the exit code.
`famc` adds the runtime (startup and library) to every link; a binary holds
only the functions the program uses.

| Command | What it does |
|---|---|
| `famc a.fam b.fam -o prog` | Compile and link. Without `-o` the binary is `a.out`. |
| `famc -c a.fam` | Compile only, to `a.o`. |
| `famc main.fam util.o -o prog` | Sources and objects together. |
| `famc --test a.fam -o t` | Build the files' tests: see "Tests". |
| `q32 prog` | Run a binary. It reads q32's standard input and writes to its standard output. |

Both run QEMU (`qemu-system-riscv32`), and need `scripts/build.sh` to have
run. `MEM=256M` in the environment changes the machine's memory.

## Values

Every value is a signed 32-bit integer. Arithmetic wraps around.

Numbers are decimal (`42`) or hex (`0x2A`), up to 32 bits.

A string, `"hello\n"`, is the address of its bytes, which end with a zero
byte. Inside one, `\n` is a newline, `\t` a tab, `\0` a zero byte, `\\` a
backslash and `\"` a quote. A string must end on the line it starts on.

`bytes { 13 00 00 00 6F00C000 }` is the address of those bytes: uppercase
hex digits, two for each byte, grouped any way. There is no zero byte at
the end, and the program has to know the length.

## Functions

```
fn NAME(PARAMETER, ...) { STATEMENTS }
```

- A function can be called before it is defined, and from another file.
- A call must pass as many arguments as the function has parameters. This
  is not checked yet.
- A function that ends without `return` returns whatever its last
  computation left behind. Use `return` when the value matters.
- Functions may call themselves and each other.

## Function values

`&NAME` is a function as a value, which can be kept in a local, passed and
compared. Calling a local calls the function it holds:

```
fn add(a, b) { return a + b; }
fn apply(f, a, b) { return f(a, b); }

fn main() {
    let f = &add;
    return f(1, 2) + apply(&add, 3, 4);
}
```

- `&shapes.area` names another module's function, as in a call.
- A local hides a function of the same name: `f(1, 2)` calls through the
  local `f` if there is one.
- The value is a small number, the function's id, not an address. Zero is
  never a function, so it can stand for "none".
- A call through a value is slower than a direct call (`docs/OBJECT.md`,
  "Function ids").
- Calling a number that is no function's id stops the program with a
  message. Nothing checks that the function takes the arguments given.

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
| `*` `/` `%` | multiply, divide, remainder; division rounds toward zero, the remainder has the sign of the left side, and dividing by zero is a panic |
| `-x` `!x` `~x` | negate; 1 if zero, else 0; bitwise not |

Parentheses group. A call is `NAME(EXPR, ...)`.

## Modules

A file belongs to a module if it starts with a `module` line:

```
module shapes;

pub fn area(w, h) { return w * h; }

fn twice(x) { return x + x; }       // only this file can call it

pub fn around(w, h) { return twice(w) + twice(h); }
```

Another file imports the module and calls its functions by their full
names:

```
import shapes;

fn main() {
    print_int(shapes.area(3, 4));
    return 0;
}
```

- **`pub`** makes a function callable from other files. Without it a
  function is private to its file, and other files may have their own
  function of the same name. `main` needs no `pub`.
- **A file without a `module` line** is in the root module, whose public
  functions need no prefix anywhere. The runtime library is there, which is
  why `print` works in every file.
- **A bare name**, `twice(x)`, is this file's function of that name if it
  has one, and the root module's otherwise.
- **A full name**, `shapes.area(3, 4)`, needs `import shapes;` earlier in
  the file, unless `shapes` is the file's own module.
- **Several files** may belong to one module. They call each other's `pub`
  functions by full name.
- **`import` does not read anything.** It only allows the prefix; the
  module's file or object must be given to `famc` too. Calling a function that
  does not exist, or is not `pub`, is a link error:
  `famld: undefined: shapes.twice in main`.

## Tests

A `test` block sits next to the code it tests:

```
fn add(a, b) { return a + b; }

test "add adds" {
    assert add(2, 3) == 5;
    assert add(-1, 1) == 0;
}
```

`famc --test` builds the files given with their tests, and running the
result runs them all:

```
$ tools/famc --test math.fam -o t && tools/q32 t
ok    add adds
FAIL  add handles big numbers (math.fam:14)

1 passed, 1 failed
```

- A test's body is statements, as in a function. `assert EXPR;` fails the
  test if the expression is zero, and the test stops there. The other
  tests still run.
- The exit code is 0 if every test passed, else 1.
- Tests run in the order they are written, file by file. `main` is not
  called.
- A normal build (without `--test`) skips test blocks.
- `assert` is only allowed in a test block.
- A panic or a trap in a test ends the whole run.

## The runtime library

These are in `lib/rt.fam`, in the root module, so every file can call them
by their bare names.

| Function | Meaning |
|---|---|
| `putc(c)` | Write one byte to the console. |
| `print(s)` | Write a string. |
| `print_int(n)` | Write a number in decimal. |
| `print_hex(n)` | Write a number as `0x` and eight hex digits. |
| `getc()` | The next byte from the console. Waits until there is one. |
| `alloc(size)` | The address of a new piece of memory of that many bytes. Nothing gives it back; running out is a panic. |
| `exit(code)` | End the program with that exit code. |
| `panic(message)` | Write `panic: ` and the message, and exit with code 1. |
| `load8(address)` `load32(address)` | The byte (0 to 255) or the word at an address. |
| `store8(address, value)` `store32(address, value)` | Put a byte or a word at an address. |

Names starting with `__` belong to the runtime.

The four `load` and `store` functions compile to a single instruction each
when called by name.

A program reads what `q32` is given: `tools/q32 prog < input`.

## When a program goes wrong

The startup code (in `lib/rt.fam`) gives the stack everything from the end of
the program to the top of the machine's memory, less a sixteenth for the
return ids of calls. `alloc` takes its pieces from the low end of the
stack's space. Running out of either stack is caught and reported, with
exit code 1, as is any other fault:

```
fam: calls nested too deep at 0x80000AF0
fam: stack overflow at 0x80000B20
fam: trap 5 on address 0x00000000 at 0x80000B4C
```

## Machine code

`asm { ... }` puts instructions in the function as they are: each is eight
uppercase hex digits, four bytes in memory order: `addi a0,a0,3` is the
word `0x00350513`, written `13053500`.

```
fn add3(x) {
    asm { 13053500 }        // addi a0, a0, 3
}
```

- `@NAME` in it is a call of that function, and `&NAME` loads the
  function's id into `a0`. Arguments and the result are in `a0` to `a7` as
  usual; a call does not preserve `t0` to `t6` or `a0` to `a7`.
- If it is the first thing in a function, the arguments are still in `a0`
  to `a7`.
- What it leaves in `a0` is the function's result if the function ends
  there.
- It may use `a0` to `a7` and `t0` to `t6`. It must leave `sp`, `s0` to
  `s11`, `gp` and `tp` as they were.

## Code that runs at startup

An `init` block at the top of a file runs once when the program starts,
before `main`:

```
init { print("starting\n"); }
```

- Init blocks run in the order written, file by file in the order the
  files are given to `famc`.
- Its body is statements, as in a function. `return;` ends it.
- `init asm { ... }` is the same with nothing but the machine code given:
  no stack frame around it. The runtime's own startup code is written this
  way, because it runs before there is a stack.

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

- Types other than the 32-bit integer; arrays, pointers, structs.
- Character literals.
- Global variables and constants; giving memory back.
- Checking the number of arguments of a call.
- Nested modules; importing single names; checking at compile time that
  an imported function exists.
- Types for function values (they are plain numbers, like everything
  else).
