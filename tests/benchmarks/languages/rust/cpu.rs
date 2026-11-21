use std::io::{self, Write};
struct Tree {
    left: Option<Box<Tree>>,
    right: Option<Box<Tree>>,
}
fn make(d: i32) -> Box<Tree> {
    Box::new(Tree {
        left: if d > 0 { Some(make(d - 1)) } else { None },
        right: if d > 0 { Some(make(d - 1)) } else { None },
    })
}
fn check(t: &Tree) -> i64 {
    match &t.left {
        Some(l) => 1 + check(l) + check(t.right.as_ref().unwrap()),
        None => 1,
    }
}
pub fn binary_trees(n: usize) {
    let t = make(n as i32 + 1);
    println!("stretch {}", check(&t));
    drop(t);
    let long = make(n as i32);
    for d in (4..=n).step_by(2) {
        let rounds = 1 << (n - d + 4);
        let mut sum = 0;
        for _ in 0..rounds {
            sum += check(&make(d as i32));
        }
        println!("{} {} {}", d, rounds, sum);
    }
    println!("long {}", check(&long));
}
pub fn fannkuch(n: usize) {
    let mut p: Vec<usize> = (0..n).collect();
    let mut count = vec![0; n];
    let mut q = vec![0; n];
    let (mut r, mut maximum, mut checksum, mut idx) = (n, 0, 0i64, 0);
    loop {
        while r != 1 {
            count[r - 1] = r;
            r -= 1;
        }
        q.copy_from_slice(&p);
        let mut flips = 0;
        while q[0] != 0 {
            let k = q[0];
            q[..=k].reverse();
            flips += 1;
        }
        maximum = maximum.max(flips);
        checksum += if idx % 2 == 0 { flips } else { -flips };
        idx += 1;
        loop {
            if r == n {
                println!("{} {}", checksum, maximum);
                return;
            }
            p[..=r].rotate_left(1);
            count[r] -= 1;
            if count[r] > 0 {
                break;
            }
            r += 1;
        }
    }
}
fn a(i: usize, j: usize) -> f64 {
    1.0 / (((i + j) * (i + j + 1) / 2 + i + 1) as f64)
}
fn mul(u: &[f64], v: &mut [f64], trans: bool) {
    for i in 0..u.len() {
        let mut s = 0.0;
        for j in 0..u.len() {
            s += if trans {
                a(j, i) * u[j]
            } else {
                a(i, j) * u[j]
            };
        }
        v[i] = s;
    }
}
pub fn spectral_norm(n: usize) {
    let mut u = vec![1.0; n];
    let mut v = vec![0.0; n];
    let mut t = vec![0.0; n];
    for _ in 0..10 {
        mul(&u, &mut t, false);
        mul(&t, &mut v, true);
        mul(&v, &mut t, false);
        mul(&t, &mut u, true);
    }
    let (mut uv, mut vv) = (0.0, 0.0);
    for i in 0..n {
        uv += u[i] * v[i];
        vv += v[i] * v[i];
    }
    println!("{:0.9}", (uv / vv).sqrt());
}
pub fn mandelbrot(n: usize) {
    let mut out = io::BufWriter::new(io::stdout().lock());
    write!(out, "P4\n{} {}\n", n, n).unwrap();
    for y in 0..n {
        let (mut byte, mut bits) = (0u8, 0);
        for x in 0..n {
            let cr = 2.0 * x as f64 / n as f64 - 1.5;
            let ci = 2.0 * y as f64 / n as f64 - 1.0;
            let (mut zr, mut zi, mut k) = (0.0, 0.0, 0);
            while k < 50 && zr * zr + zi * zi <= 4.0 {
                let next = zr * zr - zi * zi + cr;
                zi = 2.0 * zr * zi + ci;
                zr = next;
                k += 1;
            }
            byte = (byte << 1) | u8::from(zr * zr + zi * zi <= 4.0);
            bits += 1;
            if bits == 8 {
                out.write_all(&[byte]).unwrap();
                byte = 0;
                bits = 0;
            }
        }
        if bits > 0 {
            out.write_all(&[byte << (8 - bits)]).unwrap();
        }
    }
}
const ALU:&[u8]=b"GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA";
fn random(out: &mut impl Write, n: usize, letters: &[u8], prob: &[f64], seed: &mut u32) {
    for i in 0..n {
        *seed = (*seed * 3877 + 29573) % 139968;
        let r = *seed as f64 / 139968.0;
        let (mut j, mut c) = (0, 0.0);
        while j < letters.len() - 1 {
            c += prob[j];
            if r < c {
                break;
            }
            j += 1;
        }
        out.write_all(&[letters[j]]).unwrap();
        if i % 60 == 59 || i == n - 1 {
            out.write_all(b"\n").unwrap();
        }
    }
}
pub fn fasta(n: usize) {
    let mut out = io::BufWriter::new(io::stdout().lock());
    writeln!(out, ">ONE Homo sapiens alu").unwrap();
    for i in 0..2 * n {
        out.write_all(&[ALU[i % ALU.len()]]).unwrap();
        if i % 60 == 59 || i == 2 * n - 1 {
            out.write_all(b"\n").unwrap();
        }
    }
    writeln!(out, ">TWO IUB ambiguity codes").unwrap();
    let mut seed = 42;
    random(
        &mut out,
        3 * n,
        b"acgtBDHKMNRSVWY",
        &[
            0.27, 0.12, 0.12, 0.27, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02,
            0.02,
        ],
        &mut seed,
    );
    writeln!(out, ">THREE Homo sapiens frequency").unwrap();
    random(
        &mut out,
        5 * n,
        b"acgt",
        &[
            0.3029549426680,
            0.1979883004921,
            0.1975473066391,
            0.3015094502008,
        ],
        &mut seed,
    );
}
#[derive(Clone, Copy)]
struct Body {
    x: f64,
    y: f64,
    z: f64,
    vx: f64,
    vy: f64,
    vz: f64,
    m: f64,
}
fn energy(b: &[Body]) -> f64 {
    let mut e = 0.0;
    for i in 0..5 {
        let a = b[i];
        e += 0.5 * a.m * (a.vx * a.vx + a.vy * a.vy + a.vz * a.vz);
        for j in i + 1..5 {
            let dx = a.x - b[j].x;
            let dy = a.y - b[j].y;
            let dz = a.z - b[j].z;
            e -= a.m * b[j].m / (dx * dx + dy * dy + dz * dz).sqrt();
        }
    }
    e
}
pub fn n_body(n: usize) {
    let sm = 39.47841760435743;
    let yr = 365.24;
    let mut b = [
        Body {
            x: 0.,
            y: 0.,
            z: 0.,
            vx: 0.,
            vy: 0.,
            vz: 0.,
            m: sm,
        },
        Body {
            x: 4.84143144246472090,
            y: -1.16032004402742839,
            z: -0.103622044471123109,
            vx: 0.00166007664274403694 * yr,
            vy: 0.00769901118419740425 * yr,
            vz: -0.0000690460016972063023 * yr,
            m: 0.000954791938424326609 * sm,
        },
        Body {
            x: 8.34336671824457987,
            y: 4.12479856412430479,
            z: -0.403523417114321381,
            vx: -0.00276742510726862411 * yr,
            vy: 0.00499852801234917238 * yr,
            vz: 0.0000230417297573763929 * yr,
            m: 0.000285885980666130812 * sm,
        },
        Body {
            x: 12.8943695621391310,
            y: -15.1111514016986312,
            z: -0.223307578892655734,
            vx: 0.00296460137564761618 * yr,
            vy: 0.00237847173959480950 * yr,
            vz: -0.0000296589568540237556 * yr,
            m: 0.0000436624404335156298 * sm,
        },
        Body {
            x: 15.3796971148509165,
            y: -25.9193146099879641,
            z: 0.179258772950371181,
            vx: 0.00268067772490389322 * yr,
            vy: 0.00162824170038242295 * yr,
            vz: -0.0000951592254519715870 * yr,
            m: 0.0000515138902046611451 * sm,
        },
    ];
    for i in 0..5 {
        b[0].vx -= b[i].vx * b[i].m / sm;
        b[0].vy -= b[i].vy * b[i].m / sm;
        b[0].vz -= b[i].vz * b[i].m / sm;
    }
    println!("{:0.9}", energy(&b));
    for _ in 0..n {
        for i in 0..5 {
            for j in i + 1..5 {
                let dx = b[i].x - b[j].x;
                let dy = b[i].y - b[j].y;
                let dz = b[i].z - b[j].z;
                let d2 = dx * dx + dy * dy + dz * dz;
                let mag = 0.01 / (d2 * d2.sqrt());
                b[i].vx -= dx * b[j].m * mag;
                b[i].vy -= dy * b[j].m * mag;
                b[i].vz -= dz * b[j].m * mag;
                b[j].vx += dx * b[i].m * mag;
                b[j].vy += dy * b[i].m * mag;
                b[j].vz += dz * b[i].m * mag;
            }
        }
        for a in &mut b {
            a.x += 0.01 * a.vx;
            a.y += 0.01 * a.vy;
            a.z += 0.01 * a.vz;
        }
    }
    println!("{:0.9}", energy(&b));
}
