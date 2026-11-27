# lib/rtmain.s -- the last init record of a program: exit(main()).
# `fam.sh ld` puts it last in every link (lib/rt0.s is first).
init
@main
@exit
6F000000    # j .
end
