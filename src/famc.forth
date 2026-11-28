\ src/famc.forth -- the fam compiler's front end (docs/LANGUAGE.md,
\ docs/OBJECT.md).
\
\ Reads one source file from the console (up to the byte 0x04) and writes
\ its object.  On an error it writes a message in place of the object and
\ exits with 1.
\
\ It is written in the Forth of lib/compiler.lib; scripts/build.sh has the
\ core compile the two together into bin/famc.
\
\ The language (every value is a 32-bit integer):
\     program   = [ "module" NAME ";" ]
\                 { import | constant | global | function | test | init }
\     import    = "import" NAME ";"
\     constant  = "const" NAME "=" value ";"    a name for a number, in this file
\     global    = [ "pub" ] "let" NAME "=" value ";"    a variable outside any
\                                               function, starting at value
\     value     = [ "-" ] ( NUMBER | NAME )     the name of a constant
\     function  = [ "pub" ] "fn" NAME "(" [ NAME { "," NAME } ] ")" block
\     test      = "test" STRING block
\     init      = "init" block                  run at startup, in order
\               | "init" "asm" "{" ... "}"      the same, nothing but the code
\     block     = "{" { statement } "}"
\     statement = "let" NAME "=" expr ";"
\               | [ NAME "." ] NAME "=" expr ";"
\               | "if" expr block [ "else" ( block | if-statement ) ]
\               | "while" expr block
\               | "return" [ expr ] ";"
\               | "asm" "{" { HEXWORD | "@" fname | "&" fname } "}"
\               | "assert" expr ";"             in a test
\               | expr ";"
\     expr      = unary { OPERATOR unary }      by precedence, lowest first:
\                   ||   &&   == != < <= > >=   |   ^   &   << >>   + -
\                   * / %
\     unary     = ( "-" | "!" | "~" ) unary | NUMBER | STRING | [ NAME "." ] NAME
\               | "&" fname                     a function's id
\               | "bytes" "{" { HEXBYTES } "}"  data: its value is its address
\               | fname "(" [ expr { "," expr } ] ")"
\               | "(" expr ")"
\     fname     = [ NAME "." ] NAME
\     NAME      = a letter or '_', then letters, digits, '_'
\     NUMBER    = decimal digits, or 0x and hex digits (up to 32 bits)
\     STRING    = "..." with \n \t \0 \\ \" for a newline, a tab, a zero
\                 byte, a backslash and a quote: its value is its address
\     HEXWORD   = eight uppercase hex digits: four bytes of code
\     HEXBYTES  = uppercase hex digits, two for each byte
\     // starts a comment that runs to the end of the line
\
\ The code it writes (docs/OBJECT.md, "Calling convention"):
\   - A function keeps a frame, with s0 pointing at its top:
\         -4(s0)              the caller's s0
\         -8-4*i(s0)          slot i: a parameter, a local or a temporary
\         0(sp) ...           the ninth and later arguments of calls it makes
\     Slots are handed out as a stack while compiling: a `let` takes one
\     until its block ends, a temporary until it is used.
\   - An expression leaves its value in a0.  An operator saves its left
\     side in a temporary, computes the right side, and reloads the left
\     into a1.
\   - `*`, `/` and `%` are calls of __mul, __div and __rem (lib/rt.fam):
\     the CPU has no instructions for them.
\   - A string's bytes, and a zero byte, sit in the code where it is used,
\     behind a `jal a0` that jumps over them and so leaves their address.
\     `bytes { ... }` is laid down the same way, without the zero byte.
\   - `&f` is an id site: the linker fills in the two instructions that
\     load f's id.  A call `p(...)` where p is a local is a call through an
\     id: a call of __call, which the linker writes, with the id in t2.
\   - load8, load32, store8 and store32 are not calls but one instruction
\     each, on a0 (and a1).
\   - In `asm`, `@f` is a call site for f and `&f` an id site.
\   - A global is a data record: one word, its starting value.  Reading or
\     writing it is an address site -- the linker fills in the two
\     instructions that load its address into a0 -- and a load or a store.
\     A constant is its number wherever it is named.
\   - An `init` block is an init record with a frame, like a function's.
\     `init asm` has no frame: it is for the startup code, which runs
\     before there is a stack.
\   - `return` jumps to the code at the function's end that drops the
\     frame.  A function that runs off its end returns whatever is in a0.
\
\ Modules.  A function `f` of a file that says `module m;` is the symbol
\ `m.f`; without a module line it is `f` (the root module).  It is a local
\ symbol, which only this object can call, unless it is `pub` (or is the
\ root's `main`, in a build that is not for the tests).  A call `m.f()` is
\ of the symbol `m.f`, and m must be this file's module or imported.  A
\ call `f()` in module m is of this file's `m.f` if it defines one, else of
\ the root's `f`: it is noted as a symbol `f` of kind 0x100, and `resolve`
\ settles it when the whole file has been read.  A global `g` is the symbol
\ `m.g` likewise, local unless `pub`.  It must be defined above where it is
\ used by its bare name; another module's is `m.g`, and needs no more.
\
\ The file's name.  If the source starts with the byte 0x01 or 0x02, that
\ and the rest of its first line are not source: the line is the file's
\ name, as tools/famc sends it.  Errors are then reported as
\ "NAME:LINE: what"; without a name, as "famc: line LINE: what".
\
\ Tests.  If that first byte is 0x01, the tests are wanted
\ (`tools/famc --test`).  Each test block then becomes an init record, so
\ it runs at startup, in order (lib/rt.fam has the functions):
\         __test_begin(name, file)
\         the block: a failed assert calls __test_fail(line) and jumps
\         to the end, as `return` does
\         __test_end()
\ Otherwise test blocks are skipped.


\ ---- the source, and where we are in it ----------------------------------

: cur    variable ;    \ where we are in the source
: send   variable ;    \ where the source ends
: line   variable ;    \ the line of the token last read
: tk     variable ;    \ the token last read: where it starts,
: tl     variable ;    \   its length,
: kind   variable ;    \   and its kind: 0 the end of the source, 1 a name,
                       \   2 a number, 3 punctuation, 4 a string
: file   variable ;    \ the file's name (0: not given),
: fend   variable ;    \   and where it ends
: mode   variable ;    \ 1 if the tests are wanted

: modn   variable ;    \ this file's module,
: modl   variable ;    \   and its length (0: the root module)


\ ---- errors: where, what, a newline, exit code 1 --------------------------

: fail   ( -- )   A lit putc die ;

: where  ( -- )
   file @ if
      file @ fend @ over - type  3A lit putc  line @ u.
   else
      "famc: line " puts  line @ u.
   then
   ": " puts ;

: tok.   ( -- )   tk @ tl @ type ;

: syntax    ( -- )
   where
   kind @ if "unexpected " puts tok. else "unexpected end of file" puts then
   fail ;
: enum      ( -- )   where "bad number " puts tok. fail ;
: etoken    ( -- )   where "bad hex word " puts tok. fail ;
: edup      ( name len -- )   where "defined twice: " puts type fail ;
: eunknown  ( name len -- )   where "unknown variable " puts type fail ;
: emodule   ( name len -- )   where "unknown module " puts type fail ;
: estr      ( -- )   where "string without its closing quote" puts fail ;
: eescape   ( -- )   where "unknown \\ in a string" puts fail ;
: emodfst   ( -- )   where "module must come first, and once" puts fail ;
: elong     ( -- )   where "name too long" puts fail ;
: eargs     ( -- )   where "wrong number of arguments" puts fail ;
: eassert   ( -- )   where "assert outside a test" puts fail ;
: econst    ( -- )   where "cannot assign to a constant" puts fail ;
: elocals   ( -- )   where "function needs too many locals" puts fail ;
: edeep     ( -- )   where "nested too deep" puts fail ;
: efar      ( -- )   where "function too large" puts fail ;
: ebig      ( -- )   "famc: out of memory" puts fail ;

: need  ( n -- addr )   alloc dup 0= if ebig then ;


\ ---- the object being written (docs/OBJECT.md) ----------------------------

\ Its symbols, 20 bytes each: kind, where its name starts in the names,
\ the name's length, where its code starts in the code, the code's size.
: syb    variable ;
: syn    variable ;    \ the next free one
: sylim  variable ;
: nsy    variable ;    \ how many there are

\ Its call sites, 8 bytes each: where in the code, the symbol's index.
: clb    variable ;
: cln    variable ;
: cllim  variable ;

\ Its code.
: cb     variable ;
: cn     variable ;    \ where the next word goes
: clim   variable ;

\ Its names.
: nb     variable ;
: nn     variable ;
: nlim   variable ;

: rec    variable ;    \ the symbol of the record being written

\ zeq  is a name the same as a text that ends with a zero byte?
: zeq  ( name len text -- flag )
   swap 0 lit
   begin 2dup > while
      3 lit pick over + c@  3 lit pick 2 lit pick + c@ <> if
         2drop 2drop 0 lit exit
      then
      1+
   repeat
   drop + c@ 0= nip ;

\ Finding a symbol by name: 4096 lists of symbols, a name's hash saying
\ which list it is in.  hb is the first of each list and hn the one after
\ each symbol, both as an index + 1 (0: no more).
: hb     variable ;
: hn     variable ;
: hslot  variable ;    \ for a new symbol: its list (0: it has no name)

: hash  ( name len -- n )
   0 lit -rot
   begin dup while
      rot dup 5 lit lshift + 2 lit pick c@ + -rot
      swap 1+ swap 1-
   repeat
   2drop FFF lit and ;

\ ofind  the symbol of a name (0: none) and its index (none: the count).
: ofind  ( name len -- sym index )
   2dup hash 2 lit lshift hb @ + @
   begin dup while
      1-
      dup 4 lit lshift over 2 lit lshift + syb @ +       \ name len index sym
      dup 8 lit + @ 3 lit pick = if
         dup 4 lit + @ nb @ +  4 lit pick 4 lit pick same if
            swap rot drop rot drop exit
         then
      then
      drop
      2 lit lshift hn @ + @
   repeat
   drop 2drop 0 lit nsy @ ;

\ onew  a new symbol with no code (the length may be 0: no name).
: onew  ( name len kind -- sym index )
   syn @ 14 lit + sylim @ u> if ebig then
   nn @ 2 lit pick + nlim @ u> if ebig then
   over 0= if
      0 lit hslot !
   else
      2 lit pick 2 lit pick hash 2 lit lshift hb @ + hslot !
   then
   syn @
   tuck !
   nn @ nb @ - over 4 lit + !
   2dup 8 lit + !
   0 lit over C lit + !  0 lit over 10 lit + !
   -rot
   begin dup while
      over c@ nn @ c!  nn @ 1+ nn !
      swap 1+ swap 1-
   repeat 2drop
   syn @ 14 lit + syn !
   hslot @ if                                \ first in its list
      hslot @ @  nsy @ 2 lit lshift hn @ + !
      nsy @ 1+ hslot @ !
   then
   nsy @ dup 1+ nsy ! ;

\ odefine  start the record of a function (kind 1, or 3 for a local one)
\ or of a global (4, or 5); its symbol, or 0 if the name is defined already.
: odefine  ( name len kind -- sym )
   -rot 2dup ofind
   drop dup if
      nip nip
      dup @ if 2drop 0 lit exit then
      tuck !                                 \ called earlier: now defined
   else
      drop rot onew drop
   then
   cn @ cb @ - over C lit + !
   dup rec ! ;

\ oinit  start an init record.
: oinit  ( -- )
   0 lit 0 lit 2 lit onew drop
   cn @ cb @ - over C lit + !
   rec ! ;

\ oend  end the record: its code is what was appended since it started.
: oend  ( -- )
   cn @ cb @ - rec @ C lit + @ -  rec @ 10 lit + !
   0 lit rec ! ;

\ cw,  append a word to the code.
: cw,  ( word -- )
   cn @ dup clim @ u>= if ebig then
   tuck !  4 lit + cn ! ;

\ oref  the index of the symbol of a name: a new one, of the kind given
\ (0: external until defined), if the name is new.
: oref  ( name len kind -- index )
   -rot 2dup ofind over if nip nip nip nip exit then
   2drop rot onew nip ;

\ osite  append a call of a symbol: a call site and its 16 zero bytes.
: osite  ( index -- )
   cln @ 8 lit + cllim @ u> if ebig then
   cn @ cb @ - cln @ !  cln @ 4 lit + !  cln @ 8 lit + cln !
   4 lit begin dup while 0 lit cw, 1- repeat drop ;

\ oidsite  append the loading of a function's id into a0: an id site (the
\ index's top bit set) and its 8 zero bytes.
: oidsite  ( index -- )
   cln @ 8 lit + cllim @ u> if ebig then
   cn @ cb @ - cln @ !  80000000 lit or cln @ 4 lit + !  cln @ 8 lit + cln !
   0 lit cw,  0 lit cw, ;

\ oasite  append the loading of a global's address into a0: an address
\ site (the index's next-to-top bit set) and its 8 zero bytes.
: oasite  ( index -- )
   cln @ 8 lit + cllim @ u> if ebig then
   cn @ cb @ - cln @ !  40000000 lit or cln @ 4 lit + !  cln @ 8 lit + cln !
   0 lit cw,  0 lit cw, ;

\ ocall  append a call of a function by name.
: ocall  ( name len -- )   0 lit oref osite ;

\ owrite  write the object: header, symbols, call sites, code, names.
: putw  ( word -- )
   dup putc  dup 8 lit rshift putc  dup 10 lit rshift putc  18 lit rshift putc ;
: region  ( from to -- )
   begin 2dup u< while over c@ putc swap 1+ swap repeat 2drop ;
: owrite  ( -- )
   begin nn @ nb @ - 3 lit and while         \ the names: up to a whole word
      nn @ nlim @ u>= if ebig then
      0 lit nn @ c!  nn @ 1+ nn !
   repeat
   4F4D4146 lit putw                         \ FAMO
   3 lit putw
   syn @ syb @ -  cln @ clb @ - +  cn @ cb @ - +  nn @ nb @ - +  1C lit + putw
   nsy @ putw
   cln @ clb @ - 3 lit rshift putw
   cn @ cb @ - putw
   nn @ nb @ - putw
   syb @ syn @ region  clb @ cln @ region  cb @ cn @ region  nb @ nn @ region ;


\ ---- names of other modules ----------------------------------------------

\ The modules imported, 8 bytes each: name, length.
: ibase  variable ;
: itop   variable ;
: ilim   variable ;

: scr    variable ;    \ room to spell one `module.name`
: jp     variable ;    \   and where the next byte of it goes

: cpy  ( from len -- )
   begin dup while
      over c@ jp @ c!  jp @ 1+ jp !
      swap 1+ swap 1-
   repeat 2drop ;

\ join  `module.name`, spelled in the room kept for that.
: join  ( module mlen name len -- name' len' )
   2 lit pick over + FE lit u> if elong then
   scr @ jp !
   3 lit pick 3 lit pick cpy
   2E lit jp @ c!  jp @ 1+ jp !
   cpy
   2drop
   scr @ jp @ over - ;

\ qualify  the symbol of a name in this file's module: `module.name`, or
\ the name itself in the root module.
: qualify  ( name len -- name' len' )
   modl @ 0= if exit then
   modn @ -rot modl @ -rot join ;

: nameq  ( a alen b blen -- flag )
   rot over <> if 2drop drop 0 lit exit then
   same ;

\ chkmod  a name must be this file's module or one it imports.
: chkmod  ( name len -- )
   2dup modn @ modl @ nameq if 2drop exit then
   ibase @
   begin dup itop @ u< while
      2 lit pick 2 lit pick 2 lit pick dup @ swap 4 lit + @ nameq if
         drop 2drop exit
      then
      8 lit +
   repeat
   drop emodule ;

\ resolve  at the end of a file with a module: settle the calls by a bare
\ name (symbols of kind 0x100).  If the file defines `module.name`, the
\ calls go to that, and the bare name is left as an external nothing calls;
\ else the bare name is the root's.
: resolve  ( -- )
   modl @ 0= if exit then
   syb @ begin dup syn @ u< while            \ each such symbol: 0x200 and
      dup @ 100 lit = if                     \   the index to use instead,
         0 lit over !                        \   or external
         dup 4 lit + @ nb @ +  over 8 lit + @  qualify ofind
         over 0= if 2drop else
            over @ 0= if 2drop else
               nip
               200 lit 2 lit pick !
               over C lit + !
            then
         then
      then
      14 lit +
   repeat drop
   clb @ begin dup cln @ u< while            \ each call site: follow a 0x200
      dup 4 lit + @
      dup C0000000 lit and  swap 3FFFFFFF lit and
      dup 4 lit lshift swap 2 lit lshift + syb @ +
      dup @ 200 lit = if
         C lit + @ or over 4 lit + !
      else
         2drop
      then
      8 lit +
   repeat drop
   syb @ begin dup syn @ u< while            \ and the 0x200s become externals
      dup @ 200 lit = if 0 lit over !  0 lit over C lit + ! then
      14 lit +
   repeat drop ;


\ ---- reading tokens -------------------------------------------------------

\ cls  the class of a byte: 2 a digit, 1 a letter or '_', 0 other.
: cls  ( byte -- class )
   dup 30 lit < if drop 0 lit exit then
   dup 39 lit <= if drop 2 lit exit then
   dup 41 lit < if drop 0 lit exit then
   dup 5A lit <= if drop 1 lit exit then
   dup 5F lit = if drop 1 lit exit then
   dup 61 lit < if drop 0 lit exit then
   7A lit <= if 1 lit else 0 lit then ;

\ skipws  move on to the start of a token, or to the end, over spaces and
\ // comments, counting the lines.
: skipws  ( -- )
   begin
      cur @ send @ u>= if exit then
      cur @ c@
      dup A lit = if line @ 1+ line ! then
      dup 20 lit u<= if
         drop  cur @ 1+ cur !  0 lit
      else
         2F lit =  cur @ 1+ send @ u<  and if
            cur @ 1+ c@ 2F lit = if
               begin
                  cur @ 1+ cur !
                  cur @ send @ u>= if exit then
                  cur @ c@ A lit =
               until
               0 lit
            else
               -1 lit
            then
         else
            -1 lit
         then
      then
   until ;

\ lex  read the next token.  Punctuation is one character, or one of
\ == != <= >= << >> && ||.  A string is quotes and all.  To leave a token
\ unread:  tk @ cur !
: lex  ( -- )
   skipws
   cur @ tk !
   cur @ send @ u>= if 0 lit tl !  0 lit kind !  exit then
   cur @ c@ dup cls
   dup if                                    \ a number or a name: while
      kind ! drop                            \   letters, digits, '_' follow
      begin
         cur @ 1+ cur !
         cur @ send @ u>= if -1 lit else cur @ c@ cls 0= then
      until
      cur @ tk @ - tl !  exit
   then
   drop
   dup 22 lit = if                           \ a string: to its closing
      drop  4 lit kind !                     \   quote, on this line
      begin
         cur @ 1+ cur !
         cur @ send @ u>= if estr then
         cur @ c@
         dup A lit = if estr then
         dup 5C lit = if                     \ a backslash takes the next
            drop  cur @ 1+ cur !             \   with it
            cur @ send @ u>= if estr then
            cur @ c@ A lit = if estr then
            0 lit
         else
            22 lit =
         then
      until
      cur @ 1+ cur !
      cur @ tk @ - tl !  exit
   then
   3 lit kind !
   cur @ 1+ cur !
   cur @ send @ u< if
      cur @ c@                               \ the character after it
      dup 3D lit = if                        \ == != <= >=
         drop
         dup 3D lit =  over 21 lit = or  over 3C lit = or  over 3E lit = or
         if cur @ 1+ cur ! then
      else
         over = if                           \ << >> && ||
            dup 3C lit =  over 3E lit = or  over 26 lit = or  over 7C lit = or
            if cur @ 1+ cur ! then
         then
      then
   then
   drop
   cur @ tk @ - tl ! ;

: is  ( text -- flag )   tk @ tl @ rot zeq ;

\ expect  read a token: it must be this punctuation character.
: expect  ( char -- )
   lex
   kind @ 3 lit <> if syntax then
   tl @ 1 lit <> if syntax then
   tk @ c@ <> if syntax then ;

\ chkident  the token must be a name, and not a keyword.
: chkident  ( -- )
   kind @ 1 lit <> if syntax then
   "return" is if syntax then   "assert" is if syntax then
   "while" is if syntax then    "fn" is if syntax then
   "if" is if syntax then       "let" is if syntax then
   "asm" is if syntax then      "else" is if syntax then
   "const" is if syntax then ;

\ chkdeep  stop, with a message, before calls nested too deep stop us.
: chkdeep  ( -- )   rfree 800 lit u< if edeep then ;

\ parsenum  the value of the number token: decimal digits, or 0x and one
\ to eight hex digits.
: parsenum  ( -- value )
   tl @ 2 lit u> if tk @ 1+ c@ 78 lit = if
      tk @ c@ 30 lit <> if enum then
      tl @ A lit u> if enum then
      0 lit 2 lit
      begin dup tl @ u< while
         tk @ over + c@
         dup 30 lit - A lit u< if
            30 lit -
         else
            20 lit or 61 lit -               \ a letter, either case
            dup 6 lit u>= if enum then
            A lit +
         then
         rot 4 lit lshift or swap 1+
      repeat
      drop exit
   then then
   0 lit 0 lit
   begin dup tl @ u< while
      tk @ over + c@ 30 lit -
      dup A lit u>= if enum then
      2 lit pick 1999999A lit u>= if enum then      \ 10 times it would not fit
      rot dup 3 lit lshift swap 1 lit lshift +
      tuck +  dup rot u< if enum then
      swap 1+
   repeat
   drop ;

\ hexd  the value of an uppercase hex digit of the token.
: hexd  ( char -- value )
   dup 30 lit - A lit u< if 30 lit - exit then
   41 lit - dup 6 lit u>= if etoken then
   A lit + ;

\ hexword  the word the token spells as eight uppercase hex digits in
\ memory order: the first two digits are the lowest byte.
: hexword  ( -- word )
   tl @ 8 lit <> if etoken then
   0 lit 0 lit                               \ word i
   begin dup 4 lit < while
      tk @ over 1 lit lshift +
      dup c@ hexd 4 lit lshift swap 1+ c@ hexd or
      over 3 lit lshift lshift
      rot or swap 1+
   repeat
   drop ;


\ ---- constants and globals ------------------------------------------------

\ The file's constants and globals, 16 bytes each: name, length, 0 for a
\ constant or 1 for a global, and the constant's value or the index of the
\ global's symbol.
: gb     variable ;
: gn     variable ;
: glim   variable ;

\ gfind  the entry of a name (0: none).
: gfind  ( name len -- entry )
   gb @
   begin dup gn @ u< while
      dup 4 lit + @ 2 lit pick = if
         dup @ 3 lit pick 3 lit pick same if nip nip exit then
      then
      10 lit +
   repeat
   drop 2drop 0 lit ;

: gadd  ( name len kind value -- )
   gn @ dup 10 lit + glim @ u> if ebig then
   tuck C lit + !  tuck 8 lit + !  tuck 4 lit + !  tuck !
   10 lit + gn ! ;

\ constval  read [ "-" ] ( NUMBER | NAME ): a number, or a constant's.
: constval  ( -- value )
   lex
   0 lit
   kind @ 3 lit =  tl @ 1 lit =  and if
      tk @ c@ 2D lit = if drop 1 lit lex then
   then
   kind @ 2 lit = if
      parsenum
   else
      kind @ 1 lit <> if syntax then
      tk @ tl @ 2dup gfind
      dup 0= if drop eunknown then
      nip nip
      dup 8 lit + @ if syntax then           \ a global is not a constant
      C lit + @
   then
   swap if 0 lit swap - then ;


\ ---- a function's frame ---------------------------------------------------

: vcur   variable ;    \ slots in use
: vmax   variable ;    \ the most slots in use at once in this function
: vout   variable ;    \ the most stack arguments a call in it passes
: vret   variable ;    \ its last `return` jump, to patch (0: none): each
                       \   holds the address of the one before
: vpro   variable ;    \ where its first three instructions are
: vtest  variable ;    \ 1 while compiling a test block

\ The locals in scope, 12 bytes each: name, length, slot.
: lbase  variable ;
: ltop   variable ;
: llim   variable ;

: slotnew  ( -- slot )
   vcur @ dup 1+
   dup 1F4 lit u> if elocals then
   dup vcur !
   dup vmax @ u> if vmax ! else drop then ;

\ slotdrop  give back the last n slots: the lowest of them.
: slotdrop  ( n -- slot )   vcur @ swap - dup vcur ! ;

: ladd  ( name len slot -- )
   ltop @ dup C lit + llim @ u> if ebig then
   tuck 8 lit + !  tuck 4 lit + !  tuck !
   C lit + ltop ! ;

\ llook  the slot of the local of a name, the latest if several (-1: none).
: llook  ( name len -- slot )
   ltop @
   begin dup lbase @ u> while
      C lit -
      dup 4 lit + @ 2 lit pick = if
         dup @ 3 lit pick 3 lit pick same if 8 lit + @ nip nip exit then
      then
   repeat
   drop 2drop -1 lit ;

: lfind  ( name len -- slot )
   2dup llook dup 0< if drop eunknown then nip nip ;


\ ---- writing instructions -------------------------------------------------

\ esw  append `sw <register>, <slot>(s0)`.  A slot's offset is -8 - 4*slot.
: esw  ( slot register -- )
   14 lit lshift swap
   2 lit lshift 8 lit + 0 lit swap -
   dup 5 lit rshift 7F lit and 19 lit lshift
   swap 1F lit and 7 lit lshift or or
   00042023 lit or cw, ;

\ elw  append `lw <register>, <slot>(s0)`.
: elw  ( slot register -- )
   7 lit lshift swap
   2 lit lshift 8 lit + 0 lit swap - 14 lit lshift or
   00042003 lit or cw, ;

\ ejph  append a jump to be patched: where it is.
: ejph  ( -- slot )   6F lit cw,  cn @ 4 lit - ;

\ patchjl  make the instruction at slot `jal`, with the low 12 bits given
\ (its register), to an address.
: patchjl  ( slot target low -- )
   -rot over -                               \ low slot distance
   dup 100000 lit + 200000 lit u>= if efar then
   dup 14 lit rshift 1 lit and 1F lit lshift
   over 1 lit rshift 3FF lit and 15 lit lshift or
   over B lit rshift 1 lit and 14 lit lshift or
   swap C lit rshift FF lit and C lit lshift or
   rot or swap ! ;

: patchj  ( slot target -- )   6F lit patchjl ;

\ lia0  append the code that loads a value into a0: one `addi a0,zero,v`
\ if it fits 12 signed bits, else `lui` and `addi`.
: lia0  ( value -- )
   dup -2048 lit <  over 7FF lit >  or if
      dup 800 lit + C lit rshift C lit lshift 537 lit or cw,
      14 lit lshift 50513 lit or cw,
   else
      14 lit lshift 513 lit or cw,
   then ;

\ Bytes laid down in the code, four to a word.
: swd   variable ;     \ the word being filled
: scnt  variable ;     \ how many bytes it has
: sbyte  ( byte -- )
   scnt @ 3 lit lshift lshift swd @ or swd !
   scnt @ 1+ dup scnt !
   4 lit = if swd @ cw,  0 lit swd !  0 lit scnt ! then ;

\ estring  append `jal a0, <past it>`, the bytes of a string's text (as
\ written, with its \ escapes), a zero byte, and zero bytes up to a whole
\ word: code that leaves the string's address in a0.
: sa  variable ;
: se  variable ;
: estring  ( from to -- )
   se ! sa !
   56F lit cw,  cn @ 4 lit -                 \ the jal
   0 lit swd !  0 lit scnt !
   begin sa @ se @ u< while
      sa @ c@  sa @ 1+ sa !
      dup 5C lit = if                        \ a backslash: the next says what
         drop  sa @ c@  sa @ 1+ sa !
         dup 5C lit =  over 22 lit =  or if else
            dup 6E lit = if drop A lit else
               dup 74 lit = if drop 9 lit else
                  30 lit = if 0 lit else eescape 0 lit then
               then
            then
         then
      then
      sbyte
   repeat
   0 lit sbyte
   scnt @ if swd @ cw, then
   cn @ 56F lit patchjl ;

\ ebytes  bytes { HEXBYTES ... }: as a string, without the zero byte.
: ebytes  ( -- )
   56F lit cw,  cn @ 4 lit -
   0 lit swd !  0 lit scnt !
   begin
      lex
      kind @ 0= if syntax then
      kind @ 3 lit = if
         tk @ c@ 7D lit <> if syntax then
         -1 lit
      else
         tl @ 1 lit and if etoken then       \ hex digits, in pairs
         tk @ begin dup tk @ tl @ + u< while
            dup c@ hexd 4 lit lshift over 1+ c@ hexd or sbyte
            2 lit +
         repeat drop
         0 lit
      then
   until
   scnt @ if swd @ cw, then
   cn @ 56F lit patchjl ;

\ fnref  read [ module "." ] name: the index of that function's symbol, as
\ a call would name it.
: fnref  ( -- index )
   lex chkident
   tk @ tl @
   lex
   kind @ 3 lit = if tk @ c@ 2E lit = else 0 lit then if
      2dup chkmod
      lex chkident
      tk @ tl @ join 0 lit oref exit
   then
   tk @ cur !                                \ a bare name
   modl @ if 100 lit else 0 lit then oref ;

\ asmbody  "{" { HEXWORD | "@" fname | "&" fname } "}": the words as they
\ are, a call site, an id site.
: asmbody  ( -- )
   7B lit expect
   begin
      lex
      kind @ 0= if syntax then
      kind @ 3 lit = if
         tk @ c@
         dup 7D lit = if drop -1 lit else
            dup 40 lit = if drop fnref osite 0 lit else
               26 lit =  tl @ 1 lit =  and 0= if syntax then
               fnref oidsite 0 lit
            then
         then
      else
         hexword cw, 0 lit
      then
   until ;

\ binop  is the token a binary operator?  Its precedence (0: it is not
\ one) and its one or two instructions, which compute a0 from a1 (the left
\ side) and a0 (the right); the second is 0 if there is only one.  For
\ * / % the first is 1, 2, 3: they are calls.
: bprec  variable ;
: bw1    variable ;
: bw2    variable ;
: bset  ( precedence w1 w2 -- )   bw2 ! bw1 ! bprec ! ;
: binop  ( -- )
   0 lit bprec !
   kind @ 3 lit <> if exit then
   "||" is if 1 lit 0 lit 0 lit bset exit then
   "&&" is if 2 lit 0 lit 0 lit bset exit then
   "==" is if 3 lit 40A58533 lit 00153513 lit bset exit then    \ sub a0,a1,a0 ; seqz a0,a0
   "!=" is if 3 lit 40A58533 lit 00A03533 lit bset exit then    \ sub a0,a1,a0 ; snez a0,a0
   "<"  is if 3 lit 00A5A533 lit 0 lit bset exit then           \ slt a0,a1,a0
   ">"  is if 3 lit 00B52533 lit 0 lit bset exit then           \ slt a0,a0,a1
   "<=" is if 3 lit 00B52533 lit 00154513 lit bset exit then    \ slt a0,a0,a1 ; xori a0,a0,1
   ">=" is if 3 lit 00A5A533 lit 00154513 lit bset exit then    \ slt a0,a1,a0 ; xori a0,a0,1
   "|"  is if 4 lit 00A5E533 lit 0 lit bset exit then           \ or  a0,a1,a0
   "^"  is if 5 lit 00A5C533 lit 0 lit bset exit then           \ xor a0,a1,a0
   "&"  is if 6 lit 00A5F533 lit 0 lit bset exit then           \ and a0,a1,a0
   "<<" is if 7 lit 00A59533 lit 0 lit bset exit then           \ sll a0,a1,a0
   ">>" is if 7 lit 40A5D533 lit 0 lit bset exit then           \ sra a0,a1,a0
   "+"  is if 8 lit 00A58533 lit 0 lit bset exit then           \ add a0,a1,a0
   "-"  is if 8 lit 40A58533 lit 0 lit bset exit then           \ sub a0,a1,a0
   "*"  is if 9 lit 1 lit 0 lit bset exit then                  \ __mul
   "/"  is if 9 lit 2 lit 0 lit bset exit then                  \ __div
   "%"  is if 9 lit 3 lit 0 lit bset exit then ;                \ __rem


\ ---- statements and expressions ------------------------------------------

\ They call each other every which way, and a word here can only call one
\ defined above it, or itself.  So they are one word, `parse`, that is told
\ which of them to be:
\     min 0 parse      an expression, of operators of precedence min and up
\     x 1 parse        a unary
\     x 2 parse        a block
\     x 3 parse        a statement
\     sym how 4 parse  the arguments of a call and the call: see below
:M expr    0 lit parse ;
:M unary   0 lit 1 lit parse ;
:M block   0 lit 2 lit parse ;
:M stmt    0 lit 3 lit parse ;

: tslot  variable ;
: qn     variable ;    \ the name after a `module .`,
: ql     variable ;    \   and its length

\ gstore  append the storing of a0 in the global of a symbol.
: gstore  ( index -- )
   00050393 lit cw,                          \ mv t2, a0
   oasite
   00752023 lit cw, ;                        \ sw t2, 0(a0)

: parse  ( arg which -- )
   chkdeep

   \ ---- the arguments of a call, and the call.  The ( is read.
   \ how > 0: through an id, kept in the slot how - 1
   \ how < 0: one of the four built in, load8 load32 store8 store32
   \ how = 0: of the symbol whose index is sym
   \ Each argument's value goes into a temporary; then the first eight
   \ into a0 to a7 and the rest into the frame's low end; then the call.
   dup 4 lit = if
      drop
      0 lit                                  \ sym how n
      lex
      kind @ 3 lit = if tk @ c@ 29 lit = else 0 lit then 0= if
         tk @ cur !
         begin
            1 lit expr
            slotnew A lit esw
            1+
            lex
            kind @ 3 lit <> if syntax then
            tk @ c@ dup 2C lit = if
               drop 0 lit
            else
               29 lit <> if syntax then
               -1 lit
            then
         until
      then
      dup slotdrop                           \ sym how n first
      0 lit                                  \ sym how n first k
      begin dup 3 lit pick < while
         2dup +                              \ its slot
         over 8 lit < if
            over A lit + elw                 \ lw a<k>, slot
         else
            7 lit elw                        \ lw t2, slot
            dup 8 lit - 2 lit lshift         \ sw t2, 4*(k-8)(sp)
            dup 5 lit rshift 19 lit lshift  swap 1F lit and 7 lit lshift  or
            00712023 lit or cw,
         then
         1+
      repeat
      2drop                                  \ sym how n
      dup 8 lit - vout @ > if dup 8 lit - vout ! then
      over 0= if                             \ a call of a symbol
         2drop osite exit
      then
      over 0< if                             \ built in: one instruction
         swap 0 lit swap -                   \ sym n which
         dup 1 lit = if drop 1 lit 00054503 lit else         \ lbu a0, 0(a0)
            dup 2 lit = if drop 1 lit 00052503 lit else      \ lw  a0, 0(a0)
               3 lit = if 2 lit 00B50023 lit else            \ sb  a1, 0(a0)
                  2 lit 00B52023 lit                         \ sw  a1, 0(a0)
               then
            then
         then                                \ sym n want word
         -rot <> if eargs then
         cw, drop exit
      then
      drop 1- 7 lit elw                      \ through an id: lw t2, <slot>
      drop
      "__call" 6 lit ocall
      exit
   then

   \ ---- a unary
   dup 1 lit = if
      2drop
      lex
      kind @ 2 lit = if parsenum lia0 exit then
      kind @ 4 lit = if tk @ 1+  tk @ tl @ + 1-  estring exit then
      kind @ 1 lit = if
         chkident
         tk @ tl @                           \ name len
         lex                                 \ a call if ( or . follows
         kind @ 3 lit = if
            tk @ c@
            dup 28 lit = if                  \ name (
               drop
               2dup llook dup 0< if          \ not a local holding an id
                  drop
                  2dup "load8" zeq if 2drop 0 lit -1 lit else
                     2dup "load32" zeq if 2drop 0 lit -2 lit else
                        2dup "store8" zeq if 2drop 0 lit -3 lit else
                           2dup "store32" zeq if 2drop 0 lit -4 lit else
                              modl @ if 100 lit else 0 lit then oref 0 lit
                           then
                        then
                     then
                  then
               else
                  nip nip 1+ 0 lit swap
               then
               4 lit parse exit
            then
            dup 2E lit = if                  \ module . name: a call if (
               drop                          \   follows, else a global
               2dup chkmod
               lex chkident
               tk @ tl @ join 0 lit oref
               lex
               kind @ 3 lit = if tk @ c@ 28 lit = else 0 lit then if
                  0 lit 4 lit parse exit
               then
               tk @ cur !
               oasite  00052503 lit cw,      \ lw a0, 0(a0)
               exit
            then
            7B lit = if                      \ bytes { ... } ?
               2dup "bytes" zeq if 2drop ebytes exit then
            then
         then
         tk @ cur !                          \ else a local, a global or a
         2dup llook dup 0< 0= if             \   constant
            nip nip A lit elw exit
         then
         drop
         2dup gfind dup 0= if drop eunknown then
         nip nip
         dup 8 lit + @ if
            C lit + @ oasite  00052503 lit cw,          \ lw a0, 0(a0)
         else
            C lit + @ lia0
         then
         exit
      then
      kind @ 0= if syntax then
      tl @ 1 lit <> if syntax then
      tk @ c@
      dup 28 lit = if drop  1 lit expr  29 lit expect  exit then
      dup 2D lit = if drop  unary  40A00533 lit cw,  exit then     \ neg a0, a0
      dup 21 lit = if drop  unary  00153513 lit cw,  exit then     \ seqz a0, a0
      dup 7E lit = if drop  unary  FFF54513 lit cw,  exit then     \ not a0, a0
      26 lit = if fnref oidsite exit then                          \ & fname
      syntax
   then

   \ ---- a block: "{" { statement } "}".  The locals and slots of its
   \ `let`s go when it ends.
   dup 2 lit = if
      2drop
      7B lit expect
      ltop @ vcur @
      begin
         lex
         kind @ 3 lit = if tk @ c@ 7D lit = else 0 lit then
      0= while
         tk @ cur !
         stmt
      repeat
      vcur ! ltop !
      exit
   then

   \ ---- a statement
   dup 3 lit = if
      2drop
      lex
      kind @ 1 lit = if
         "let" is if                         \ let NAME = expr
            lex chkident
            tk @ tl @
            3D lit expect
            1 lit expr
            3B lit expect
            slotnew dup tslot ! ladd         \ in scope from here on, not in
            tslot @ A lit esw                \   its own expression
            exit
         then
         "if" is if                          \ if expr block [ else ... ]
            1 lit expr
            00051463 lit cw,                 \ bnez a0, +8
            ejph                             \ j <past the block>
            block
            lex
            kind @ 1 lit = if "else" is else 0 lit then if
               ejph swap cn @ patchj         \ j <past the else part>
               lex  tk @ cur !
               kind @ 1 lit = if "if" is else 0 lit then if stmt else block then
            else
               tk @ cur !
            then
            cn @ patchj
            exit
         then
         "asm" is if asmbody exit then
         "while" is if                       \ while expr block
            cn @
            1 lit expr
            00051463 lit cw,                 \ bnez a0, +8
            ejph                             \ j <past the block>
            block
            ejph rot patchj                  \ j <the condition>
            cn @ patchj
            exit
         then
         "return" is if                      \ return [ expr ]
            lex
            kind @ 3 lit = if tk @ c@ 3B lit = else 0 lit then if
               00000513 lit cw,              \ li a0, 0
            else
               tk @ cur !
               1 lit expr
               3B lit expect
            then
            ejph  vret @ over !  vret !      \ j <the end>, patched there
            exit
         then
         "assert" is if                      \ assert expr
            vtest @ 0= if eassert then
            line @
            1 lit expr
            3B lit expect
            00050463 lit cw,                 \ beqz a0, +8
            ejph                             \ j <past the failure>
            swap lia0                        \ __test_fail(line)
            "__test_fail" B lit ocall
            ejph  vret @ over !  vret !      \ j <the end>, as `return` does
            cn @ patchj
            exit
         then
         tk @ tl @ line @                    \ a name: `NAME = ...` or an
         lex                                 \   expression.  Look one on.
         kind @ 3 lit =  tl @ 1 lit =  and if tk @ c@ 3D lit = else 0 lit then if
            drop
            2dup tl ! tk !  1 lit kind !
            chkident
            2dup llook dup 0< if             \ not a local: a global
               drop
               2dup gfind dup 0= if drop eunknown then
               nip nip
               dup 8 lit + @ 0= if econst then
               C lit + @
               1 lit expr
               3B lit expect
               gstore
            else
               nip nip
               1 lit expr
               3B lit expect
               A lit esw
            then
            exit
         then
         kind @ 3 lit =  tl @ 1 lit =  and if tk @ c@ 2E lit = else 0 lit then if
            lex                              \ module . NAME = ... ?
            kind @ 1 lit = if
               tk @ qn !  tl @ ql !
               lex
               kind @ 3 lit =  tl @ 1 lit =  and if tk @ c@ 3D lit = else 0 lit then if
                  drop
                  2dup chkmod
                  qn @ ql @ join 0 lit oref
                  1 lit expr
                  3B lit expect
                  gstore
                  exit
               then
            then
         then
         line !  drop  cur !                 \ an expression: back to the name
      else
         tk @ cur !
      then
      1 lit expr
      3B lit expect
      exit
   then

   \ ---- an expression: unary { OPERATOR unary }
   drop                                      \ min
   unary
   begin
      lex binop
      bprec @ dup 0= if drop 0 lit else over u>= then
   while
      bprec @ 3 lit u< if                    \ || and && skip their right side
         bprec @ 1 lit = if
            00A03533 lit cw,                 \ snez a0, a0
            00050463 lit cw,                 \ beqz a0, +8
         else
            00051463 lit cw,                 \ bnez a0, +8
         then
         ejph                                \ j <past the right side>
         bprec @ 1+ expr
         00A03533 lit cw,                    \ snez a0, a0
         cn @ patchj
      else
         bw1 @ bw2 @                         \ min w1 w2
         slotnew A lit esw                   \ the left side waits in a slot
         bprec @ 1+ expr
         over 10 lit u< if                   \ * / %: a call, left side in a0
            00050593 lit cw,                 \   and right in a1.  mv a1, a0
            1 lit slotdrop A lit elw
            over 1 lit = if "__mul" else
               over 2 lit = if "__div" else "__rem" then
            then
            5 lit ocall
            2drop
         else
            1 lit slotdrop B lit elw         \ the left side, into a1
            swap cw,
            dup if cw, else drop then
         then
      then
   repeat
   drop
   tk @ cur ! ;                              \ not ours: leave it unread


\ ---- functions, tests, init blocks ----------------------------------------

\ fnbegin  start the code of a function, test or init block: nothing in
\ scope, no slots, and room for the three instructions that make the
\ frame, filled in at the end.
: fnbegin  ( -- )
   lbase @ ltop !
   0 lit vcur !  0 lit vmax !  0 lit vout !  0 lit vret !  0 lit vtest !
   cn @ vpro !
   13 lit cw,  13 lit cw,  13 lit cw, ;

\ fnend  after its block: where every `return` jumps, the code that drops
\ the frame, and the three instructions that make it.  The frame is the
\ saved s0, the slots and the outgoing arguments, rounded up to 16 bytes.
: fnend  ( -- )
   vret @ begin dup while dup @ swap cn @ patchj repeat drop
   vtest @ if "__test_end" A lit ocall then
   00040113 lit cw,                          \ mv sp, s0
   FFC12403 lit cw,                          \ lw s0, -4(sp)
   vmax @ vout @ + 2 lit lshift 13 lit + -16 lit and
   dup 7F0 lit u> if elocals then
   0 lit over - 14 lit lshift 00010113 lit or  vpro @ !          \ addi sp, sp, -frame
   dup 4 lit -
   dup 5 lit rshift 19 lit lshift  swap 1F lit and 7 lit lshift  or
   00812023 lit or  vpro @ 4 lit + !                             \ sw s0, frame-4(sp)
   14 lit lshift 00010413 lit or  vpro @ 8 lit + !               \ addi s0, sp, frame
   oend ;

: pslot  variable ;
: gkind  variable ;    \ the kind of the global being defined: 4, or 5 local

\ top  one thing at the top of a file.  Its first token is read, a name.
: top  ( -- )
   "module" is if                            \ before anything else, once
      modl @ if emodfst then
      nsy @ if emodfst then
      cn @ cb @ <> if emodfst then
      itop @ ibase @ <> if emodfst then
      lex chkident
      tk @ modn !  tl @ modl !
      3B lit expect
      exit
   then
   "import" is if
      lex chkident
      itop @ dup 8 lit + ilim @ u> if ebig then
      tk @ over !  tl @ over 4 lit + !
      8 lit + itop !
      3B lit expect
      exit
   then
   "test" is if
      lex                                    \ its name
      kind @ 4 lit <> if syntax then
      mode @ 0= if                           \ not wanted: past its block
         7B lit expect
         1 lit                               \ how many { are open
         begin dup while
            lex
            kind @ 0= if syntax then
            kind @ 3 lit =  tl @ 1 lit =  and if
               tk @ c@ dup 7B lit = if drop 1+ else 7D lit = if 1- then then
            then
         repeat
         drop exit
      then
      tk @ tl @
      oinit fnbegin
      1 lit vtest !
      file @ fend @ estring                  \ __test_begin(name, file)
      00050593 lit cw,                       \ mv a1, a0
      over 1+ -rot + 1- estring              \ the name, inside its quotes
      "__test_begin" C lit ocall
      block fnend
      exit
   then
   "init" is if
      oinit
      lex
      kind @ 1 lit = if "asm" is else 0 lit then if
         asmbody oend exit                   \ nothing but the code
      then
      tk @ cur !                             \ a block, with a frame
      fnbegin block fnend
      exit
   then
   "const" is if                             \ const NAME = value ;
      lex chkident
      tk @ tl @
      2dup gfind if edup then
      3D lit expect
      constval
      3B lit expect
      0 lit swap gadd
      exit
   then
   3 lit                                     \ a local function, unless pub
   "pub" is if
      drop 1 lit
      lex
      kind @ 1 lit <> if syntax then
   then
   "let" is if                               \ [ pub ] let NAME = value ;
      1 lit = if 4 lit else 5 lit then gkind !
      lex chkident
      tk @ tl @
      2dup gfind if edup then
      2dup qualify 2dup gkind @ odefine
      dup 0= if drop edup then
      nip nip
      syb @ - 14 lit /                       \ name len index
      3D lit expect
      constval cw,                           \ its record: the one word
      3B lit expect
      oend
      1 lit swap gadd
      exit
   then
   "fn" is 0= if syntax then
   lex chkident
   modl @ 0=  mode @ 0=  and  "main" is  and if drop 1 lit then
   tk @ tl @ qualify                         \ kind name len
   2dup 4 lit pick odefine 0= if edup then
   2drop drop
   fnbegin
   28 lit expect
   lex
   kind @ 3 lit = if
      tk @ c@ 29 lit <> if syntax then
   else
      begin                                  \ parameter k goes to slot k
         chkident
         tk @ tl @ slotnew dup pslot ! ladd
         pslot @ 8 lit u< if
            pslot @ dup A lit + esw          \ from its register, a0 to a7
         else
            pslot @ 8 lit - 16 lit lshift 00042383 lit or cw,    \ lw t2, 4*(k-8)(s0)
            pslot @ 7 lit esw                \   from the caller's frame
         then
         lex
         kind @ 3 lit <> if syntax then
         tk @ c@ dup 29 lit = if
            drop -1 lit
         else
            2C lit <> if syntax then
            lex 0 lit
         then
      until
   then
   block fnend ;

: setup  ( -- )
   100000 lit need dup syb ! dup syn !  100000 lit + sylim !
   100000 lit need dup clb ! dup cln !  100000 lit + cllim !
   200000 lit need dup nb ! dup nn !  200000 lit + nlim !
   1000000 lit need dup cb ! dup cn !  1000000 lit + clim !
   10000 lit need dup lbase ! dup ltop !  10000 lit + llim !
   10000 lit need dup ibase ! dup itop !  10000 lit + ilim !
   40000 lit need dup gb ! dup gn !  40000 lit + glim !
   400 lit need scr !
   40000 lit need hn !
   4000 lit need dup hb !
   dup 4000 lit + swap begin 2dup u> while 0 lit over ! 4 lit + repeat 2drop
   0 lit nsy !  0 lit rec !  0 lit modl !  0 lit mode !  0 lit file !
   0 lit vtest !
   2000000 lit need dup cur !                \ the source: read it all
   2000000 lit +                             \ its limit
   cur @
   begin
      getc dup 4 lit <>
   while
      over 3 lit pick u>= if ebig then
      over c!  1+
   repeat
   drop send ! drop
   1 lit line ! ;

\ header  0x01 or 0x02 and the file's name, first?
: header  ( -- )
   cur @ send @ u>= if exit then
   cur @ c@ dup 1 lit <  over 2 lit >  or if drop exit then
   1 lit = if 1 lit mode ! then
   cur @ 1+ dup file !
   begin dup send @ u< if dup c@ A lit <> else 0 lit then while 1+ repeat
   dup fend !
   1+ cur ! ;

: main  ( -- )
   setup
   header
   begin lex kind @ while
      kind @ 1 lit <> if syntax then
      top
   repeat
   resolve
   owrite ;

main bye
