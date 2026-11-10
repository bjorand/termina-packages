-- fortune: a random saying, shown at boot under the message of the day.
return {
  name = "fortune",
  version = "1.0.0",
  description = "A random saying at the prompt and at boot; add your own in /etc/fortunes",
  author = "bjorand",
  license = "MIT",
  bin = { "fortune" },   -- "fortune", or "fortune -f <file>"
}
