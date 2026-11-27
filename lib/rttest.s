# lib/rttest.s -- the last init record of a test build, in place of
# lib/rtmain.s: every test has run by now (each is an init record of its
# object); report the totals and exit (lib/rt.fam).
init
@__tests_done
6F000000    # j .
end
