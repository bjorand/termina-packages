-- code: a VS Code-like editor for the text screen, at the shell prompt.
return {
  name = "code",
  version = "2.0.1",
  description = "Code editor: file tree, tabs, mouse, terminal, Lua checks, git; also runs on a Mac or Linux (TERMINA 4.2.0)",
  author = "bjorand",
  license = "MIT",
  bin = { "code" },   -- "code [dir|file]" at the prompt
}
