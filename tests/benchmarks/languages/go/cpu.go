package main

import (
	"bufio"
	"fmt"
	"math"
	"os"
)

type Tree struct{ left, right *Tree }

func makeTree(d int) *Tree {
	t := &Tree{}
	if d > 0 {
		t.left = makeTree(d - 1)
		t.right = makeTree(d - 1)
	}
	return t
}
func check(t *Tree) int64 {
	if t.left == nil {
		return 1
	}
	return 1 + check(t.left) + check(t.right)
}
func binaryTrees(n int) {
	fmt.Printf("stretch %d\n", check(makeTree(n+1)))
	long := makeTree(n)
	for d := 4; d <= n; d += 2 {
		rounds := 1 << (n - d + 4)
		var sum int64
		for i := 0; i < rounds; i++ {
			sum += check(makeTree(d))
		}
		fmt.Printf("%d %d %d\n", d, rounds, sum)
	}
	fmt.Printf("long %d\n", check(long))
}
func fannkuch(n int) {
	p := make([]int, n)
	count := make([]int, n)
	q := make([]int, n)
	for i := range p {
		p[i] = i
	}
	r, maximum, checksum, idx := n, 0, 0, 0
	for {
		for r != 1 {
			count[r-1] = r
			r--
		}
		copy(q, p)
		flips := 0
		for q[0] != 0 {
			k := q[0]
			for i, j := 0, k; i < j; i, j = i+1, j-1 {
				q[i], q[j] = q[j], q[i]
			}
			flips++
		}
		if flips > maximum {
			maximum = flips
		}
		if idx%2 == 0 {
			checksum += flips
		} else {
			checksum -= flips
		}
		idx++
		for {
			if r == n {
				fmt.Printf("%d %d\n", checksum, maximum)
				return
			}
			first := p[0]
			for i := 0; i < r; i++ {
				p[i] = p[i+1]
			}
			p[r] = first
			count[r]--
			if count[r] > 0 {
				break
			}
			r++
		}
	}
}
func matrixA(i, j int) float64 { return 1 / float64((i+j)*(i+j+1)/2+i+1) }
func multiply(u, v []float64, trans bool) {
	for i := range u {
		s := 0.0
		for j := range u {
			if trans {
				s += matrixA(j, i) * u[j]
			} else {
				s += matrixA(i, j) * u[j]
			}
		}
		v[i] = s
	}
}
func spectralNorm(n int) {
	u, v, t := make([]float64, n), make([]float64, n), make([]float64, n)
	for i := range u {
		u[i] = 1
	}
	for i := 0; i < 10; i++ {
		multiply(u, t, false)
		multiply(t, v, true)
		multiply(v, t, false)
		multiply(t, u, true)
	}
	uv, vv := 0.0, 0.0
	for i := range u {
		uv += u[i] * v[i]
		vv += v[i] * v[i]
	}
	fmt.Printf("%.9f\n", math.Sqrt(uv/vv))
}
func mandelbrot(n int) {
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	fmt.Fprintf(out, "P4\n%d %d\n", n, n)
	for y := 0; y < n; y++ {
		byte, bits := 0, 0
		for x := 0; x < n; x++ {
			cr, ci := 2*float64(x)/float64(n)-1.5, 2*float64(y)/float64(n)-1
			zr, zi, k := 0.0, 0.0, 0
			for k < 50 && zr*zr+zi*zi <= 4 {
				next := zr*zr - zi*zi + cr
				zi = 2*zr*zi + ci
				zr = next
				k++
			}
			byte <<= 1
			if zr*zr+zi*zi <= 4 {
				byte |= 1
			}
			bits++
			if bits == 8 {
				out.WriteByte(uint8(byte))
				byte = 0
				bits = 0
			}
		}
		if bits > 0 {
			out.WriteByte(uint8(byte << (8 - bits)))
		}
	}
}

const alu = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA"

