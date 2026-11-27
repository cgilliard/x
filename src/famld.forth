\ src/famld.forth -- the fam linker and back end (docs/OBJECT.md).
\
\ Reads objects from the console, one after another, up to the end marker
\ (four 0x04 bytes), and writes the program: a binary that runs.  On an
\ error it writes a message in place of the binary and exits with 1.
\
\ It is written in the Forth of lib/compiler.lib; scripts/build.sh has the
\ core compile the two together into bin/famld.
\
\ What it does:
\   1. Reads and checks each object, and enters its symbols in one table.
\   2. Finds the functions the init records reach, and writes each after
\      the functions it calls.  A function nothing reaches is left out.
\   3. Writes the init records, in the order given, as the code the binary
\      starts with.
\
\ The binary never has a jalr.  A call pushes a number, its return id, on
\ the stack of return ids (s10 floor, s11 pointer) and jumps to the
\ function; the function ends by jumping to an "island", which pops the id
\ and jumps to where the call was, finding the place by halving through the
\ ids.  A jump reaches 1 MiB, so there is an island about every 256 KiB,
\ and each has a relay, a jump, for every function before it: a call out of
\ reach goes to the nearest relay behind it, and so on back.
\
\ Functions that call each other in a cycle cannot all come before their
\ callers.  When a function calls one that is still being written, the call
\ goes to a stub: a word holding one jump, pointed at the function when its
\ turn comes.
\
\ A function's id, for calling it through a value, is a number from 1.  A
\ call through an id is a call of `__call` with the id in t2; if no object
\ defines `__call` the linker writes it: the dispatcher, which finds t2
\ among the ids by halving and calls the function.


\ ---- errors: a message in place of the binary, then exit code 1 ----------

: fail  ( -- )      A lit putc die ;
: err   ( text -- ) puts fail ;
: oom   ( -- )      "famld: out of memory" err ;
: bad   ( -- )      "famld: bad object" err ;


\ ---- memory ---------------------------------------------------------------

: need  ( n -- addr )   alloc dup 0= if oom then ;

\ The objects, as read, one after another.
: objp    variable ;   \ where the next goes
: objend  variable ;   \ where the room for them ends

\ The binary being made.
: obase   variable ;   \ where it starts
: op      variable ;   \ where the next word goes
: olim    variable ;   \ where the room for it ends

\ The symbols: one for every name, and one for every local function.
\ 32 bytes each:
\    +0  name, +4 its length
\    +8  the object that defines it (0: none yet; 1: it is the dispatcher)
\   +12  its symbol there
\   +16  0 not written, 1 being written, 2 written
\   +20  its word (below), once it is being written
\   +24  its stub's word, if it has a stub
\   +28  its function id (0: none)
: symb    variable ;
: symn    variable ;   \ the next free one
: symlim  variable ;

\ The words: every function and every stub written, in the order written.
\ 8 bytes each: where it starts in the binary, and its relay in the last
\ island (for calls out of reach of the word itself).
: wb      variable ;
: wn      variable ;
: wlim    variable ;

\ The call sites written: for each return id, where to return to.
: sb      variable ;
: sn      variable ;
: slim    variable ;

\ The init records: 8 bytes each, the object and its symbol there.
: ib      variable ;
: in      variable ;
: ilim    variable ;

: nids    variable ;   \ how many functions have an id
: curfn   variable ;   \ the symbol of the function being written (0: none)
: depth   variable ;   \ how many functions are being written at once

: setup  ( -- )
   2000000 lit need dup objp !  2000000 lit + objend !
   2000000 lit need dup obase ! dup op !  2000000 lit + olim !
   100000 lit need dup symb ! dup symn !  100000 lit + symlim !
   100000 lit need dup wb ! dup wn !  100000 lit + wlim !
   100000 lit need dup sb ! dup sn !  100000 lit + slim !
   10000 lit need dup ib ! dup in !  10000 lit + ilim !
   0 lit nids !  0 lit curfn !  0 lit depth ! ;


\ ---- writing the binary ---------------------------------------------------

\ w,  append a word.
: w,  ( word -- )
   op @ dup olim @ u>= if oom then
   tuck !  4 lit + op ! ;

