# Contributing a package

1. Fork the repository and copy `packages/salut/` to `packages/<your-name>/`.
2. Write the `package.lua` manifest, then add your files.
3. Run `go run ./tools/mkindex` to check, then open a pull request. CI runs the same checks. Once the PR is merged, the package is available to everyone after a `pkg update`.

## The manifest

```lua
return {
  name = "snake2",                 -- = folder name; lowercase letters, digits, - and _ (24 max)
  version = "1.0.0",               -- X.Y.Z
  description = "Snake in color",  -- one line, 120 characters max
  author = "Ada Lovelace",         -- optional
  license = "MIT",                 -- optional
  bin = { "snake2" },              -- optional: commands for the A> prompt
  depends = { "tui" },             -- optional: other packages from the registry
}
```

The manifest holds data only: strings, numbers and lists. Functions, calls and variables are rejected.

## Rules

- **Files:** any kind of file (Lua, shell scripts, PICO-8 carts, data...), flat in the folder, without subfolders. They are installed as-is in `A:\pkg\<name>\`. Each file is **64 KB at most**, the limit for a script on the machine. A package is 256 KB at most in total, because the `A:` drive holds about 1.9 MB.
- **Lua:** `.lua` files are Lua 5.4 with 32-bit numbers, and CI checks their syntax. There is no `io` or `os`, and memory is limited to 96 KB per script. The API (`term`, `key`, `fs`, `net`, `win`...) is described in the TERMINA README.
- **Commands:** each name in `bin` needs its own `<name>.lua` file. Once installed, typing `<name>` at the prompt runs it. A `<name>.lua` file at the root of `A:` takes precedence, so pick names that are unlikely to collide (avoid `hello` or `snake`, for example).
- **Modules:** a `util.lua` file in your package loads with `require "<package>.util"`, which looks for it in `A:\pkg\<package>\util.lua`. Another package that lists yours in its `depends` can do the same.
- **Desktop apps:** a file whose header contains `-- @app Name` (and optionally `-- @icon name`) shows up on the `win` desktop, like the apps at the root of `A:`.
- **Versions:** any change to a published package must bump its version, or CI rejects the PR. Machines only update a package when its version goes up.

## Security

A package runs with the same rights as any Lua program on the machine. In particular, it can read and write all of `A:` and use the network. PRs are reviewed before they are merged: keep the code readable (no minified or obfuscated code), and don't send data to a server without saying so in the description.

On the machine, every downloaded file is checked against its SHA-1 sum from the index. The index itself goes over HTTPS, but the machine does not verify TLS certificates.