func randomSequence(out *bufio.Writer, n int, letters string, prob []float64, seed *int) {
	for i := 0; i < n; i++ {
		*seed = (*seed*3877 + 29573) % 139968
		r := float64(*seed) / 139968
		c := 0.0
		j := 0
		for j < len(letters)-1 {
			c += prob[j]
			if r < c {
				break
			}
			j++
		}
		out.WriteByte(letters[j])
		if i%60 == 59 || i == n-1 {
			out.WriteByte(10)
		}
	}
}
func fasta(n int) {
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	fmt.Fprintln(out, ">ONE Homo sapiens alu")
	for i := 0; i < 2*n; i++ {
		out.WriteByte(alu[i%len(alu)])
		if i%60 == 59 || i == 2*n-1 {
			out.WriteByte(10)
		}
	}
	fmt.Fprintln(out, ">TWO IUB ambiguity codes")
	seed := 42
	randomSequence(out, 3*n, "acgtBDHKMNRSVWY", []float64{.27, .12, .12, .27, .02, .02, .02, .02, .02, .02, .02, .02, .02, .02, .02}, &seed)
	fmt.Fprintln(out, ">THREE Homo sapiens frequency")
	randomSequence(out, 5*n, "acgt", []float64{.3029549426680, .1979883004921, .1975473066391, .3015094502008}, &seed)
}

type Body struct{ x, y, z, vx, vy, vz, m float64 }

func energy(b []Body) float64 {
	e := 0.0
	for i, a := range b {
		e += .5 * a.m * (a.vx*a.vx + a.vy*a.vy + a.vz*a.vz)
		for j := i + 1; j < 5; j++ {
			dx, dy, dz := a.x-b[j].x, a.y-b[j].y, a.z-b[j].z
			e -= a.m * b[j].m / math.Sqrt(dx*dx+dy*dy+dz*dz)
		}
	}
	return e
}
func nBody(n int) {
	sm, yr := 39.47841760435743, 365.24
	b := []Body{
		{0, 0, 0, 0, 0, 0, sm},
		{4.84143144246472090, -1.16032004402742839, -.103622044471123109, .00166007664274403694 * yr, .00769901118419740425 * yr, -.0000690460016972063023 * yr, .000954791938424326609 * sm},
		{8.34336671824457987, 4.12479856412430479, -.403523417114321381, -.00276742510726862411 * yr, .00499852801234917238 * yr, .0000230417297573763929 * yr, .000285885980666130812 * sm},
		{12.8943695621391310, -15.1111514016986312, -.223307578892655734, .00296460137564761618 * yr, .00237847173959480950 * yr, -.0000296589568540237556 * yr, .0000436624404335156298 * sm},
		{15.3796971148509165, -25.9193146099879641, .179258772950371181, .00268067772490389322 * yr, .00162824170038242295 * yr, -.0000951592254519715870 * yr, .0000515138902046611451 * sm}}
	for i := range b {
		b[0].vx -= b[i].vx * b[i].m / sm
		b[0].vy -= b[i].vy * b[i].m / sm
		b[0].vz -= b[i].vz * b[i].m / sm
	}
	fmt.Printf("%.9f\n", energy(b))
	for s := 0; s < n; s++ {
		for i := 0; i < 5; i++ {
			for j := i + 1; j < 5; j++ {
				a, other := &b[i], &b[j]
				dx, dy, dz := a.x-other.x, a.y-other.y, a.z-other.z
				d2 := dx*dx + dy*dy + dz*dz
				mag := .01 / (d2 * math.Sqrt(d2))
				a.vx -= dx * other.m * mag
				a.vy -= dy * other.m * mag
				a.vz -= dz * other.m * mag
				other.vx += dx * a.m * mag
				other.vy += dy * a.m * mag
				other.vz += dz * a.m * mag
			}
		}
		for i := range b {
			b[i].x += .01 * b[i].vx
			b[i].y += .01 * b[i].vy
			b[i].z += .01 * b[i].vz
		}
	}
	fmt.Printf("%.9f\n", energy(b))
}
