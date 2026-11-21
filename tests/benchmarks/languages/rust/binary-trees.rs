#[allow(dead_code)]
mod cpu;
fn main() {
    cpu::binary_trees(std::env::args().nth(1).unwrap().parse().unwrap());
}
