#[allow(dead_code)]
mod cpu;
fn main() {
    cpu::spectral_norm(std::env::args().nth(1).unwrap().parse().unwrap());
}
