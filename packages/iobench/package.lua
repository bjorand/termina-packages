-- Storage benchmark: how fast the flash (/) and the SD card (/mnt/sd) are.
return {
  name = "iobench",
  version = "2.0.0",
  description = "Storage benchmark: read/write speed of the flash and the SD card",
  author = "bjorand",
  license = "MIT",
  bin = { "iobench" },   -- "iobench [-s KB] [dir...]" at the prompt
}
