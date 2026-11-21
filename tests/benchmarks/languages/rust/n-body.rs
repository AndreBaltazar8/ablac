#[allow(dead_code)]
mod cpu;
fn main() {
    cpu::n_body(std::env::args().nth(1).unwrap().parse().unwrap());
}
