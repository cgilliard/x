# error: famld: mutual recursion is not supported yet: main in b
fn main
@b
end
fn b
@main
end
