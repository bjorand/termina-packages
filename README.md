# termina-packages

Registre de packages Lua pour [TERMINA](https://github.com/bjorand/termina). Sur la machine, la commande `pkg` les installe :

```
pkg update            récupérer la liste des packages
pkg list              packages disponibles (-i : installés)
pkg search <mot>      chercher
pkg info <nom>        détails
pkg install <nom>     installer, avec ses dépendances
pkg upgrade [nom]     mettre à jour (tout par défaut)
pkg remove <nom>      désinstaller
```

## Fonctionnement

1. Chaque package est un dossier `packages/<nom>/` avec un manifeste `package.lua` et ses fichiers.
2. À chaque pull request, la CI (`.github/workflows/publish.yml`) lance `tools/mkindex`, qui valide tous les packages. Elle vérifie :
   - le manifeste ;
   - la taille des fichiers ;
   - la syntaxe Lua 5.4 ;
   - les dépendances ;
   - qu'une nouvelle version accompagne chaque modification.
3. Sur `main`, la CI publie le registre sur GitHub Pages (`https://bjorand.github.io/termina-packages/`) :
   - `index.lua` : la liste, avec la taille et la somme SHA-1 de chaque fichier ;
   - `p/<nom>/<version>/<fichier>` : les fichiers eux-mêmes.
4. Sur la machine, `pkg update` télécharge `index.lua`. `pkg install` télécharge ensuite les fichiers un par un et vérifie leur SHA-1, puis installe le package dans `A:\pkg\<nom>\`. En cas d'échec, la version déjà installée reste en place.

Pour utiliser un autre registre (un fork, ou un serveur local de test) : `pkg url http://192.168.1.10:8000/`.

## Développer

```
go test ./...
go run ./tools/mkindex                          # valider seulement
go run ./tools/mkindex -luac luac5.4 -out site  # générer le site dans site/
```

Pour tester sur la machine ou dans l'émulateur, servez `site/` (par exemple `python -m http.server 8000 -d site`), puis faites `pkg url http://<ip>:8000/` et `pkg update`.

Pour contribuer un package, voir [CONTRIBUTING.md](CONTRIBUTING.md).
