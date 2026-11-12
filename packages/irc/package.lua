-- irc: a full-screen IRC client, at the shell prompt.
return {
  name = "irc",
  version = "1.1.0",
  description = "IRC client: several servers, channels and queries in windows, nick list, TLS checked against the root CAs (TERMINA 8.13), SASL (needs TERMINA 4.0)",
  author = "bjorand",
  license = "MIT",
  bin = { "irc" },   -- "irc [host[:port] [#channel...]]" at the prompt
}
