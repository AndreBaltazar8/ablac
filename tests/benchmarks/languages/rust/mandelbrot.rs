#[allow(dead_code)]
mod cpu;
fn main() {
    cpu::mandelbrot(std::env::args().nth(1).unwrap().parse().unwrap());
}
