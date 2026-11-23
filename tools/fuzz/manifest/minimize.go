package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// runReaders writes the pairs as cases under dir and runs the readers program over them.
func runReaders(readers, dir string, pairs [][2]string) ([]*caseResult, error) {
	os.RemoveAll(dir)
	for i, p := range pairs {
		d := filepath.Join(dir, fmt.Sprintf("c%d", i))
		os.MkdirAll(d, 0o755)
		os.WriteFile(filepath.Join(d, "abla.toml"), []byte(p[0]), 0o644)
		os.WriteFile(filepath.Join(d, "abla.lock"), []byte(p[1]), 0o644)
	}
	out := filepath.Join(dir, "readers.out")
	f, _ := os.Create(out)
	cmd := exec.Command(readers, dir, strconv.Itoa(len(pairs)))
	cmd.Stdout = f
	err := cmd.Run()
	f.Close()
	if err != nil {
		return nil, err
	}
	parsed, err := parseOutput(out)
	if err != nil {
		return nil, err
	}
	results := make([]*caseResult, len(pairs))
	for i := range pairs {
		results[i] = parsed[i]
	}
	return results, nil
}

func hasFinding(found []finding, reader, class string) bool {
	for _, f := range found {
		if f.reader == reader && f.class == class {
			return true
		}
	}
	return false
}

// minimize removes lines of the manifest (or of the lock) one at a time while the same kind of difference stays, until none can go.
func minimize(readers, dir, manifest, lock string, reader, class, detail string) (string, string, string) {
	isLock := strings.HasPrefix(reader, "lock")
	for round := 0; round < 40; round++ {
		text := manifest
		if isLock {
			text = lock
		}
		lines := strings.SplitAfter(text, "\n")
		if len(lines) <= 1 {
			break
		}
		var pairs [][2]string
		for i := range lines {
			cut := strings.Join(lines[:i], "") + strings.Join(lines[i+1:], "")
			if isLock {
				pairs = append(pairs, [2]string{manifest, cut})
			} else {
				pairs = append(pairs, [2]string{cut, lock})
			}
		}
		results, err := runReaders(readers, dir, pairs)
		if err != nil {
			break
		}
		progressed := false
		for i, res := range results {
			if res == nil {
				continue
			}
			found, _, _ := compare(pairs[i][0], pairs[i][1], res)
			if hasFinding(found, reader, class) {
				for _, f := range found {
					if f.reader == reader && f.class == class {
						detail = f.detail
						break
					}
				}
				manifest, lock = pairs[i][0], pairs[i][1]
				progressed = true
				break
			}
		}
		if !progressed {
			break
		}
	}
	return manifest, lock, detail
}
