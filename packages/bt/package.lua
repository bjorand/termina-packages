-- bt: the Bluetooth manager, full screen at the prompt.
return {
  name = "bt",
  version = "1.0.0",
  description = "Bluetooth keyboards and mice: turn on, pair, forget, keymap (TERMINA 8.16.0)",
  author = "bjorand",
  license = "MIT",
  bin = { "bt" },   -- "bt" at the prompt; also "bt status|on|off|scan", "bt pair|forget <addr>"
}