\ reach?  can a jump span this distance?  (1 MiB either way)
: reach?  ( distance -- flag )   100000 lit + 200000 lit u< ;

\ jalw  the instruction `jal x0` over a distance.
: jalw  ( distance -- word )
   dup 14 lit rshift 1 lit and 1F lit lshift
   over 1 lit rshift 3FF lit and 15 lit lshift or
   over B lit rshift 1 lit and 14 lit lshift or
   swap C lit rshift FF lit and C lit lshift or
   6F lit or ;

: far   ( -- )   "famld: a jump is out of reach" err ;

\ jal,  append a jump to an address.
: jal,  ( target -- )
   op @ -  dup reach? 0= if far then  jalw w, ;

\ patchj  make the jump at slot go to an address.
: patchj  ( slot target -- )
   over -  dup reach? 0= if far then  jalw swap ! ;

\ li,  append `lui r, hi` and `addi r, r, lo` that load a value, given the
\ two instructions with a zero value.
: li,  ( value lui addi -- )
   rot
   dup 800 lit + C lit rshift C lit lshift  3 lit pick or w,
   14 lit lshift or w,
   drop ;


\ ---- islands --------------------------------------------------------------

: lastisl  variable ;  \ where the last island ended (the start, at first)
: retent   variable ;  \ where a word written now returns: the last island
: prevchk  variable ;  \ where the last island checks an id (0: no island)
: fwdslot  variable ;  \ its jump on to the next island, to be filled in
: seglo    variable ;  \ the first return id since the last island
: isover   variable ;  \ the island being written: the jump over it,
: iret     variable ;  \   where it starts,
: ichk     variable ;  \   and where it checks an id

: nsites  ( -- n )         sn @ sb @ - 2 lit rshift ;
: site@   ( id -- addr )   2 lit lshift sb @ + @ ;

\ bst  the code that jumps to the return site of the id in t0, known to be
\ one of lo..hi.  For one id, a jump.  For more, with m the middle one:
\      li t1, m ; bne t0, t1, +8 ; j site m ; bge t0, t1, +8 ; j lower
\      <the ids above m>   lower: <the ids below m>
: bst  ( lo hi -- )
   2dup > if 2drop exit then
   2dup = if drop site@ jal, exit then
   2dup + 1 lit rshift                       \ lo hi m
   dup 337 lit 30313 lit li,                 \ li t1, m
   00629463 lit w,                           \ bne t0, t1, +8
   dup site@ jal,
   0062D463 lit w,                           \ bge t0, t1, +8
   op @  6F lit w,                           \ lo hi m slot
   over 1+ 3 lit pick bst                    \ the ids above m
   over 4 lit pick = if                      \ none below m: a jump to itself,
      dup patchj  2drop drop                 \   which no good id takes
   else
      op @ patchj  nip 1- bst                \ the ids below m
   then ;

\ island  write an island: the returns of the call sites since the last
\ one, and (unless it is the last of all) a relay for every word so far.
\      [ j over ]                          not in the last
\      lw t0, 0(s11) ; addi s11, s11, 4    words return here: pop the id
\      li t1, lo ; bgeu t0, t1, +8 ; j <the island before>
\      li t1, n  ; bltu t0, t1, +8 ; j <the island after>
\      <bst lo..n-1>
\      <relays>                            not in the last
: island  ( last -- )
   dup 0= if op @ isover !  6F lit w, then
   op @ iret !
   000DA283 lit w,                           \ lw t0, 0(s11)
   004D8D93 lit w,                           \ addi s11, s11, 4
   op @ ichk !
   fwdslot @ dup if op @ patchj else drop then
   prevchk @ 0= if obase @ 8 lit + iret @ patchj then
   seglo @ 337 lit 30313 lit li,             \ li t1, lo
   0062F463 lit w,                           \ bgeu t0, t1, +8
   prevchk @ dup 0= if drop op @ then jal,
   nsites 337 lit 30313 lit li,              \ li t1, n
   0062E463 lit w,                           \ bltu t0, t1, +8
   0 lit fwdslot !
   dup 0= if op @ fwdslot ! then
   6F lit w,
   seglo @ nsites 1-                         \ last lo hi
   nsites seglo !  ichk @ prevchk !  iret @ retent !
   bst
   0= if
      wb @ begin dup wn @ u< while
         dup @ op @ - reach? if dup @ else dup 4 lit + @ then
         op @ 2 lit pick 4 lit + !           \ this is its relay from now on
         jal,
         8 lit +
      repeat drop
      isover @ op @ patchj
      op @ lastisl !
   then ;


