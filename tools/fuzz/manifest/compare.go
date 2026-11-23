package main

import (
	"fmt"
	"strings"

	"github.com/BurntSushi/toml"
)

// compare reads one manifest and lock the way the compiler's readers did (res) and the way a TOML parser does, and returns the differences. validManifest and validLock are 1
// when the file is TOML at all.
func compare(manifest, lock string, res *caseResult) (findings []finding, validManifest, validLock int) {
	add := func(reader, class, detail string) {
		findings = append(findings, finding{reader: reader, class: class, detail: detail})
	}
	var root map[string]any
	_, err := toml.Decode(manifest, &root)
	if err == nil {
		validManifest = 1
		for _, k := range []string{"name", "entry", "visibility", "version"} {
			truth, _ := asString(root[k])
			got := res.str[k]
			if got == truth {
				continue
			}
			class := "different"
			if truth == "" {
				class = "ghost"
			} else if got == "" {
				class = "missed"
			}
			add("string:"+k, class, fmt.Sprintf("reader %q, TOML %q (%T)", got, truth, root[k]))
		}
		for _, k := range []string{"compileCapabilities", "wasmHostImports", "nativeLibraries"} {
			truth, ok := asStrings(root[k])
			if !ok {
				truth = nil
			}
			got := res.arr[k]
			if equalStrings(got, truth) {
				continue
			}
			class := "different"
			if len(truth) == 0 {
				class = "ghost"
			} else if len(got) == 0 {
				class = "missed"
			} else {
				extra := false
				for _, g2 := range got {
					found := false
					for _, t := range truth {
						if t == g2 {
							found = true
						}
					}
					if !found {
						extra = true
					}
				}
				if !extra {
					class = "missed"
				}
			}
			add("array:"+k, class, fmt.Sprintf("reader %q, TOML %q", got, truth))
		}
		deps, _ := root["dependencies"].(map[string]any)
		for _, d := range res.deps {
			name, git, kind, sel := d[0], d[1], d[2], d[3]
			entry, ok := deps[name].(map[string]any)
			good := false
			if ok {
				g1, _ := asString(entry["git"])
				s1, _ := asString(entry[kind])
				good = g1 == git && s1 == sel
				for _, other := range []string{"rev", "tag", "branch"} {
					if other != kind {
						if _, has := entry[other]; has {
							good = false
						}
					}
				}
			}
			if !good {
				add("dependencies", "ghost", fmt.Sprintf("reader accepts %q git=%q %s=%q; TOML has %v", name, git, kind, sel, deps[name]))
			}
		}
		for _, pair := range []struct {
			table string
			items [][2]string
		}{{"exports", res.exps}} {
			truth, _ := root[pair.table].(map[string]any)
			for _, e := range pair.items {
				if v, ok := asString(truth[e[0]]); !ok || v != e[1] {
					add(pair.table, "ghost", fmt.Sprintf("reader has %q = %q; TOML has %v", e[0], e[1], truth[e[0]]))
				}
			}
		}
		imports, _ := root["imports"].(map[string]any)
		for _, e := range res.imps {
			if e[2] != "" || e[0] == "" {
				continue
			}
			if v, ok := asString(imports[e[0]]); !ok || v != e[1] {
				add("imports", "ghost", fmt.Sprintf("reader has %q = %q; TOML has %v", e[0], e[1], imports[e[0]]))
			}
		}
		grants, _ := root["dependencyCompileCapabilities"].(map[string]any)
		for _, g1 := range res.grant {
			if strings.HasPrefix(g1, "\t") {
				continue
			}
			parts := strings.SplitN(g1, "\t", 2)
			truth, ok := asStrings(grants[parts[0]])
			joined := strings.Join(truth, ",")
			if !ok || len(parts) < 2 || joined != parts[1] {
				add("dependencyCompileCapabilities", "ghost", fmt.Sprintf("reader has %q; TOML has %v", g1, grants[parts[0]]))
			}
		}
	} else {
		// Not TOML: what do the readers take of it?
		invalid := false
		for _, k := range []string{"name", "entry", "visibility", "version"} {
			if res.str[k] != "" {
				invalid = true
			}
		}
		for _, k := range []string{"compileCapabilities", "wasmHostImports", "nativeLibraries"} {
			if len(res.arr[k]) > 0 {
				invalid = true
			}
		}
		if len(res.deps) > 0 || len(res.exps) > 0 {
			invalid = true
		}
		if invalid {
			add("manifest-not-toml", "taken", err.Error())
		}
	}
	var lockRoot map[string]any
	_, lerr := toml.Decode(lock, &lockRoot)
	if lerr == nil {
		validLock = 1
		records, _ := lockRoot["package"].([]map[string]any)
		if res.lockV {
			fieldsOf := []string{"name", "provider", "identity", "source", "selector-kind", "selector", "revision", "digest", "entry"}
			if len(res.lock) != len(records) {
				add("lock", "different", fmt.Sprintf("reader has %d packages, TOML has %d", len(res.lock), len(records)))
			} else {
				for r2, rec := range res.lock {
					for f, field := range fieldsOf {
						truth, _ := asString(records[r2][field])
						if rec[f] == truth {
							continue
						}
						class := "different"
						if truth == "" {
							class = "ghost"
						} else if rec[f] == "" {
							class = "missed"
						}
						add("lock:"+field, class, fmt.Sprintf("package %d: reader %q, TOML %q", r2, rec[f], truth))
					}
				}
			}
		}
	} else if res.lockV && len(res.lock) > 0 {
		add("lock-not-toml", "taken", lerr.Error())
	}
	return
}
