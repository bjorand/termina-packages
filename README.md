# termina-packages

Package registry for [TERMINA](https://github.com/bjorand/termina). On the machine, the `pkg` command installs them:

```
pkg update            fetch the package list
pkg list              available packages (-i: installed)
pkg search <word>     search
pkg info <name>       details
pkg install <name>    install, with its dependencies
pkg upgrade [name]    upgrade (everything by default)
pkg remove <name>     uninstall
```

A package can hold any kind of file: Lua programs and modules, shell scripts, PICO-8 carts, data.

## How it works

1. Each package is a folder `packages/<name>/` with a `package.lua` manifest and its files.
2. On every pull request, CI (`.github/workflows/publish.yml`) runs `tools/mkindex`, which validates all the packages. It checks:
   - the manifest;
   - file sizes;
   - Lua 5.4 syntax of the `.lua` files;
   - dependencies;
   - that every change comes with a new version.
3. On `main`, CI publishes the registry to GitHub Pages (`https://bjorand.github.io/termina-packages/`):
   - `index.lua`: the list, with the size and SHA-1 sum of every file;
   - `p/<name>/<version>/<file>`: the files themselves;
   - `index.html`: the catalog page.
4. On the machine, `pkg update` downloads `index.lua`. `pkg install` then downloads the files one by one, checks their SHA-1 and installs the package into `A:\pkg\<name>\`. If anything fails, the version already installed stays in place.

To use another registry (a fork, or a local test server): `pkg url http://192.168.1.10:8000/`.

## Development

```
go test ./...
go run ./tools/mkindex                          # validate only
go run ./tools/mkindex -luac luac5.4 -out site  # generate the site into site/
```

To test on the machine or in the emulator, serve `site/` (for example `python -m http.server 8000 -d site`), then run `pkg url http://<ip>:8000/` and `pkg update`.

To contribute a package, see [CONTRIBUTING.md](CONTRIBUTING.md).