\ ---- words and calls ------------------------------------------------------

: skip  variable ;     \ the jump over the word being written

\ word:  start a word, after an island if one is due; its entry in the list
\ of words.  A word is: a jump over it, its code, a jump to the island.
: word:  ( -- word )
   op @ lastisl @ - 40000 lit u>= if 0 lit island then
   op @ skip !  6F lit w,
   wn @ dup wlim @ u>= if oom then
   op @ over !  0 lit over 4 lit + !
   dup 8 lit + wn ! ;

\ ;word  end it.
: ;word  ( -- )
   retent @ jal,
   skip @ op @ patchj ;

\ call,  append a call of a word:
\      addi s11, s11, -4 ; bgeu s11, s10, +8 ; ebreak     room for an id?
\      li t0, id ; sw t0, 0(s11) ; j <the word, or its relay>
: call,  ( word -- )
   FFCD8D93 lit w,  01ADF463 lit w,  00100073 lit w,
   nsites 2B7 lit 28293 lit li,              \ li t0, id
   005DA023 lit w,                           \ sw t0, 0(s11)
   dup @ op @ - reach? if @ else 4 lit + @ then jal,
   sn @ dup slim @ u>= if oom then
   op @ over !  4 lit + sn ! ;


\ ---- reading the objects --------------------------------------------------

\ rd  read bytes from the console into dst..end.
: rd  ( dst end -- )
   swap begin 2dup u> while getc over c! 1+ repeat 2drop ;

\ same  are the len bytes at a and at b the same?
: same  ( a b len -- flag )
   begin dup while
      2 lit pick c@ 2 lit pick c@ <> if drop 2drop 0 lit exit then
      1- rot 1+ rot 1+ rot
   repeat
   drop 2drop -1 lit ;

\ find  the symbol of a name, or 0.
: find  ( name len -- sym )
   symb @
   begin dup symn @ u< while
      dup 4 lit + @ 2 lit pick = if
         dup @ 3 lit pick 3 lit pick same if nip nip exit then
      then
      20 lit +
   repeat
   drop 2drop 0 lit ;

\ newsym  a new symbol, nothing known of it but its name.
: newsym  ( name len -- sym )
   symn @ dup 20 lit + symlim @ u> if oom then
   dup 20 lit + symn !
   tuck 4 lit + !
   tuck !
   0 lit over 8 lit + !    0 lit over C lit + !   0 lit over 10 lit + !
   0 lit over 14 lit + !   0 lit over 18 lit + !  0 lit over 1C lit + ! ;

\ While an object is being checked:
: o       variable ;   \ the object
: nsym    variable ;   \ how many symbols it has,
: ncall   variable ;   \   call sites,
: codesz  variable ;   \   bytes of code,
: namesz  variable ;   \   and bytes of names
: pend    variable ;   \ where the call site before ended

\ lsym  the object's symbol of that index.
: lsym  ( index -- L )
   dup 4 lit lshift swap 2 lit lshift + o @ + 1C lit + ;

\ chkcode  the code of a symbol must lie inside the object's, in whole words.
: chkcode  ( L -- )
   dup C lit + @ swap 10 lit + @             \ offset size
   2dup or 3 lit and if bad then
   over codesz @ u> if bad then
   dup codesz @ u> if bad then
   + codesz @ u> if bad then ;

