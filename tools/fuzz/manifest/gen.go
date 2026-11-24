package main

// The generator: manifests and lock files that mix what TOML allows (and some it does not) around the keys the compiler's line-based readers look for. Each construct it
// uses is recorded as a tag, so a difference can be reported by the construct that caused it.

import (
	"fmt"
	"math/rand"
	"strings"
)

type gen struct {
	r     *rand.Rand
	tags  map[string]bool
	nl    string
	plain bool // only the forms the compiler's grammar admits: a positive control, readers and TOML should agree on every value
}

var values = []string{"lib", "a b", "x#y", "q\"r", "back\\slash", "é€😀", "tab\there", "key = \"inj\"", "[table]", "rev = \"abc\"", "", "main.ab", "../up", "a'b", "\u007f", "x=y", "p,q", "name"}
var capabilityNames = []string{"filesystem.read", "process.io", "network", "trusted.native", "none", "x"}

func (g *gen) tag(t string) { g.tags[t] = true }

func (g *gen) pick(list []string) string { return list[g.r.Intn(len(list))] }

func (g *gen) chance(percent int) bool { return g.r.Intn(100) < percent }

func basic(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, c := range s {
		switch {
		case c == '"':
			b.WriteString(`\"`)
		case c == '\\':
			b.WriteString(`\\`)
		case c == '\t':
			b.WriteString(`\t`)
		case c < 0x20 || c == 0x7f:
			fmt.Fprintf(&b, `\u%04x`, c)
		default:
			b.WriteRune(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// A string value in one of TOML's four string forms (or an invalid one), as the text after `key =`.
func (g *gen) str(v string) string {
	if g.plain {
		if strings.ContainsAny(v, "\"\\\n\r\t\x7f") {
			v = "x"
		}
		return `"` + v + `"`
	}
	switch g.r.Intn(12) {
	case 0:
		if !strings.ContainsAny(v, "'\n\r") && !strings.ContainsRune(v, 0x7f) {
			g.tag("literal-string")
			return "'" + v + "'"
		}
	case 1:
		g.tag("multiline-basic")
		return `"""` + g.nl + strings.ReplaceAll(strings.ReplaceAll(v, `\`, `\\`), `"""`, `\"\"\"`) + `"""`
	case 2:
		if !strings.Contains(v, "'''") {
			g.tag("multiline-literal")
			return "'''" + g.nl + v + "'''"
		}
	case 3:
		g.tag("escaped-unicode")
		var b strings.Builder
		b.WriteByte('"')
		for _, c := range v {
			if c > 0x7f {
				fmt.Fprintf(&b, `\u%04X`, c)
			} else if c == '"' || c == '\\' {
				b.WriteByte('\\')
				b.WriteRune(c)
			} else if c < 0x20 || c == 0x7f {
				fmt.Fprintf(&b, `\u%04x`, c)
			} else {
				b.WriteRune(c)
			}
		}
		b.WriteByte('"')
		return b.String()
	}
	return basic(v)
}

// A key in one of its spellings.
func (g *gen) key(k string) string {
	if g.plain {
		return k
	}
	switch g.r.Intn(14) {
	case 0:
		g.tag("quoted-key")
		return `"` + k + `"`
	case 1:
		g.tag("literal-quoted-key")
		return "'" + k + "'"
	case 2:
		g.tag("spaced-key")
		return k + "   "
	case 3:
		g.tag("tight-equals")
		return k
	}
	return k
}

func (g *gen) assign(k, value string) string {
	if g.plain {
		return k + " = " + value
	}
	switch g.r.Intn(8) {
	case 0:
		return g.key(k) + "=" + value
	case 1:
		g.tag("tab-spacing")
		return g.key(k) + "\t=\t" + value
	case 2:
		g.tag("trailing-comment")
		return g.key(k) + " = " + value + " # " + g.pick([]string{"c", "key = \"c\"", "\"", "x \" y"})
	}
	return g.key(k) + " = " + value
}

func (g *gen) array(items []string) string {
	var parts []string
	for _, it := range items {
		parts = append(parts, g.str(it))
	}
	if g.plain {
		return "[" + strings.Join(parts, ", ") + "]"
	}
	switch g.r.Intn(6) {
	case 0:
		g.tag("multiline-array")
		return "[" + g.nl + "  " + strings.Join(parts, ","+g.nl+"  ") + "," + g.nl + "]"
	case 1:
		g.tag("array-comment")
		return "[" + g.nl + "  # a comment with \"quotes\" ]" + g.nl + "  " + strings.Join(parts, ", ") + g.nl + "]"
	case 2:
		g.tag("array-trailing-comma")
		return "[" + strings.Join(parts, ", ") + ",]"
	case 3:
		g.tag("array-nested")
		return "[[" + strings.Join(parts, ", ") + "], " + g.str("z") + "]"
	case 4:
		g.tag("array-multiline-break")
		return "[" + strings.Join(parts, ","+g.nl) + "]"
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

var stringKeys = []string{"name", "entry", "visibility", "version"}
var arrayKeys = []string{"compileCapabilities", "wasmHostImports", "nativeLibraries"}

// rootItems: the root keys and decoys of them.
func (g *gen) rootItems() []string {
	var out []string
	for _, k := range stringKeys {
		if g.chance(55) {
			out = append(out, g.assign(k, g.str(g.pick(values))))
		}
		if g.chance(8) {
			g.tag("duplicate-root-key")
			out = append(out, g.assign(k, g.str(g.pick(values))))
		}
		if g.chance(6) {
			g.tag("dotted-key")
			out = append(out, k+".sub = "+g.str("v"))
		}
		if g.chance(5) {
			g.tag("inline-table-root")
			out = append(out, "meta = { "+k+" = "+g.str(g.pick(values))+" }")
		}
	}
	for _, k := range arrayKeys {
		if g.chance(55) {
			var items []string
			for n := g.r.Intn(4); n >= 0; n-- {
				items = append(items, g.pick(capabilityNames))
			}
			out = append(out, g.assign(k, g.array(items)))
		}
		if g.chance(8) {
			g.tag("duplicate-root-key")
			out = append(out, g.assign(k, g.array([]string{g.pick(capabilityNames)})))
		}
	}
	// A multi-line string that carries lines that look like keys.
	if g.chance(15) {
		g.tag("keys-in-multiline-string")
		var lines []string
		for n := 1 + g.r.Intn(3); n > 0; n-- {
			if g.chance(50) {
				lines = append(lines, g.pick(stringKeys)+" = "+basic(g.pick(values)))
			} else {
				lines = append(lines, g.pick(arrayKeys)+" = "+g.array([]string{g.pick(capabilityNames)}))
			}
		}
		delim := `"""`
		if g.chance(50) {
			delim = "'''"
			for i := range lines {
				lines[i] = strings.ReplaceAll(lines[i], "'''", "")
			}
		} else {
			for i := range lines {
				lines[i] = strings.ReplaceAll(strings.ReplaceAll(lines[i], `\`, `\\`), `"""`, `\"\"\"`)
			}
		}
		out = append(out, "description = "+delim+g.nl+strings.Join(lines, g.nl)+g.nl+delim)
	}
	if g.chance(15) {
		g.tag("key-in-comment")
		out = append(out, "# "+g.pick(stringKeys)+" = "+basic(g.pick(values)))
	}
	if g.chance(10) {
		g.tag("array-key-in-comment")
		out = append(out, "# "+g.pick(arrayKeys)+" = "+g.array([]string{g.pick(capabilityNames)}))
	}
	g.r.Shuffle(len(out), func(i, j int) { out[i], out[j] = out[j], out[i] })
	return out
}

func (g *gen) decoyTable() string {
	name := g.pick([]string{"package", "metadata", "decoy", "extra", "tool.abla", "x"})
	g.tag("key-in-other-table")
	var lines []string
	lines = append(lines, "["+name+"]")
	for n := 1 + g.r.Intn(3); n > 0; n-- {
		if g.chance(50) {
			lines = append(lines, g.assign(g.pick(stringKeys), g.str(g.pick(values))))
		} else {
			lines = append(lines, g.assign(g.pick(arrayKeys), g.array([]string{g.pick(capabilityNames)})))
		}
	}
	if g.chance(20) {
		g.tag("array-of-tables-decoy")
		lines[0] = "[[" + name + "]]"
	}
	return strings.Join(lines, g.nl)
}

var dependencyNames = []string{"alpha", "beta", "gamma", "d-e", "x.y", "foo_bar"}
var gitSources = []string{"https://example.test/a.git", "git@example.test:a/b.git", "../local", "https://h/r.git?rev = \"abc\"", "ssh://h/p", "-evil", "ext::sh -c x", "file:///tmp/x"}
var revisions = []string{"0123456789abcdef0123456789abcdef01234567", "v1.2", "main", "abc", "refs/heads/x", ""}

func (g *gen) dependenciesTable() string {
	lines := []string{"[dependencies]"}
	for n := g.r.Intn(4); n > 0; n-- {
		name := g.pick(dependencyNames)
		git := g.pick(gitSources)
		selector := g.pick([]string{"rev", "tag", "branch"})
		inline := "{ git = " + g.str(git) + ", " + selector + " = " + g.str(g.pick(revisions)) + " }"
		switch g.r.Intn(10) {
		case 0:
			g.tag("dep-two-selectors")
			inline = "{ git = " + g.str(git) + ", rev = " + g.str(g.pick(revisions)) + ", tag = " + g.str("t") + " }"
		case 1:
			g.tag("dep-selector-in-git-string")
			inline = "{ git = " + g.str(git+" rev = \"x\"") + ", " + selector + " = " + g.str(g.pick(revisions)) + " }"
		case 2:
			g.tag("dep-multiline-inline")
			inline = "{" + g.nl + "  git = " + g.str(git) + "," + g.nl + "  " + selector + " = " + g.str(g.pick(revisions)) + g.nl + "}"
		case 3:
			g.tag("dep-extra-key")
			inline = "{ git = " + g.str(git) + ", " + selector + " = " + g.str(g.pick(revisions)) + ", path = " + g.str("../x") + " }"
		case 4:
			g.tag("dep-dotted")
			lines = append(lines, name+".git = "+g.str(git), name+"."+selector+" = "+g.str(g.pick(revisions)))
			continue
		case 5:
			g.tag("dep-quoted-name")
			name = `"` + name + `"`
		case 6:
			g.tag("dep-key-order")
			inline = "{ " + selector + " = " + g.str(g.pick(revisions)) + ", git = " + g.str(git) + " }"
		}
		lines = append(lines, g.assign(name, inline))
	}
	if g.chance(15) {
		g.tag("dep-in-string-decoy")
		lines = append(lines, "note = "+g.str("evil = { git = \"https://example.test/e.git\", rev = \"abc\" }"))
	}
	return strings.Join(lines, g.nl)
}

func (g *gen) pairTable(header string, quotedKeys bool) string {
	lines := []string{"[" + header + "]"}
	for n := g.r.Intn(4); n > 0; n-- {
		k := g.pick([]string{"util", "text/json", "a.b", "x", "e é"})
		v := g.pick([]string{"util/entry.ab", "x.ab", "b.ab", "../out"})
		switch g.r.Intn(6) {
		case 0:
			g.tag("pair-bare-key")
			lines = append(lines, "x = "+g.str(v))
			continue
		case 1:
			g.tag("pair-literal")
			if !strings.ContainsAny(k, "'") {
				lines = append(lines, "'"+k+"' = "+g.str(v))
				continue
			}
		case 2:
			g.tag("pair-single-line-value-extra")
			lines = append(lines, `"`+k+`" = "`+v+`" "tail"`)
			continue
		case 3:
			g.tag("pair-escaped-quote-key")
			lines = append(lines, basic(k+`"q`)+" = "+g.str(v))
			continue
		}
		lines = append(lines, g.assign(basic(k), g.str(v)))
	}
	return strings.Join(lines, g.nl)
}

func (g *gen) grantsTable() string {
	lines := []string{"[dependencyCompileCapabilities]"}
	for n := g.r.Intn(3); n > 0; n-- {
		name := g.pick(dependencyNames)
		var items []string
		for m := g.r.Intn(3); m >= 0; m-- {
			items = append(items, g.pick(capabilityNames))
		}
		lines = append(lines, g.assign(name, g.array(items)))
	}
	return strings.Join(lines, g.nl)
}

func (g *gen) manifest() string {
	g.nl = "\n"
	if g.plain {
		g.tag("plain")
		return g.plainManifest()
	}
	switch g.r.Intn(12) {
	case 0:
		g.nl = "\r\n"
		g.tag("crlf")
	case 1:
		g.tag("bom")
	}
	var parts []string
	root := g.rootItems()
	tables := []string{}
	if g.chance(50) {
		tables = append(tables, g.dependenciesTable())
	}
	if g.chance(30) {
		tables = append(tables, g.pairTable("exports", true))
	}
	if g.chance(30) {
		tables = append(tables, g.pairTable("imports", true))
	}
	if g.chance(30) {
		tables = append(tables, g.grantsTable())
	}
	for n := g.r.Intn(3); n > 0; n-- {
		tables = append(tables, g.decoyTable())
	}
	g.r.Shuffle(len(tables), func(i, j int) { tables[i], tables[j] = tables[j], tables[i] })
	if g.chance(8) && len(tables) > 0 {
		g.tag("root-key-after-table")
		tables = append(tables, root...)
		parts = tables
	} else {
		parts = append(root, tables...)
	}
	out := strings.Join(parts, g.nl+g.nl) + g.nl
	if g.tags["bom"] {
		out = "\xef\xbb\xbf" + out
	}
	if g.chance(3) {
		g.tag("nul-byte")
		out = strings.Replace(out, "=", "= \x00", 1)
	}
	if g.chance(3) {
		g.tag("bare-cr")
		out = strings.Replace(out, g.nl, "\r", 1)
	}
	return out
}

var lockPools = map[string][]string{
	"name":          {"alpha", "beta-1", "g_2", "evil"},
	"provider":      {"git"},
	"identity":      {"git:https://example.test/a.git", "git:https://example.test/b.git"},
	"source":        {"https://example.test/a.git", "https://example.test/b.git", "ssh://h/p"},
	"selector-kind": {"rev", "tag", "branch", "head"},
	"selector":      {"0123456789abcdef0123456789abcdef01234567", "v1.2", "main", "fedcba9876543210fedcba9876543210fedcba98"},
	"revision":      {"0123456789abcdef0123456789abcdef01234567", "fedcba9876543210fedcba9876543210fedcba98"},
	"digest":        {"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
	"entry":         {"src/main.ab", "lib.ab", "a/b.ab"},
}

func (g *gen) lock() string {
	g.nl = "\n"
	if g.plain {
		g.tag("plain")
		return g.plainLock()
	}
	if g.chance(10) {
		g.nl = "\r\n"
		g.tag("lock-crlf")
	}
	fields := []string{"name", "provider", "identity", "source", "selector-kind", "selector", "revision", "digest", "entry"}
	pick := func(f string) string { return g.pick(lockPools[f]) }
	var parts []string
	parts = append(parts, "# lock")
	for n := 1 + g.r.Intn(3); n > 0; n-- {
		var lines []string
		lines = append(lines, "[[package]]")
		for _, f := range fields {
			if g.chance(97) {
				lines = append(lines, g.assign(f, g.str(pick(f))))
			}
			if g.chance(5) {
				g.tag("lock-duplicate-field")
				lines = append(lines, g.assign(f, g.str(pick(f))))
			}
			if g.chance(4) {
				g.tag("lock-dotted-key")
				lines = append(lines, f+".sub = "+g.str("v"))
			}
		}
		if g.chance(15) {
			g.tag("lock-subtable")
			f := g.pick(fields)
			lines = append(lines, "[package.extra]", g.assign(f, g.str(pick(f))))
		}
		if g.chance(12) {
			g.tag("lock-fields-in-multiline-string")
			f := g.pick(fields)
			delim := `"""`
			if g.chance(50) {
				delim = "'''"
			}
			lines = append(lines, "note = "+delim+g.nl+f+" = "+basic(pick(f))+g.nl+delim)
		}
		if g.chance(8) {
			g.tag("lock-comment-field")
			f := g.pick(fields)
			lines = append(lines, "# "+f+" = "+basic(pick(f)))
		}
		if g.chance(6) {
			g.tag("lock-inline-table")
			f := g.pick(fields)
			lines = append(lines, "extra = { "+f+" = "+basic(pick(f))+" }")
		}
		g.r.Shuffle(len(lines)-1, func(i, j int) { lines[i+1], lines[j+1] = lines[j+1], lines[i+1] })
		parts = append(parts, strings.Join(lines, g.nl))
	}
	if g.chance(10) {
		g.tag("lock-package-table-not-array")
		parts = append(parts, "[package]"+g.nl+"name = "+basic("x"))
	}
	return strings.Join(parts, g.nl+g.nl) + g.nl
}

// plainManifest: a manifest made only of the forms the compiler's grammar admits (src/manifest_grammar.ab): the readers and TOML must agree on every value of it.
func (g *gen) plainManifest() string {
	g.nl = "\n"
	if g.chance(20) {
		g.nl = "\r\n"
	}
	simple := []string{"lib", "a b", "x#y", "main.ab", "../up", "a'b", "x=y", "p,q", "name", "src/x.ab", "é€"}
	var lines []string
	if g.chance(30) {
		lines = append(lines, "# a comment with = and \"quotes\"")
	}
	table := ""
	if g.chance(15) {
		table = g.pick([]string{"project", "package"})
		lines = append(lines, "["+table+"]")
	}
	for _, k := range stringKeys {
		if g.chance(60) {
			lines = append(lines, k+" = "+`"`+g.pick(simple)+`"`)
		}
	}
	for _, k := range arrayKeys {
		if g.chance(50) {
			var items []string
			for n := g.r.Intn(4); n >= 0; n-- {
				items = append(items, `"`+g.pick(capabilityNames)+`"`)
			}
			if g.chance(30) {
				lines = append(lines, k+" = [", "  "+strings.Join(items, ","+g.nl+"  ")+", # last", "]")
			} else {
				lines = append(lines, k+" = ["+strings.Join(items, ", ")+"]")
			}
		}
	}
	if table != "" {
		table = ""
	}
	if g.chance(50) {
		lines = append(lines, "", "[dependencies]")
		used := map[string]bool{}
		for n := g.r.Intn(3); n >= 0; n-- {
			name := g.pick([]string{"alpha", "beta", "gamma", "d-e", "foo_bar"})
			if used[name] {
				continue
			}
			used[name] = true
			selector := g.pick([]string{"rev", "tag", "branch"})
			lines = append(lines, name+" = { git = \""+g.pick([]string{"https://example.test/a.git", "ssh://h/p", "../local"})+"\", "+selector+" = \""+g.pick([]string{"0123456789abcdef0123456789abcdef01234567", "v1.2", "main"})+"\" }")
		}
	}
	for _, t := range []string{"exports", "imports"} {
		if g.chance(30) {
			lines = append(lines, "", "["+t+"]")
			used := map[string]bool{}
			for n := g.r.Intn(3); n >= 0; n-- {
				k := g.pick([]string{"util", "text/json", "a.b", "x", "e é", "../../src/i2c/device.ab"})
				if used[k] {
					continue
				}
				used[k] = true
				lines = append(lines, `"`+k+`" = "`+g.pick([]string{"util/entry.ab", "x.ab", "b.ab"})+`"`)
			}
		}
	}
	if g.chance(30) {
		lines = append(lines, "", "[dependencyCompileCapabilities]")
		used := map[string]bool{}
		for n := g.r.Intn(3); n >= 0; n-- {
			name := g.pick([]string{"alpha", "beta", "gamma"})
			if used[name] {
				continue
			}
			used[name] = true
			lines = append(lines, name+" = [\""+g.pick(capabilityNames)+"\", \""+g.pick(capabilityNames)+"\"]")
		}
	}
	return strings.Join(lines, g.nl) + g.nl
}

func (g *gen) plainLock() string {
	g.nl = "\n"
	fields := []string{"name", "provider", "identity", "source", "selector-kind", "selector", "revision", "digest", "entry"}
	lines := []string{"version = 2"}
	for n := 1 + g.r.Intn(3); n > 0; n-- {
		lines = append(lines, "", "[[package]]")
		for _, f := range fields {
			lines = append(lines, f+` = "`+g.pick(lockPools[f])+`"`)
		}
	}
	return strings.Join(lines, g.nl) + g.nl
}
