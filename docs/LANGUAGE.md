# The fam language (so far)

Status: what the compiler, `src/famc/`, compiles today. It grows step by
step; "Not yet" at the end lists what is planned and missing.

```
fn fib(n: i32) -> i32 {
    if n < 2 { return n; }
    return fib(n - 1) + fib(n - 2);
}

fn main() -> i32 {
    let i = 1;
    while i <= 10 {
        print_int(fib(i));
        print("\n");
        i = i + 1;
    }
    return 0;
}
```

Compile it with `tools/famc`, and run it with `tools/q32`:

```
tools/famc prog.fam -o prog
tools/q32 prog; echo $?
```

The program starts at `main`, which is `fn main() -> i32`, and what it
returns is the exit code. Every program has the runtime library; a binary
holds only the functions the program uses.

| Command | What it does |
|---|---|
| `famc a.fam -o prog` | Compile and link. Without `-o` the binary is `a.out`. |
| `famc -c a.fam` | Compile only, to `a.o`. |
| `famc --test a.fam` | Build the tests of the file, and of the files it uses, and run them: see "Tests". |
| `famc --cfg NAME ...` | Set a flag, for `#[cfg(NAME)]`. |
| `q32 prog` | Run a binary. It reads q32's standard input and writes to its standard output. |

`famc` is given one file. The files that one uses are found from it: see
"Using other files".

Both run QEMU (`qemu-system-riscv32`), and need `scripts/build.sh` to have
run. `MEM=256M` in the environment changes the machine's memory.

## Types

Every value has a type, and nothing is converted that is not told to be.

| Type | What it is |
|---|---|
| `i8` `i16` `i32` | an integer with a sign, of 8, 16 or 32 bits |
| `u8` `u16` `u32` | an integer without one |
| `bool` | `true` or `false` |
| `*T` | a pointer: the address of a `T` |
| `fn(T, ...) -> T` | a function, as a value: see "Function values" |

- **Arithmetic wraps** at the size of the type: a `u8` holding 250, plus
  10, is 4.
- **The two sides of an operator have the same type.** `a + b` with a `u8`
  and an `i32` is an error: write `a as i32 + b`.
- **`EXPR as TYPE`** turns a value into another type. Between integers it
  keeps the low bits and reads them as the new type: `300 as u8` is 44,
  and `200 as u8 as i8` is -56. A `bool` becomes 1 or 0. A pointer becomes
  a pointer of another type, or a `u32` or `i32`, and those become
  pointers. Nothing becomes a `bool`: write `n != 0`. `as` binds tighter
  than any operator with two sides, and looser than `-x` or `*p`.
- **A number written in the source** (`42`, `0x2A`, up to 32 bits) takes
  the type of what stands beside it, or of where it is going, and must fit
  it: `let b: u8 = 300;` is an error. With nothing to say, it is an `i32`.
- **A string**, `"hello\n"`, is a `*u8`: the address of its bytes, which
  end with a zero byte. Inside one, `\n` is a newline, `\t` a tab, `\0` a
  zero byte, `\\` a backslash and `\"` a quote. A string must end on the
  line it starts on.
- **`bytes { 13 00 00 00 6F00C000 }`** is a `*u8` too: the address of those
  bytes, written as uppercase hex digits, two for each byte, grouped any
  way. There is no zero byte at the end.

## Pointers

```
fn sum(p: *u32, n: u32) -> u32 {
    let total: u32 = 0;
    let i: u32 = 0;
    while i < n {
        total = total + p[i];
        i = i + 1;
    }
    return total;
}
```

| Expression | Meaning |
|---|---|
| `*p` | what `p` points at |
| `p[i]` | what `p` points at, `i` of them further on; `i` is any integer |
| `p + n`, `p - n` | the pointer `n` of them further on, or back |
| `&x` | the address of the local or global `x` |
| `p == q`, `p < q`, ... | pointers of one type compare, as addresses |

`*p = EXPR;` and `p[i] = EXPR;` store. What is loaded and stored is as
many bytes as the type has. Nothing checks that a pointer points at
anything: `0 as *u8` is a pointer like any other.

## Functions

```
fn NAME(PARAMETER: TYPE, ...) -> TYPE { STATEMENTS }
```

- Without `-> TYPE` the function gives nothing, and `return;` ends it.
- A call must pass as many arguments as the function has parameters, each
  of the parameter's type.
- A function can be called before it is defined.
- `return EXPR;` must give the function's type. A function that should
  give a value and ends without `return` gives whatever its last
  computation left behind: this is not checked yet.
- Functions may call themselves and each other.

## Function values

`&NAME` is a function as a value, of the type `fn(...) -> ...` that the
function has. It can be kept in a local, passed and compared, and calling
a local calls the function it holds:

