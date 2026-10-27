package main

import (
	_ "embed"
	"fmt"
	"html/template"
	"sort"
	"strings"
)

// La Logithèque : index.html du site, dans le style du site de TERMINA.
// Rendue côté serveur (lisible sans JavaScript) ; le script ajoute la
// recherche, les fiches (#p/nom) et un terminal qui imite pkg.

//go:embed catalogue.html
var catalogueSrc string

var catalogue = template.Must(template.New("catalogue").Funcs(template.FuncMap{
	"mod": func(a, b int) int { return a % b },
}).Parse(catalogueSrc))

type pageFile struct {
	Path, SizeLabel, SHA1, Short, Source string
}

type pagePkg struct {
	*Package
	Kinds      []string
	KindAttr   string
	Initials   string
	SizeLabel  string
	SearchText string
	Source     string
	UsedBy     []string
	Files      []pageFile
}

// jsPkg : ce que le terminal de la page sait d'un package.
type jsPkg struct {
	Version     string   `json:"version"`
	Description string   `json:"description"`
	Author      string   `json:"author,omitempty"`
	License     string   `json:"license,omitempty"`
	Bin         []string `json:"bin"`
	Depends     []string `json:"depends"`
	Size        int64    `json:"size"`
	Files       int      `json:"files"`
	Names       []string `json:"names"`
}

type pageData struct {
	Date, Repo, Example   string
	Count, Commands, Apps int
	Packages              []pagePkg
	JSON                  map[string]jsPkg
}

// sizeLabel : « 309 o », « 12,4 Ko ».
func sizeLabel(n int64) string {
	if n < 1024 {
		return fmt.Sprintf("%d o", n)
	}
	return strings.Replace(fmt.Sprintf("%.1f Ko", float64(n)/1024), ".", ",", 1)
}

func initials(name string) string {
	parts := strings.FieldsFunc(name, func(r rune) bool { return r == '-' || r == '_' })
	if len(parts) >= 2 {
		return parts[0][:1] + parts[1][:1]
	}
	if len(name) >= 2 {
		return name[:2]
	}
	return name
}

func indexHTML(pkgs []*Package, repo, date string) (string, error) {
	data := pageData{Date: date, Repo: repo, Count: len(pkgs), JSON: map[string]jsPkg{}}
	usedBy := map[string][]string{}
	for _, p := range pkgs {
		for _, d := range p.Depends {
			usedBy[d] = append(usedBy[d], p.Name)
		}
	}
	for _, p := range pkgs {
		pp := pagePkg{
			Package:  p,
			Initials: initials(p.Name),
			Source:   fmt.Sprintf("%s/tree/main/packages/%s", repo, p.Name),
			UsedBy:   usedBy[p.Name],
		}
		sort.Strings(pp.UsedBy)
		if len(p.Bin) > 0 {
			pp.Kinds = append(pp.Kinds, "commande")
			data.Commands += len(p.Bin)
		}
		if len(p.Apps) > 0 {
			pp.Kinds = append(pp.Kinds, "app")
			data.Apps += len(p.Apps)
		}
		if len(pp.Kinds) == 0 {
			pp.Kinds = append(pp.Kinds, "module")
		}
		pp.KindAttr = strings.Join(pp.Kinds, " ")
		var total int64
		var names []string
		for _, f := range p.Files {
			total += f.Size
			names = append(names, f.Path)
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
		data.JSON[p.Name] = jsPkg{
			Version: p.Version, Description: p.Description, Author: p.Author, License: p.License,
			Bin: nonNil(p.Bin), Depends: nonNil(p.Depends), Size: total, Files: len(p.Files), Names: names,
		}
	}
	data.Example = "salut"
	if _, ok := data.JSON["salut"]; !ok && len(pkgs) > 0 {
		data.Example = pkgs[0].Name
	}
	var b strings.Builder
	if err := catalogue.Execute(&b, data); err != nil {
		return "", err
	}
	return b.String(), nil
}

func nonNil(xs []string) []string {
	if xs == nil {
		return []string{}
	}
	return xs
}
