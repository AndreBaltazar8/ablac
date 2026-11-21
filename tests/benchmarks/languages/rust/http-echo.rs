use std::io::{Read, Write};
fn main() {
    let port = std::env::args().nth(1).unwrap();
    let listener = std::net::TcpListener::bind(format!("127.0.0.1:{}", port)).unwrap();
    for incoming in listener.incoming() {
        let mut c = incoming.unwrap();
        let mut buf = [0u8; 8192];
        let mut n = 0;
        loop {
            let r = c.read(&mut buf[n..]).unwrap_or(0);
            if r == 0 {
                break;
            }
            n += r;
            if let Some(at) = buf[..n].windows(4).position(|s| s == b"\r\n\r\n") {
                if n >= at + 4 + 256 {
                    let mut response =
                        b"HTTP/1.1 200 OK\r\nContent-Length: 256\r\nConnection: close\r\n\r\n"
                            .to_vec();
                    response.extend_from_slice(&buf[at + 4..at + 4 + 256]);
                    let _ = c.write_all(&response);
                    break;
                }
            }
            if n == buf.len() {
                break;
            }
        }
    }
}