\ dosym  check one symbol of the object, and enter it.  Afterwards its
\ second word, which was the offset of its name, is the address of its
\ symbol here (for a function or an external).
: dosym  ( L -- )
   dup @ 3 lit u> if bad then
   dup @ 2 lit = if                          \ an init record
      dup chkcode
      in @ dup ilim @ u>= if oom then
      o @ over !  tuck 4 lit + !
      8 lit + in !
      exit
   then
   dup 8 lit + @ dup 0= if bad then  FF lit u> if bad then
   dup 4 lit + @ namesz @ u> if bad then
   dup 4 lit + @ over 8 lit + @ + namesz @ u> if bad then
   dup 4 lit + @ o @ 8 lit + @ + codesz @ +  \ L name
   over 8 lit + @                            \ L name len
   2 lit pick @ 3 lit = if                   \ a local function: a symbol
      0 lit                                  \   of its own, whatever
   else
      2dup find
   then
   dup 0= if drop newsym else nip nip then   \ L sym
   2dup swap 4 lit + !
   over @ 0= if 2drop exit then              \ an external: nothing more
   dup 8 lit + @ if
      "famld: defined twice: " puts  dup @ swap 4 lit + @ type  fail
   then
   over chkcode
   o @ over 8 lit + !
   C lit + ! ;

\ dosite  check one call site of the object.  A function whose id is taken
\ (a site with the top bit of its index set) gets an id.
: dosite  ( C -- )
   dup @
   dup 3 lit and if bad then
   dup pend @ u< if bad then
   dup codesz @ u> if bad then
   over 4 lit + @ 0< if 8 lit else 1C lit then +
   dup codesz @ u> if bad then
   pend !
   dup 4 lit + @ 7FFFFFFF lit and
   dup nsym @ u>= if bad then
   lsym                                      \ C L
   dup @ 2 lit = if bad then
   swap 4 lit + @ 0< if
      4 lit + @                              \ sym
      dup 1C lit + @ 0= if
         nids @ 1+
         dup 4E20 lit u> if "famld: too many functions have their id taken" err then
         dup nids !
         swap 1C lit + !
      else
         drop
      then
   else
      drop
   then ;

\ check  check a whole object, just read, and enter what is in it.
\ Afterwards its second word, which was the version, is the address of its
\ call sites, and its third, which was its size, the address of its code
\ (where the call sites end).
: check  ( O -- )
   dup o !
   dup C lit + @ nsym !   dup 10 lit + @ ncall !
   dup 14 lit + @ codesz !  dup 18 lit + @ namesz !
   8 lit + @                                 \ size
   nsym @ over u> if bad then    ncall @ over u> if bad then
   codesz @ over u> if bad then  namesz @ over u> if bad then
   codesz @ namesz @ or 3 lit and if bad then
   nsym @ 4 lit lshift nsym @ 2 lit lshift + 1C lit +    \ size, header and symbols
   dup o @ + o @ 4 lit + !                   \ the call sites start after them
   ncall @ 3 lit lshift +
   dup o @ + o @ 8 lit + !                   \ and the code after those
   codesz @ + namesz @ +
   <> if bad then                            \ the parts must add up
   o @ 1C lit +
   begin dup o @ 4 lit + @ u< while dup dosym 14 lit + repeat drop
   0 lit pend !
   o @ 4 lit + @
   begin dup o @ 8 lit + @ u< while dup dosite 8 lit + repeat drop ;

\ load  read the next object; 0 if it was the end marker.
: load  ( -- more )
   objp @
   dup C lit + objend @ u> if oom then
   dup dup 4 lit + rd
   dup @ 04040404 lit = if drop 0 lit exit then
   dup @ 4F4D4146 lit <> if "famld: the input is not a fam object" err then
   dup 4 lit + over C lit + rd
   dup 4 lit + @ 1 lit <> if "famld: unknown object version" err then
   dup 8 lit + @                             \ O size
   dup 1C lit u< if bad then
   dup 3 lit and if bad then
   dup objend @ 3 lit pick - u> if oom then
   over C lit + 2 lit pick 2 lit pick + rd
   over + objp !
   check
   1 lit ;


\ ---- writing the functions ------------------------------------------------

\ 1stcall  the object's first call site at or after an offset in its code
\ (the end of its call sites if there is none).  They are in order.
: 1stcall  ( O offset -- C )
   swap dup 4 lit + @ swap 8 lit + @         \ offset lo hi
   begin 2dup u< while
      2dup swap - 4 lit rshift 3 lit lshift 2 lit pick +     \ the middle one
      dup @ 4 lit pick u< if
         8 lit + rot drop swap
      else
         nip
      then
   repeat
   drop nip ;

