# code

A code editor in the spirit of VS Code, for a text screen: a file tree with
the git state of each file, tabs, the mouse everywhere (select, drag, double
and triple click, wheel, scroll bars, context menus), a terminal panel,
problems, search in files, Lua syntax checks, an outline, go to definition,
references and completion, and git (gutter marks, stage, diff, commit, push,
pull). F1 lists every command.

## On Termina

```
pkg install code
code [folder|file]
```

It needs TERMINA 4.2.0 or later.

## On a Mac, Linux or any computer with Lua

The same files run in a terminal (Terminal, iTerm2, Windows Terminal, xterm...)
with Lua 5.4, [luasystem](https://github.com/lunarmodules/luasystem) and
[LuaFileSystem](https://github.com/lunarmodules/luafilesystem):

```
brew install lua luarocks            # Mac; Linux: apt install lua5.4 liblua5.4-dev luarocks
luarocks install luasystem
luarocks install luafilesystem
git clone https://github.com/bjorand/termina-packages
lua termina-packages/packages/code/code.lua [folder|file]
```

On Debian or Ubuntu, `lua` may be an older version: run `lua5.4`, and install
the rocks for it (`luarocks --lua-version 5.4 install ...`).

The screen is drawn with ANSI escape codes, and the keys and the mouse come
from the terminal as xterm sequences. A few things differ from Termina:

- the terminal panel runs a command until it ends, without the keyboard, and
  shows its output as it comes; `!command` runs one full screen;
- git goes through the `git` command;
- copy and paste use the system clipboard (`pbcopy`/`pbpaste` on a Mac,
  `wl-copy` or `xclip` on Linux), and Cmd+V pastes from the terminal;
- most terminals send Ctrl+Shift+letter as Ctrl+letter: use F1 for those
  commands (Ctrl+Shift+P, F, G, M, O);
- the status bar draws its Powerline arrows only with `CODE_POWERLINE=1`
  in the environment, for a font that has them (a Nerd Font, for instance).
