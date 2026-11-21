use std::{env, io::{self, Write}};

fn main() -> io::Result<()> {
    let count: usize = env::args().nth(1).unwrap().parse().unwrap();
    let mut text = String::new();
    for i in 0..count {
        let chunk = if i % 2 == 0 { "alpha: 01234567\n" } else { "bravo: 76543210\n" };
        text.push_str(chunk);
    }
    io::stdout().write_all(text.as_bytes())
}
