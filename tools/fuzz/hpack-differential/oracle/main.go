// The reference side of tools/test-hpack-differential.sh (#1139 area 4 round 8): golang.org/x/net/http2/hpack's decoder. `gen SEED COUNT` writes
// cases, one a line: header blocks as h<hex>, space-separated, decoded in order by one decoder (its dynamic table carried across them); `decode`
// prints Go's verdicts: per case the blocks joined by '|', each "E" (an error; nothing after it) or the fields as hex(name)=hex(value) joined by ','.
package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"strings"

	"golang.org/x/net/http2/hpack"
)

var state uint64

func next() uint64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
func below(n int) int { return int(next() % uint64(n)) }

func integer(out []byte, first byte, prefix uint, value uint64) []byte {
	mask := uint64(1)<<prefix - 1
	if value < mask {
		return append(out, first|byte(value))
	}
	out = append(out, first|byte(mask))
	rest := value - mask
	for rest >= 128 {
		out = append(out, byte(rest&127)|128)
		rest >>= 7
	}
	out = append(out, byte(rest))
	if below(15) == 0 { // overlong: an extra zero continuation
		out[len(out)-1] |= 128
		out = append(out, 0)
	}
	return out
}

var names = []string{":method", ":path", "content-type", "x-a", "cookie", "a", "", "X-Up", "custom-key"}

func text() string {
	k := below(6)
	switch k {
	case 0:
		return ""
	case 1:
		return names[below(len(names))]
	case 2:
		b := make([]byte, below(8))
		for i := range b {
			b[i] = byte(below(256))
		}
		return string(b)
	default:
		b := make([]byte, below(20))
		for i := range b {
			b[i] = byte('a' + below(26))
		}
		return string(b)
	}
}

func str(out []byte, s string) []byte {
	if below(2) == 0 {
		h := hpack.AppendHuffmanString(nil, s)
		switch below(12) {
		case 0:
			if len(h) > 0 {
				h[below(len(h))] ^= byte(1 << below(8))
			}
		case 1:
			h = append(h, 0xff) // a padding byte too many
		case 2:
			if len(h) > 0 {
				h[len(h)-1] &^= 1 // padding not all ones (or a changed last symbol)
			}
		case 3:
			h = append(h, 0xff, 0xff, 0xff, 0xfc) // EOS
		}
		out = integer(out, 0x80, 7, uint64(len(h)))
		return append(out, h...)
	}
	out = integer(out, 0, 7, uint64(len(s)))
	if below(30) == 0 && len(s) > 0 {
		return append(out, s[:len(s)-1]...) // truncated
	}
	return append(out, s...)
}

func index() uint64 {
	switch below(5) {
	case 0:
		return uint64(1 + below(61))
	case 1:
		return uint64(62 + below(12))
	case 2:
		return 0
	case 3:
		return uint64(below(200))
	default:
		return uint64(1 + below(70))
	}
}

func block(first bool) []byte {
	var out []byte
	n := below(6)
	if below(4) == 0 {
		sizes := []uint64{0, 32, 64, 100, 4096, 4097, 1 << 20, uint64(below(5000))}
		out = integer(out, 0x20, 5, sizes[below(len(sizes))])
	}
	for i := 0; i < n; i++ {
		switch below(5) {
		case 0:
			out = integer(out, 0x80, 7, index())
		case 1, 2:
			idx := index()
			if below(2) == 0 {
				idx = 0
			}
			out = integer(out, 0x40, 6, idx)
			if idx == 0 {
				out = str(out, text())
			}
			out = str(out, text())
		case 3:
			idx := index()
			if below(2) == 0 {
				idx = 0
			}
			kind := byte(0)
			if below(2) == 0 {
				kind = 0x10
			}
			out = integer(out, kind, 4, idx)
			if idx == 0 {
				out = str(out, text())
			}
			out = str(out, text())
		default:
			// A size update after a field (an error, RFC 7541 4.2); not as the second item of a block, where two in a row are allowed and Go refuses
			// them once its table holds an entry (a known Go difference, not counted).
			if i > 0 && below(8) == 0 {
				out = integer(out, 0x20, 5, uint64(below(200))) // a size update after a field
			} else {
				out = integer(out, 0x80, 7, uint64(1+below(61)))
			}
		}
	}
	if below(25) == 0 && len(out) > 0 {
		out = out[:below(len(out))] // cut
	}
	return out
}

func main() {
	if len(os.Args) >= 4 && os.Args[1] == "gen" {
		seed, _ := strconv.ParseUint(os.Args[2], 10, 64)
		state = 0x9e3779b97f4a7c15 ^ seed*0x2545f4914f6cdd1d
		count, _ := strconv.Atoi(os.Args[3])
		w := bufio.NewWriter(os.Stdout)
		for c := 0; c < count; c++ {
			blocks := 1 + below(4)
			parts := make([]string, blocks)
			for b := 0; b < blocks; b++ {
				parts[b] = "h" + hex.EncodeToString(block(b == 0))
			}
			fmt.Fprintln(w, strings.Join(parts, " "))
		}
		w.Flush()
		return
	}
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 1<<20), 1<<24)
	w := bufio.NewWriter(os.Stdout)
	for in.Scan() {
		d := hpack.NewDecoder(4096, nil)
		d.SetMaxStringLength(16384)
		var verdicts []string
		for _, part := range strings.Fields(in.Text()) {
			data, _ := hex.DecodeString(part[1:])
			fields, err := d.DecodeFull(data)
			if err != nil {
				verdicts = append(verdicts, "E")
				break
			}
			var fs []string
			for _, f := range fields {
				fs = append(fs, hex.EncodeToString([]byte(f.Name))+"="+hex.EncodeToString([]byte(f.Value)))
			}
			verdicts = append(verdicts, strings.Join(fs, ","))
		}
		fmt.Fprintln(w, strings.Join(verdicts, "|"))
	}
	w.Flush()
}
