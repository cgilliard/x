# exit: 4
# A function may call itself: count(a0) returns a0 once it reaches 4.
fn main
# addi a0,zero,0
13050000
@count
end
fn count
# addi t2,zero,4 ; beq a0,t2,done (over the addi and the call) ; addi a0,a0,1
93034000
63027502
13051500
@count
# done:
end