\ csym  the symbol a call site of an object names.
: csym  ( O C -- sym )
   4 lit + @ 7FFFFFFF lit and
   dup 4 lit lshift swap 2 lit lshift + + 20 lit + @ ;

: name.  ( sym -- )   dup @ swap 4 lit + @ type ;

\ undef  a call of a function no object defines.
: undef  ( sym -- )
   "famld: undefined: " puts name.
   curfn @ dup if " in " puts name. else drop then
   fail ;

\ outcall  append a call of a function: of its stub, if it is still being
\ written (and is not the one this code is in).
: outcall  ( sym -- )
   dup 10 lit + @ 1 lit =  over curfn @ <>  and
   if 18 lit + @ else 14 lit + @ then
   call, ;

\ emitcode  append a record's code: its words as they are, a call for each
\ call site, and for each id site the two instructions that load the id.
: eo     variable ;    \ the object
: eoff   variable ;    \ how far through its code
: eend   variable ;    \ where the record's code ends
: ecall  variable ;    \ the next call site
: emitcode  ( O L -- )
   swap eo !
   dup C lit + @ dup eoff !  swap 10 lit + @ + eend !
   eo @ eoff @ 1stcall ecall !
   begin eoff @ eend @ u< while
      ecall @ eo @ 8 lit + @ u<  ecall @ @ eoff @ =  and if
         ecall @ 4 lit + @ 0< if             \ an id site
            eoff @ 8 lit + dup eend @ u> if bad then eoff !
            eo @ ecall @ csym 1C lit + @
            dup 800 lit + C lit rshift C lit lshift 537 lit or w,    \ lui a0
            14 lit lshift 50513 lit or w,                             \ addi a0, a0
         else                                \ a call site
            eoff @ 1C lit + dup eend @ u> if bad then eoff !
            eo @ ecall @ csym
            dup 8 lit + @ 0= if undef then
            outcall
         then
         ecall @ 8 lit + ecall !
      else
         eo @ 8 lit + @ eoff @ + @ w,
         eoff @ 4 lit + eoff !
      then
   repeat ;

\ The dispatcher.  An illegal instruction unless 1 <= t2 <= the last id;
\ then the tree: for one id,      <call it> ; j <the end>
\ and for more, with m the middle one,
\      li t3, m ; bltu t2, t3, +8 ; j <second half> ; <first half>
\ so a run of n ids is 48n - 16 bytes.
: dpos  variable ;     \ bytes of tree written
: dend  variable ;     \ bytes of tree in all

: idsym  ( id -- sym )
   symb @ begin dup 1C lit + @ 2 lit pick <> while 20 lit + repeat nip ;

: gen  ( lo hi -- )
   2dup = if
      drop idsym outcall
      dpos @ 1C lit + dpos !
      dend @ dpos @ - jalw w,
      dpos @ 4 lit + dpos !
      exit
   then
   2dup + 1+ 1 lit rshift                    \ lo hi m
   dup E37 lit E0E13 lit li,                 \ li t3, m
   01C3E463 lit w,                           \ bltu t2, t3, +8
   dup 3 lit pick - 30 lit * C lit - jalw w,
   dpos @ 10 lit + dpos !
   2 lit pick over 1- gen
   swap gen drop ;

: disp  ( -- )
   00039463 lit w,  0 lit w,                 \ bnez t2, +8 ; illegal
   nids @ 0= if exit then
   nids @ 1+ E37 lit E0E13 lit li,           \ li t3, last + 1
   01C3E463 lit w,  0 lit w,                 \ bltu t2, t3, +8 ; illegal
   nids @ 30 lit * 10 lit - dend !  0 lit dpos !
   1 lit nids @ gen ;

\ mkstub  give a function that is being written a stub, if it has none.
: mkstub  ( sym -- )
   dup 18 lit + @ if drop exit then
   word: swap 18 lit + !
   6F lit w,                                 \ the jump, pointed later
   ;word ;

\ spatch  point a stub's jump at its function.
: spatch  ( slot target -- )
   over - dup reach? 0= if
      "famld: functions that call each other are over 1 MiB apart" err
   then
   jalw swap ! ;

