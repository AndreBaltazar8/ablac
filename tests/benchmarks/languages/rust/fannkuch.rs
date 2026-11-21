#[allow(dead_code)]
mod cpu;
fn main() {
    cpu::fannkuch(std::env::args().nth(1).unwrap().parse().unwrap());
}
