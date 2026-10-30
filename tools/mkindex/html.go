package main

import (
	_ "embed"
	"fmt"
	"html/template"
	"sort"
	"strings"
)

// The catalog: the site's index.html, in the style of the TERMINA site.
// Rendered server-side (readable without JavaScript); the script adds the
// search, the filters and the package sheets (#p/name).

//go:embed catalogue.html
var catalogueSrc string

var catalogue = template.Must(template.New("catalogue").Parse(catalogueSrc))

type pageFile struct {
	Path, SizeLabel, SHA1, Short, Source string
}

type pagePkg struct {
	*Package
	Kinds      []string
	KindAttr   string
	SizeLabel  string
	SearchText string
	Source     string
	UsedBy     []string
	Files      []pageFile
}

type pageData struct {
	Date, Repo, Example   string
	Count, Commands, Apps int
	Packages              []pagePkg
}

// sizeLabel: "309 B", "12.4 KB".
func sizeLabel(n int64) string {
	if n < 1024 {
		return fmt.Sprintf("%d B", n)
	}
	return fmt.Sprintf("%.1f KB", float64(n)/1024)
}

func indexHTML(pkgs []*Package, repo, date string) (string, error) {
	data := pageData{Date: date, Repo: repo, Count: len(pkgs)}
	usedBy := map[string][]string{}
	for _, p := range pkgs {
		for _, d := range p.Depends {
			usedBy[d] = append(usedBy[d], p.Name)
		}
	}
	for _, p := range pkgs {
		pp := pagePkg{
			Package: p,
			Source:  fmt.Sprintf("%s/tree/main/packages/%s", repo, p.Name),
			UsedBy:  usedBy[p.Name],
		}
		sort.Strings(pp.UsedBy)
		if len(p.Bin) > 0 {
			pp.Kinds = append(pp.Kinds, "command")
			data.Commands += len(p.Bin)
		}
		if len(p.Apps) > 0 {
			pp.Kinds = append(pp.Kinds, "app")
			data.Apps += len(p.Apps)
		}
		if len(pp.Kinds) == 0 {
			// No command and no app: a Lua library, or plain files.
			kind := "files"
			for _, f := range p.Files {
				if strings.HasSuffix(f.Path, ".lua") {
					kind = "module"
				}
			}
			pp.Kinds = append(pp.Kinds, kind)
		}
		pp.KindAttr = strings.Join(pp.Kinds, " ")
		var total int64
		for _, f := range p.Files {
			total += f.Size
			pp.Files = append(pp.Files, pageFile{
				Path: f.Path, SizeLabel: sizeLabel(f.Size), SHA1: f.SHA1, Short: f.SHA1[:10],
				Source: fmt.Sprintf("%s/blob/main/packages/%s/%s", repo, p.Name, f.Path),
			})
		}
		pp.SizeLabel = sizeLabel(total)
		var apps []string
		for _, a := range p.Apps {
			apps = append(apps, a.Name)
		}
		pp.SearchText = strings.Join(append([]string{p.Name, p.Description, p.Author, strings.Join(p.Bin, " "), strings.Join(apps, " ")}, pp.Kinds...), " ")
		data.Packages = append(data.Packages, pp)
		if p.Name == "salut" || data.Example == "" {
			data.Example = p.Name
		}
	}
	var b strings.Builder
	if err := catalogue.Execute(&b, data); err != nil {
		return "", err
	}
	return b.String(), nil
}