\ go  the walk that puts every function after the functions it calls.
\
\ mode 1: look at the call sites of the record L of object O, and visit
\ each function called.
\ mode 0: visit a function: if it is not written, write it now, first
\ visiting what it calls; if it is being written -- this call closes a
\ cycle -- give it a stub.  (A call of itself needs none.)
: ccur  variable ;     \ the call site to look at next
: cend  variable ;     \ where the record's code ends
: go  ( O L 1 -- )  ( sym x 0 -- )
   if
      over swap
      dup C lit + @ swap 10 lit + @ over +   \ O O offset end
      cend @ swap cend !                     \ O O offset oldend
      -rot 1stcall                           \ O oldend first
      ccur @ swap ccur !                     \ O oldend oldcur
      rot                                    \ oldend oldcur O
      begin dup 8 lit + @ ccur @ u>  ccur @ @ cend @ u<  and while
         ccur @ dup 8 lit + ccur !
         dup 4 lit + @ 0< if                 \ an id site calls nothing
            drop
         else
            over swap csym 0 lit 0 lit go
         then
      repeat
      drop
      ccur ! cend !
      exit
   then
   drop
   dup 8 lit + @ 0= if undef then
   dup curfn @ = if drop exit then
   dup 10 lit + @ 2 lit = if drop exit then
   dup 10 lit + @ 1 lit = if mkstub exit then

   1 lit over 10 lit + !
   depth @ 1+ dup 1000 lit u> if "famld: calls nested too deep" err then depth !
   curfn @ swap curfn !                      \ oldfn
   curfn @ 8 lit + @ 1 lit = if              \ the dispatcher calls every
      symb @ begin dup symn @ u< while       \   function with an id
         dup 1C lit + @ if dup 0 lit 0 lit go then
         20 lit +
      repeat drop
   else
      curfn @ 8 lit + @  curfn @ C lit + @  1 lit go
   then

   word: curfn @ 14 lit + !
   curfn @ 18 lit + @ dup if @ op @ spatch else drop then
   curfn @ 8 lit + @ 1 lit = if
      disp
   else
      curfn @ 8 lit + @  curfn @ C lit + @  emitcode
   then
   ;word

   2 lit curfn @ 10 lit + !
   depth @ 1- depth !
   curfn ! ;


\ ---- the whole binary -----------------------------------------------------

\ header  how the binary starts:
\      nop                 the mark of a fam binary
\      j +12               over the next two words
\      j <first island>    words before the first island return through here
\      j .
\      auipc gp, 0 ; addi gp, gp, 0      filled in at the end: gp = the
\                                        address just past the binary
: header  ( -- )
   13 lit w,
   C lit jalw w,
   6F lit w,
   6F lit w,
   197 lit w,
   18193 lit w,
   obase @ lastisl !
   obase @ 8 lit + retent !
   0 lit prevchk !  0 lit fwdslot !  0 lit seglo ! ;

\ finish  how it ends: a jump to itself, in case the program runs off its
\ end; the last island; and the two instructions of the header.
: finish  ( -- )
   op @ jal,
   1 lit island
   op @ obase @ 10 lit + -                   \ from the auipc to the end
   dup 800 lit + C lit rshift C lit lshift 197 lit or  obase @ 10 lit + !
   14 lit lshift 18193 lit or  obase @ 14 lit + ! ;

: flush  ( -- )
   obase @ begin dup op @ u< while dup c@ putc 1+ repeat drop ;

: main  ( -- )
   setup
   header
   begin load 0= until

   "__call" 6 lit find                       \ __call, called and not defined:
   dup if                                    \   the dispatcher
      dup 8 lit + @ 0= if 1 lit swap 8 lit + ! else drop then
   else
      drop
   then

   ib @ begin dup in @ u< while              \ the functions the init records
      dup @ over 4 lit + @ 1 lit go          \   reach
      8 lit +
   repeat drop

   ib @ begin dup in @ u< while              \ then the init records
      dup @ over 4 lit + @ emitcode
      8 lit +
   repeat drop

   finish
   flush ;

main bye
