// manifestdiff: the compiler's hand-written manifest and lock readers against a TOML parser (#1139 area 2, round 2).
//
//	manifestdiff -readers ./readers -dir DIR -count N -seed S [-examples K]
//
// It writes N cases (DIR/c<i>/abla.toml and abla.lock), runs the readers program (tools/fuzz/manifest/readers.ab, built by the caller) over them, reads each file with
// BurntSushi/toml, and reports where they differ: "ghost" (a reader sees a key, item or value that TOML does not have there: the dangerous direction, it is what a
// reviewer or a TOML tool would not see), "different" (a value that differs) and "missed" (TOML has it and the reader does not: fails closed, informational).
package main

import (
	"bufio"
	"encoding/hex"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type finding struct {
	reader, class string
	index         int
	detail        string
	tags          []string
	size          int
}

func unhex(s string) string {
	if s == "-" {
		return ""
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return "?bad-hex?"
	}
	return string(b)
}

type caseResult struct {
	str   map[string]string
	arr   map[string][]string
	deps  [][4]string
	depsN int
	exps  [][2]string
	expsF bool
	imps  [][3]string
	grant []string
	lock  [][9]string
	lockV bool
}

func parseOutput(path string) (map[int]*caseResult, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := map[int]*caseResult{}
	var cur *caseResult
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1<<20), 1<<26)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 0 {
			continue
		}
		switch fields[0] {
		case "CASE":
			i, _ := strconv.Atoi(fields[1])
			cur = &caseResult{str: map[string]string{}, arr: map[string][]string{}}
			out[i] = cur
		case "STR":
			cur.str[fields[1]] = unhex(fields[2])
		case "ARR":
			n, _ := strconv.Atoi(fields[2])
			var list []string
			for k := 0; k < n; k++ {
				list = append(list, unhex(fields[3+k]))
			}
			cur.arr[fields[1]] = list
		case "DEP":
			n, _ := strconv.Atoi(fields[1])
			cur.depsN, _ = strconv.Atoi(fields[2])
			for k := 0; k < n; k++ {
				b := 3 + 4*k
				cur.deps = append(cur.deps, [4]string{unhex(fields[b]), unhex(fields[b+1]), unhex(fields[b+2]), unhex(fields[b+3])})
			}
		case "EXP":
			cur.expsF = fields[1] == "1"
			n, _ := strconv.Atoi(fields[2])
			for k := 0; k < n; k++ {
				cur.exps = append(cur.exps, [2]string{unhex(fields[3+2*k]), unhex(fields[4+2*k])})
			}
		case "IMP":
			n, _ := strconv.Atoi(fields[1])
			for k := 0; k < n; k++ {
				cur.imps = append(cur.imps, [3]string{unhex(fields[2+3*k]), unhex(fields[3+3*k]), unhex(fields[4+3*k])})
			}
		case "GRANT":
			n, _ := strconv.Atoi(fields[1])
			for k := 0; k < n; k++ {
				cur.grant = append(cur.grant, unhex(fields[2+k]))
			}
		case "LOCK":
			cur.lockV = fields[1] == "1"
			n, _ := strconv.Atoi(fields[2])
			for k := 0; k < n; k++ {
				var rec [9]string
				for m := 0; m < 9; m++ {
					rec[m] = unhex(fields[3+9*k+m])
				}
				cur.lock = append(cur.lock, rec)
			}
		}
	}
	return out, scanner.Err()
}

func asString(v any) (string, bool) { s, ok := v.(string); return s, ok }

