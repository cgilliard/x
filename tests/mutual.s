# exit: 5
# main calls a, a calls b, b calls a: b reaches a through a stub.
fn main
# addi a0,zero,0
13050000
@a
end
fn a
# addi t2,zero,5 ; beq a0,t2,done ; addi a0,a0,1 ; (call b) ; done:
93035000
63027502
13051500
@b
end
fn b
@a
end
