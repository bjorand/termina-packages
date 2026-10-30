// mkindex validates the packages in packages/ and generates the site published
// on GitHub Pages, which TERMINA's pkg command reads:
//
//	site/index.lua                  package list (Lua data)
//	site/p/<name>/<version>/<file>  the files of each package
//	site/index.html                 the same list, for humans
//
//	go run ./tools/mkindex [-packages packages] [-out site] [-prev old/index.lua] [-luac luac5.4]
//
// Without -out, it only validates.
package main

import (
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Machine limits: a script over 64 KB does not load, and the A: drive holds
// about 1.9 MB.
const (
	maxFile    = 64 * 1024
	maxPackage = 256 * 1024
)

var (
	reName    = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,23}$`)
	reVersion = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)
	reFile    = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,30}$`)
)

type File struct {
	Path string
	Size int64
	SHA1 string
	data []byte
}

type Package struct {
	Name, Version, Description, Author, License string
	Bin, Depends                                []string
	Files                                       []File
	Apps                                        []App // for the page only: the machine detects them itself
}

// App: a file whose header has "-- @app Name" (TERMINA WIN desktop).
type App struct {
	File, Name, Icon string
}

func main() {
	pkgDir := flag.String("packages", "packages", "packages directory")
	out := flag.String("out", "", "site directory to generate (empty: validate only)")
	prev := flag.String("prev", "", "previously published index.lua (version number checks)")
	luac := flag.String("luac", "", "compiler used to check syntax, e.g. \"luac5.4\" (empty: no check)")
	repo := flag.String("repo", "https://github.com/bjorand/termina-packages", "GitHub repository (links to the source)")
	flag.Parse()

	pkgs, err := loadAll(*pkgDir, *luac)
	if err == nil && *prev != "" {
		err = checkVersions(pkgs, *prev)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if *out != "" {
		if err := writeSite(*out, pkgs, *repo, time.Now().UTC().Format("2006-01-02")); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	fmt.Printf("%d valid package(s)\n", len(pkgs))
}

// loadAll reads and validates every package; all errors are returned at once
// so that a contributor sees them in a single CI run.
func loadAll(dir, luac string) ([]*Package, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var pkgs []*Package
	var errs []error
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		p, err := loadPackage(filepath.Join(dir, e.Name()), luac)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		pkgs = append(pkgs, p)
	}
	byName := map[string]*Package{}
	for _, p := range pkgs {
		byName[p.Name] = p
	}
	for _, p := range pkgs {
		for _, d := range p.Depends {
			if byName[d] == nil {
				errs = append(errs, fmt.Errorf("%s: depends on \"%s\", which does not exist", p.Name, d))
			}
		}
	}
	if err := checkCycles(pkgs, byName); err != nil {
		errs = append(errs, err)
	}
	sort.Slice(pkgs, func(i, j int) bool { return pkgs[i].Name < pkgs[j].Name })
	return pkgs, errors.Join(errs...)
}

func loadPackage(dir, luac string) (*Package, error) {
	base := filepath.Base(dir)
	fail := func(format string, args ...any) error {
		return fmt.Errorf("%s: %s", base, fmt.Sprintf(format, args...))
	}
	src, err := os.ReadFile(filepath.Join(dir, "package.lua"))
	if err != nil {
		return nil, fail("package.lua missing")
	}
	t, err := parseLuaData(base+"/package.lua", string(src))
	if err != nil {
		return nil, err
	}
	p := &Package{}
	strs := map[string]*string{
		"name": &p.Name, "version": &p.Version, "description": &p.Description,
		"author": &p.Author, "license": &p.License,
	}
	lists := map[string]*[]string{"bin": &p.Bin, "depends": &p.Depends}
	if len(t.Array) > 0 {
		return nil, fail("package.lua: only \"key = value\" fields")
	}
	for k, v := range t.Hash {
		if s, ok := strs[k]; ok {
			if *s, ok = v.(string); !ok {
				return nil, fail("\"%s\" must be a string", k)
			}
		} else if l, ok := lists[k]; ok {
			lt, ok := v.(*luaTable)
			if !ok || len(lt.Hash) > 0 {
				return nil, fail("\"%s\" must be a list of strings", k)
			}
			for _, x := range lt.Array {
				s, ok := x.(string)
				if !ok {
					return nil, fail("\"%s\" must be a list of strings", k)
				}
				*l = append(*l, s)
			}
		} else {
			return nil, fail("unknown field \"%s\" (name, version, description, author, license, bin, depends)", k)
		}
	}
	switch {
	case p.Name != base:
		return nil, fail("name = %q, but the folder is named %q", p.Name, base)
	case !reName.MatchString(p.Name):
		return nil, fail("invalid name (lowercase letters, digits, - and _, 24 characters at most)")
	case !reVersion.MatchString(p.Version):
		return nil, fail("version %q: X.Y.Z expected", p.Version)
	case strings.TrimSpace(p.Description) == "":
		return nil, fail("description missing")
	case len(p.Description) > 120:
		return nil, fail("description too long (120 characters at most)")
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var total int64
	var errs []error
	for _, e := range entries {
		name := e.Name()
		if name == "package.lua" {
			continue
		}
		if e.IsDir() {
			errs = append(errs, fail("%s: subfolders are not supported", name))
			continue
		}
		if !reFile.MatchString(name) {
			errs = append(errs, fail("%s: invalid file name", name))
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return nil, err
		}
		if len(data) > maxFile {
			errs = append(errs, fail("%s: %d bytes, 64 KB at most", name, len(data)))
		}
		if strings.HasSuffix(name, ".lua") && luac != "" {
			if err := syntax(luac, filepath.Join(dir, name)); err != nil {
				errs = append(errs, fail("%s: %v", name, err))
			}
		}
		if app, ok := appHeader(name, data); ok {
			p.Apps = append(p.Apps, app)
		}
		sum := sha1.Sum(data)
		p.Files = append(p.Files, File{Path: name, Size: int64(len(data)), SHA1: hex.EncodeToString(sum[:]), data: data})
		total += int64(len(data))
	}
	if len(p.Files) == 0 {
		errs = append(errs, fail("no files"))
	}
	if total > maxPackage {
		errs = append(errs, fail("%d bytes in total, 256 KB at most", total))
	}
	for _, b := range p.Bin {
		if !reName.MatchString(b) {
			errs = append(errs, fail("invalid command %q", b))
		} else if !p.hasFile(b + ".lua") {
			errs = append(errs, fail("command %q: %s.lua missing", b, b))
		}
	}
	for _, d := range p.Depends {
		if d == p.Name {
			errs = append(errs, fail("depends on itself"))
		}
	}
	if err := errors.Join(errs...); err != nil {
		return nil, err
	}
	return p, nil
}

// appHeader reads the header like wm::scanApps does: "-- @app" in the first 255 bytes.
func appHeader(file string, data []byte) (App, bool) {
	if !strings.HasSuffix(file, ".lua") {
		return App{}, false
	}
	head := string(data[:min(len(data), 255)])
	field := func(tag string) string {
		i := strings.Index(head, tag)
		if i < 0 {
			return ""
		}
		v, _, _ := strings.Cut(head[i+len(tag):], "\n")
		return strings.TrimSpace(v)
	}
	name := field("-- @app ")
	if name == "" {
		return App{}, false
	}
	icon := field("-- @icon ")
	if icon == "" {
		icon = "lua"
	}
	return App{File: file, Name: name, Icon: icon}, true
}

func (p *Package) hasFile(name string) bool {
	for _, f := range p.Files {
		if f.Path == name {
			return true
		}
	}
	return false
}

func syntax(luac, file string) error {
	args := strings.Fields(luac)
	cmd := exec.Command(args[0], append(args[1:], "-p", file)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("syntax error: %s", msg)
	}
	return nil
}

func checkCycles(pkgs []*Package, byName map[string]*Package) error {
	state := map[string]int{} // 1: visiting, 2: done
	var visit func(p *Package, path []string) error
	visit = func(p *Package, path []string) error {
		switch state[p.Name] {
		case 1:
			return fmt.Errorf("circular dependencies: %s", strings.Join(append(path, p.Name), " -> "))
		case 2:
			return nil
		}
		state[p.Name] = 1
		for _, d := range p.Depends {
			if q := byName[d]; q != nil {
				if err := visit(q, append(path, p.Name)); err != nil {
					return err
				}
			}
		}
		state[p.Name] = 2
		return nil
	}
	for _, p := range pkgs {
		if err := visit(p, nil); err != nil {
			return err
		}
	}
	return nil
}

// checkVersions rejects a package whose content changed since the published
// index without a version bump (machines would not update it), or whose
// version went backwards.
func checkVersions(pkgs []*Package, prevFile string) error {
	src, err := os.ReadFile(prevFile)
	if err != nil {
		return err
	}
	idx, err := parseLuaData(filepath.Base(prevFile), string(src))
	if err != nil {
		return err
	}
	prev, _ := idx.Hash["packages"].(*luaTable)
	if prev == nil {
		return fmt.Errorf("%s: no packages table", prevFile)
	}
	var errs []error
	for _, p := range pkgs {
		old, _ := prev.Hash[p.Name].(*luaTable)
		if old == nil {
			continue
		}
		oldVersion, _ := old.Hash["version"].(string)
		switch c := compareVersions(p.Version, oldVersion); {
		case c < 0:
			errs = append(errs, fmt.Errorf("%s: version %s is older than the published version %s", p.Name, p.Version, oldVersion))
		case c == 0 && fingerprint(p.Files) != oldFingerprint(old):
			errs = append(errs, fmt.Errorf("%s: files changed, bump the version (published: %s)", p.Name, oldVersion))
		}
	}
	return errors.Join(errs...)
}

func compareVersions(a, b string) int {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < 3; i++ {
		var x, y int
		if i < len(pa) {
			fmt.Sscan(pa[i], &x)
		}
		if i < len(pb) {
			fmt.Sscan(pb[i], &y)
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

func fingerprint(files []File) string {
	var parts []string
	for _, f := range files {
		parts = append(parts, f.Path+":"+f.SHA1)
	}
	sort.Strings(parts)
	return strings.Join(parts, ",")
}

func oldFingerprint(old *luaTable) string {
	var files []File
	if ft, ok := old.Hash["files"].(*luaTable); ok {
		for _, x := range ft.Array {
			if f, ok := x.(*luaTable); ok {
				path, _ := f.Hash["path"].(string)
				sum, _ := f.Hash["sha1"].(string)
				files = append(files, File{Path: path, SHA1: sum})
			}
		}
	}
	return fingerprint(files)
}

// ------------------------------------------------------------------ site

func writeSite(out string, pkgs []*Package, repo, date string) error {
	if err := os.RemoveAll(out); err != nil {
		return err
	}
	for _, p := range pkgs {
		dir := filepath.Join(out, "p", p.Name, p.Version)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		for _, f := range p.Files {
			if err := os.WriteFile(filepath.Join(dir, f.Path), f.data, 0o644); err != nil {
				return err
			}
		}
	}
	if err := os.WriteFile(filepath.Join(out, "index.lua"), []byte(indexLua(pkgs)), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(out, ".nojekyll"), nil, 0o644); err != nil {
		return err
	}
	page, err := indexHTML(pkgs, repo, date)
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(out, "index.html"), []byte(page), 0o644)
}

func luaList(xs []string) string {
	q := make([]string, len(xs))
	for i, x := range xs {
		q[i] = luaString(x)
	}
	return "{" + strings.Join(q, ", ") + "}"
}

// indexLua produces the index read by pkg (format 1). It is deterministic: the
// same repository always gives the same file.
func indexLua(pkgs []*Package) string {
	var b strings.Builder
	b.WriteString("-- TERMINA package index, generated by tools/mkindex: do not edit.\n")
	b.WriteString("return {\n  format = 1,\n  packages = {\n")
	for _, p := range pkgs {
		fmt.Fprintf(&b, "    [%s] = {\n", luaString(p.Name))
		fmt.Fprintf(&b, "      version = %s,\n", luaString(p.Version))
		fmt.Fprintf(&b, "      description = %s,\n", luaString(p.Description))
		if p.Author != "" {
			fmt.Fprintf(&b, "      author = %s,\n", luaString(p.Author))
		}
		if p.License != "" {
			fmt.Fprintf(&b, "      license = %s,\n", luaString(p.License))
		}
		fmt.Fprintf(&b, "      bin = %s,\n", luaList(p.Bin))
		fmt.Fprintf(&b, "      depends = %s,\n", luaList(p.Depends))
		b.WriteString("      files = {\n")
		for _, f := range p.Files {
			fmt.Fprintf(&b, "        {path = %s, size = %d, sha1 = %s},\n", luaString(f.Path), f.Size, luaString(f.SHA1))
		}
		b.WriteString("      },\n    },\n")
	}
	b.WriteString("  },\n}\n")
	return b.String()
}
