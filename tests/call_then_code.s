# exit: 12
# Code before, between and after call sites: 1 + 5 + 5 + 1.
fn main
# addi s0,zero,1 ; (call) ; add s0,s0,a0 ; (call) ; add a0,a0,s0 ; addi a0,a0,1
13041000
@five
3304A400
@five
33058500
13051500
end
fn five
13055000
end
