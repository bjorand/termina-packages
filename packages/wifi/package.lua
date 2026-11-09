-- wifi: the Wi-Fi network manager, full screen at the prompt.
return {
  name = "wifi",
  version = "1.0.0",
  description = "Wi-Fi network manager: connection, networks around, join one without restarting (TERMINA 6.2.0)",
  author = "bjorand",
  license = "MIT",
  bin = { "wifi" },   -- "wifi" at the prompt (TERMINA 6.2.0 runs it for its wifi command)
}
