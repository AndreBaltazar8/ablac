package main

import (
	"fmt"
	"os"
	"regexp"
)

func main() {
	input, e := os.ReadFile(os.Args[2])
	if e != nil {
		panic(e)
	}
	s := regexp.MustCompile(">[^\n]*\n|\n").ReplaceAll(input, nil)
	clean := len(s)
	patterns := []string{"agggtaaa|tttaccct", "[cgt]gggtaaa|tttaccc[acg]", "a[act]ggtaaa|tttacc[agt]t", "ag[act]gtaaa|tttac[agt]ct", "agg[act]taaa|ttta[agt]cct", "aggg[acg]aaa|ttt[cgt]ccct", "agggt[cgt]aa|tt[acg]accct", "agggta[cgt]a|t[acg]taccct", "agggtaa[cgt]|[acg]ttaccct"}
	for _, p := range patterns {
		fmt.Printf("%s %d\n", p, len(regexp.MustCompile(p).FindAllIndex(s, -1)))
	}
	p := []string{"tHa[Nt]", "aND|caN|Ha[DS]|WaS", "a[NSt]|BY", "<[^>]*>", `\|[^|][^|]*\|`}
	r := []string{"<4>", "<3>", "<2>", "|", "-"}
	for i := range p {
		s = regexp.MustCompile(p[i]).ReplaceAll(s, []byte(r[i]))
	}
	fmt.Printf("\n%d\n%d\n%d\n", len(input), clean, len(s))
}
