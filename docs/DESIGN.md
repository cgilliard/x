# Design rules

The rules the toolchain is built to. A change that breaks one of them is a
change to this file first.

## The rules

1. **`fam0.seed` is the root of trust.** It is the only binary in the
   repository. Everything in `bin/` is built from it and from source, and
   the build checks that the seed, given its own source, builds itself.

2. **The build needs almost nothing.** `scripts/build.sh` needs
   `qemu-system-riscv32`, a shell and `cat`. It never runs anything in
   `tools/`; those are for users. (The tests do run them, as a user would.)

3. **Each step is only strong enough to build the next.** The seed loads
   hex; the core (`src/fam.S`) is a minimal macro compiler; the compiler
   and the linker are written in the core's language. A lower step does
   not grow to make a higher one more convenient.

4. **No `jalr`.** Nothing the toolchain writes contains one: not the
   programs it compiles, and not its own. A call stores a return id and a
   return looks it up, so a return can only go to a real return site, and
   every path through a binary can be read from its bytes.

5. **The toolchain is deterministic.** The same inputs, in the same order,
   give the same bytes: on any host, with any amount of memory, today and
   later. Nothing a tool writes may depend on the time, the host, where
   things happen to be in memory, or anything else that is not its input.
   So anyone can rebuild from the seed and get the binaries bit for bit,
   and a proof about a binary is a proof about everyone's copy of it.

   The order of the inputs is part of the input: the linker lays functions
   out in the order it meets them. A driver must not take that order from
   something that varies between hosts, such as how a shell sorts names.

6. **Failures are loud.** A tool that cannot do its job says why and exits
   with 1; it does not write something that looks like a result. A limit
   that is reached is reported, not run past.

## To prove later

Properties to be proved rather than checked while running. None is proved
yet.

1. No word in `src/famc.forth` or `src/famld.forth` takes more off the
   data stack than was put on it.
2. Every write into a table in those programs is inside the table.

With rule 4 and rule 5, proofs can be about the binary itself, which
leaves the compiler out of what has to be trusted.