func asStrings(v any) ([]string, bool) {
	list, ok := v.([]any)
	if !ok {
		list2, ok2 := v.([]string)
		return list2, ok2
	}
	var out []string
	for _, e := range list {
		s, ok := e.(string)
		if !ok {
			return nil, false
		}
		out = append(out, s)
	}
	return out, true
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func main() {
	readers := flag.String("readers", "./readers", "the readers program")
	dir := flag.String("dir", "build/manifest-diff", "where the cases go")
	count := flag.Int("count", 1000, "cases")
	seed := flag.Int64("seed", 1, "seed")
	examples := flag.Int("examples", 2, "examples per kind of difference")
	flag.Parse()
	os.RemoveAll(*dir)
	type meta struct {
		manifest, lock string
		mtags, ltags   []string
	}
	cases := make([]meta, *count)
	for i := 0; i < *count; i++ {
		g := &gen{r: rand.New(rand.NewSource(*seed*1000003 + int64(i))), tags: map[string]bool{}}
		g.plain = g.r.Intn(100) < 35
		manifest := g.manifest()
		mtags := tagList(g.tags)
		g.tags = map[string]bool{}
		lock := g.lock()
		ltags := tagList(g.tags)
		cases[i] = meta{manifest, lock, mtags, ltags}
		d := filepath.Join(*dir, fmt.Sprintf("c%d", i))
		os.MkdirAll(d, 0o755)
		os.WriteFile(filepath.Join(d, "abla.toml"), []byte(manifest), 0o644)
		os.WriteFile(filepath.Join(d, "abla.lock"), []byte(lock), 0o644)
	}
	outPath := filepath.Join(*dir, "readers.out")
	cmd := exec.Command(*readers, *dir, strconv.Itoa(*count))
	outFile, _ := os.Create(outPath)
	cmd.Stdout = outFile
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "the readers program failed:", err)
		os.Exit(2)
	}
	outFile.Close()
	results, err := parseOutput(outPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	var findings []finding
	validManifest, validLock := 0, 0
	for i := 0; i < *count; i++ {
		res := results[i]
		if res == nil {
			findings = append(findings, finding{"harness", "missing-case", i, "no output", nil, 0})
			continue
		}
		found, vm, vl := compare(cases[i].manifest, cases[i].lock, res)
		validManifest += vm
		validLock += vl
		for _, f := range found {
			f.index = i
			if strings.HasPrefix(f.reader, "lock") {
				f.tags = cases[i].ltags
				f.size = len(cases[i].lock)
			} else {
				f.tags = cases[i].mtags
				f.size = len(cases[i].manifest)
			}
			findings = append(findings, f)
		}
	}
	agreed := map[string]int{}
	var differences []finding
	for _, f := range findings {
		if f.class == "agree" {
			agreed[f.reader]++
		} else {
			differences = append(differences, f)
		}
	}
	findings = differences
	fmt.Printf("manifestdiff: %d cases (%d manifests and %d locks are valid TOML), %d differences\n", *count, validManifest, validLock, len(findings))
	var agreedKeys []string
	for k := range agreed {
		agreedKeys = append(agreedKeys, k)
	}
	sort.Strings(agreedKeys)
	for _, k := range agreedKeys {
		fmt.Printf("agree %s: %d cases\n", k, agreed[k])
	}
	type key struct{ reader, class string }
	groups := map[key][]finding{}
	for _, f := range findings {
		k := key{f.reader, f.class}
		groups[k] = append(groups[k], f)
	}
	var keys []key
	for k := range groups {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(a, b int) bool {
		if keys[a].class != keys[b].class {
			return classRank(keys[a].class) < classRank(keys[b].class)
		}
		return keys[a].reader < keys[b].reader
	})
	for _, k := range keys {
		list := groups[k]
		fmt.Printf("\n%s %s: %d cases\n", k.class, k.reader, len(list))
		tagCount := map[string]int{}
		for _, f := range list {
			for _, t := range f.tags {
				tagCount[t]++
			}
		}
		var tagKeys []string
		for t := range tagCount {
			tagKeys = append(tagKeys, t)
		}
		sort.Slice(tagKeys, func(a, b int) bool { return tagCount[tagKeys[a]] > tagCount[tagKeys[b]] })
		if len(tagKeys) > 6 {
			tagKeys = tagKeys[:6]
		}
		for _, t := range tagKeys {
			fmt.Printf("    %4d with %s\n", tagCount[t], t)
		}
		sort.Slice(list, func(a, b int) bool { return list[a].size < list[b].size })
		for n := 0; n < *examples && n < len(list); n++ {
			fmt.Printf("  e.g. case %d: %s [%s]\n", list[n].index, list[n].detail, strings.Join(list[n].tags, " "))
			if k.class == "ghost" || k.class == "different" {
				m, l, why := minimize(*readers, filepath.Join(*dir, "min"), cases[list[n].index].manifest, cases[list[n].index].lock, k.reader, k.class, list[n].detail)
				text := m
				if strings.HasPrefix(k.reader, "lock") {
					text = l
				}
				fmt.Printf("  minimal (%d bytes): %s\n    -> %s\n", len(text), fmt.Sprintf("%q", text), why)
			}
		}
	}
}

func classRank(c string) int {
	switch c {
	case "ghost":
		return 0
	case "different":
		return 1
	case "taken":
		return 2
	}
	return 3
}

func tagList(m map[string]bool) []string {
	var out []string
	for t := range m {
		out = append(out, t)
	}
	sort.Strings(out)
	return out
}