```
fn add(a: i32, b: i32) -> i32 { return a + b; }
fn apply(f: fn(i32, i32) -> i32, a: i32, b: i32) -> i32 { return f(a, b); }

fn main() -> i32 {
    let f = &add;
    return f(1, 2) + apply(&add, 3, 4);
}
```

- `&shapes::area` names another file's function.
- The value is a small number, the function's id, not an address. Zero is
  never a function's id.
- A call through a value is slower than a direct call (`docs/OBJECT.md`,
  "Function ids").
- Calling a number that is no function's id stops the program with a
  message.

## Constants and globals

```
const LIMIT = 4096;
let count = 0;
pub let total: u32 = LIMIT;
let ready: bool = false;
```

A **constant** is a name for a number, or for `true` or `false`. Like a
number written in the source, it takes the type of where it is used.

A **global** is a variable outside any function, which starts as given and
lasts as long as the program runs. Its type is `i32` if none is written.

- What follows the `=` is a number or the name of a constant, with a `-`
  in front if wanted, or `true` or `false`. It is not an expression.
- A local or parameter of the same name hides either.
- A global the program never uses is left out of the binary.

## Statements

| Statement | Meaning |
|---|---|
| `let NAME = EXPR;` | A new local, of the expression's type. It lasts to the end of its block and may hide an outer one of the same name. |
| `let NAME: TYPE = EXPR;` | The same, of the type written. |
| `NAME = EXPR;` | Assign to a local, a parameter or a global. `FILE::NAME = EXPR;` assigns to another file's global. |
| `*P = EXPR;` `P[I] = EXPR;` | Store where a pointer points. |
| `if EXPR { ... } else if EXPR { ... } else { ... }` | The `else` parts are optional. The expression is a `bool`. |
| `while EXPR { ... }` | Loop while the `bool` is true. |
| `return EXPR;` `return;` | Leave the function, with its value if it gives one. |
| `EXPR;` | Compute and discard, usually a call. |
| `asm { HEXWORD ... }` | Put machine code in the function: see below. |

Every variable can be assigned to. Assigning is a statement, not an
expression: `a = b = 0;` is an error.

## Expressions

Operators, from the lowest precedence to the highest. Those on one line
have the same precedence and group left to right.

| Operators | Meaning |
|---|---|
| `\|\|` | or, of two `bool`s; the right side is skipped if the left decides |
| `&&` | and, of two `bool`s; the right side is skipped if the left decides |
| `==` `!=` `<` `<=` `>` `>=` | comparisons, giving a `bool`; the order is that of the type, with or without a sign |
| `\|` | bitwise or |
| `^` | bitwise exclusive or |
| `&` | bitwise and |
| `<<` `>>` | shifts; `>>` keeps the sign of a type that has one |
| `+` `-` | add, subtract |
| `*` `/` `%` | multiply, divide, remainder; division rounds toward zero, the remainder has the sign of the left side, and dividing by zero is a panic |
| `EXPR as TYPE` | turn into another type |
| `-x` `!x` `~x` `*p` `&x` | negate; not, of a `bool`; bitwise not; what a pointer points at; an address |
| `p[i]` `f(...)` | what a pointer points at, further on; a call |

Parentheses group.

## Using other files

The compiler is given one file and finds the others itself:

```
// main.fam
use config::LIMIT;          // LIMIT is what config.fam calls LIMIT
use logging::log;           // log is logging.fam's function log
use net::packet;            // packet is the file net/packet.fam

fn main() -> i32 {
    log("limit", LIMIT);
    return packet::size(3) - packet::HEADER;
}
```

```
tools/famc main.fam -o prog
```

- **`use a::b::name;`** makes `name` stand for what the file `a/b.fam`
  calls `name`: a function, a global or a constant. If there is no such
  file, the whole path is a file, `a/b/name.fam`, and `name` stands for
  that file: then `name::thing` is what it calls `thing`.
- **Files are found from the directory of the file given to `famc`,**
  wherever the `use` is written.
- **Only what is `pub` can be used** from another file: `pub fn`,
  `pub let`, `pub const`. Using what is not `pub`, or does not exist, is an
  error that names the line: `main.fam:2: private: helper`.
- **A used file is compiled into the object of the file that was given.**
  It is compiled once, however many files use it, where the first `use`
  of it stands: so its `init` blocks run before those that follow that
  `use`.
- **A bare name** is this file's, or one named in a `use`, or else the
  runtime library's. It is never another file's that was not named in a
  `use`.
- **Anything can be named before it is defined**, in this file or
  another, and two files may use each other. Only the value of a constant
  or a global must be made of constants defined above it.

## Tests

A test is a function marked `#[test]`, next to the code it tests:

