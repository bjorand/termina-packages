package main

import (
	"crypto/sha1"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// mkpkg creates packages/<name>/ with a manifest and files.
func mkpkg(t *testing.T, root, name, manifest string, files map[string]string) {
	t.Helper()
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "package.lua"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	for f, s := range files {
		if err := os.WriteFile(filepath.Join(dir, f), []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

const helloManifest = `-- example
return {
  name = "hello", version = "1.0.0",
  description = "Says hello", author = "Ada", license = "MIT",
  bin = { "hello" },
}`

func TestValidPackageAndIndex(t *testing.T) {
	root := t.TempDir()
	mkpkg(t, root, "hello", helloManifest, map[string]string{"hello.lua": `print("hello")`})
	mkpkg(t, root, "app", `return { name = "app", version = "0.2.10", description = "An \"app\"", depends = {"hello"} }`,
		map[string]string{"app.lua": "-- @app App\n"})
	pkgs, err := loadAll(root, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(pkgs) != 2 || pkgs[0].Name != "app" || pkgs[1].Name != "hello" {
		t.Fatalf("packages: %+v", pkgs)
	}
	out := filepath.Join(t.TempDir(), "site")
	if err := writeSite(out, pkgs, "https://github.com/x/y", "01/01/2026"); err != nil {
		t.Fatal(err)
	}
	src, err := os.ReadFile(filepath.Join(out, "index.lua"))
	if err != nil {
		t.Fatal(err)
	}
	// The index reads back, with the expected SHA-1 sums.
	idx, err := parseLuaData("index.lua", string(src))
	if err != nil {
		t.Fatal(err)
	}
	hello := idx.Hash["packages"].(*luaTable).Hash["hello"].(*luaTable)
	f := hello.Hash["files"].(*luaTable).Array[0].(*luaTable)
	sum := sha1.Sum([]byte(`print("hello")`))
	if f.Hash["sha1"] != hex.EncodeToString(sum[:]) || f.Hash["size"] != int64(14) {
		t.Fatalf("sha1: %v", f.Hash["sha1"])
	}
	if _, err := os.Stat(filepath.Join(out, "p", "hello", "1.0.0", "hello.lua")); err != nil {
		t.Fatal(err)
	}
	app := idx.Hash["packages"].(*luaTable).Hash["app"].(*luaTable)
	if app.Hash["description"] != `An "app"` {
		t.Fatalf("description: %q", app.Hash["description"])
	}
	// The page: app detected from its header, escaped text, links to the source.
	if a := pkgs[0].Apps; len(a) != 1 || a[0].Name != "App" {
		t.Fatalf("apps: %+v", a)
	}
	page, err := os.ReadFile(filepath.Join(out, "index.html"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`id="sheet-hello"`, `An &#34;app&#34;`, "https://github.com/x/y/blob/main/packages/hello/hello.lua", `data-kinds="app"`, `data-kinds="command"`} {
		if !strings.Contains(string(page), want) {
			t.Errorf("index.html without %q", want)
		}
	}
	// Deterministic.
	if again := indexLua(pkgs); again != string(src) {
		t.Fatal("index is not deterministic")
	}
}

func TestInvalidPackages(t *testing.T) {
	cases := []struct {
		name, manifest string
		files          map[string]string
		want           string
	}{
		{"code", `return { name = "code", version = "1.0.0", description = os.exit() }`, map[string]string{"a.lua": ""}, "only data"},
		{"folder", `return { name = "other", version = "1.0.0", description = "x" }`, map[string]string{"a.lua": ""}, "the folder is named"},
		{"ver", `return { name = "ver", version = "1.0", description = "x" }`, map[string]string{"a.lua": ""}, "X.Y.Z"},
		{"field", `return { name = "field", version = "1.0.0", description = "x", depend = {} }`, map[string]string{"a.lua": ""}, "unknown field"},
		{"big", `return { name = "big", version = "1.0.0", description = "x" }`, map[string]string{"a.lua": strings.Repeat("-", maxFile+1)}, "64 KB"},
		{"bin", `return { name = "bin", version = "1.0.0", description = "x", bin = {"game"} }`, map[string]string{"a.lua": ""}, "game.lua missing"},
		{"dep", `return { name = "dep", version = "1.0.0", description = "x", depends = {"absent"} }`, map[string]string{"a.lua": ""}, "does not exist"},
		{"empty", `return { name = "empty", version = "1.0.0", description = "x" }`, nil, "no files"},
		{"Upper", `return { name = "Upper", version = "1.0.0", description = "x" }`, map[string]string{"a.lua": ""}, "invalid name"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			root := t.TempDir()
			mkpkg(t, root, c.name, c.manifest, c.files)
			_, err := loadAll(root, "")
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("error %v, expected %q", err, c.want)
			}
		})
	}
}

func TestCycle(t *testing.T) {
	root := t.TempDir()
	mkpkg(t, root, "a", `return { name = "a", version = "1.0.0", description = "x", depends = {"b"} }`, map[string]string{"a.lua": ""})
	mkpkg(t, root, "b", `return { name = "b", version = "1.0.0", description = "x", depends = {"a"} }`, map[string]string{"b.lua": ""})
	if _, err := loadAll(root, ""); err == nil || !strings.Contains(err.Error(), "circular") {
		t.Fatalf("error %v", err)
	}
}

func TestVersionBump(t *testing.T) {
	root := t.TempDir()
	mkpkg(t, root, "hello", helloManifest, map[string]string{"hello.lua": `print("hello")`})
	pkgs, err := loadAll(root, "")
	if err != nil {
		t.Fatal(err)
	}
	prev := filepath.Join(t.TempDir(), "index.lua")
	if err := os.WriteFile(prev, []byte(indexLua(pkgs)), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := checkVersions(pkgs, prev); err != nil {
		t.Fatalf("same content, same version: %v", err)
	}
	// Content changed, same version: rejected.
	mkpkg(t, root, "hello", helloManifest, map[string]string{"hello.lua": `print("hi")`})
	pkgs, _ = loadAll(root, "")
	if err := checkVersions(pkgs, prev); err == nil || !strings.Contains(err.Error(), "bump the version") {
		t.Fatalf("error %v", err)
	}
	// Version bumped: accepted.
	mkpkg(t, root, "hello", strings.Replace(helloManifest, "1.0.0", "1.0.1", 1), map[string]string{"hello.lua": `print("hi")`})
	pkgs, _ = loadAll(root, "")
	if err := checkVersions(pkgs, prev); err != nil {
		t.Fatal(err)
	}
	// Version going backwards: rejected.
	mkpkg(t, root, "hello", strings.Replace(helloManifest, "1.0.0", "0.9.0", 1), map[string]string{"hello.lua": `print("hi")`})
	pkgs, _ = loadAll(root, "")
	if err := checkVersions(pkgs, prev); err == nil || !strings.Contains(err.Error(), "is older") {
		t.Fatalf("error %v", err)
	}
}

func TestLuaDataComments(t *testing.T) {
	src := `--[==[ header ]==]
return { -- comment
  a = [[
long]], b = 'x\'y', c = { 1, -2, true }, ["d e"] = false;
}`
	tb, err := parseLuaData("t", src)
	if err != nil {
		t.Fatal(err)
	}
	if tb.Hash["a"] != "long" || tb.Hash["b"] != "x'y" || tb.Hash["d e"] != false {
		t.Fatalf("%+v", tb.Hash)
	}
	if c := tb.Hash["c"].(*luaTable).Array; len(c) != 3 || c[1] != int64(-2) {
		t.Fatalf("%+v", c)
	}
}