```
fn add(a: i32, b: i32) -> i32 { return a + b; }

#[cfg(test)]
{
    fn big() -> i32 { return 1000; }    // only there in a test build

    #[test]
    fn adds() {
        assert(add(2, 3) == 5);
        assert(add(2, 2) == 4, "two and two");
        assert_eq(add(big(), 1), 1001, "a big one");
    }
}
```

```
$ tools/famc --test math.fam
ok    adds
FAIL  subtracts (math.fam:21): 3 is not 4: three less one

1 passed, 1 failed
```

- **`#[test] fn NAME() { ... }`** is a test, named by its function. A
  normal build passes over it.
- **`assert(EXPR);`** fails the test if the `bool` is false, and the test
  stops there; the other tests still run. **`assert_eq(A, B);`** fails it
  if two integers of one type differ, and says what they were. Both take a
  reason, a string, as a last argument; it is only computed if the test
  fails. They are only allowed in a test.
- **`#[cfg(NAME)]`** before a function, a `let`, a `const`, a `use`, or
  several of them in `{ }`, keeps them only if the flag NAME is set.
  `famc --test` sets the flag `test`, and `famc --cfg NAME` sets any. What
  is not kept is not read, but for its braces: a mistake in it shows only
  in a build with the flag. The braces group; they are not a scope.
- `famc --test main.fam` runs the tests of `main.fam` and of every file it
  uses, in the order the files are compiled. `main` is not called.
- The exit code is 0 if every test passed, else 1.
- `famc --test main.fam -o t` keeps the test binary as `t` and does not
  run it; `tools/q32 t` runs it later.
- `famc --test lib/rt.fam` runs the runtime's own tests.
- A panic or a trap in a test ends the whole run.

## Macros

`if`, `while`, `return`, `||`, `&&`, `#[cfg]`, `#[test]`, `assert` and
`assert_eq` are not part of the compiler proper. Each is a macro: a
function in `src/famc/std.fam` that the compiler calls where the word
stands, which reads what follows and says what code to write, with labels
and jumps (`docs/CORE.md`). A program cannot define its own yet.

## The runtime library

These are in `lib/rt.fam`, and every file can call them by their bare
names.

| Function | Meaning |
|---|---|
| `putc(c: u8)` | Write one byte to the console. |
| `print(s: *u8)` | Write a string. |
| `print_int(n: i32)` | Write a number in decimal. |
| `print_hex(n: u32)` | Write a number as `0x` and eight hex digits. |
| `getc() -> u8` | The next byte from the console. Waits until there is one. |
| `alloc(size: u32) -> *u8` | The address of a new piece of memory of that many bytes, on a 16-byte boundary. Nothing gives it back; running out is a panic. |
| `exit(code: i32)` | End the program with that exit code. |
| `panic(message: *u8)` | Write `panic: ` and the message, and exit with code 1. |

Names starting with `__` belong to the runtime.

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
fn add3(x: i32) -> i32 {
    asm { 13053500 }        // addi a0, a0, 3
}
```

- `@NAME` in it is a call of that function, and `&NAME` loads the
  function's id into `a0`. Arguments and the result are in `a0` to `a7` as
  usual; a call does not preserve `t0` to `t6` or `a0` to `a7`.
- If it is the first thing in a function, the arguments are still in `a0`
  to `a7`.
- What it leaves in `a0` is the function's result if the function ends
  there. Nothing checks it against the function's type.
- It may use `a0` to `a7` and `t0` to `t6`. It must leave `sp`, `s0` to
  `s11`, `gp` and `tp` as they were.

## Code that runs at startup

An `init` block at the top of a file runs once when the program starts,
before `main`:

```
init { print("starting\n"); }
```

- Init blocks run in the order written, file by file in the order the
  files are compiled.
- Its body is statements, as in a function that gives nothing. `return;`
  ends it.
- `init asm { ... }` is the same with nothing but the machine code given:
  no stack frame around it. The runtime's own startup code is written this
  way, because it runs before there is a stack.

## Comments

`//` starts a comment that runs to the end of the line.

## Errors

A compile error names the file and line and stops at the first problem:

```
prog.fam:3: unknown variable y
prog.fam:7: expected u8, found i32
```

## Limits

- About 500 locals and temporaries alive at once in one function.
- A function's code must stay under 1 MiB.

## Not yet

- Structs, arrays, integers of 64 bits, tagged unions and `match`.
- Character literals.
- Globals of more than one word, or that start as anything but a number;
  giving memory back.
- Checking that every path through a function that gives a value ends in
  a `return`.
- Macros defined by a program; `defer`; loops other than `while`.
- Operators as library functions: what `+` does for each type is still in
  the compiler.
