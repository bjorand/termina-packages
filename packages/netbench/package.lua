-- Network benchmark: latency and HTTPS throughput over Wi-Fi.
return {
  name = "netbench",
  version = "1.0.0",
  description = "Network benchmark: TCP and HTTPS latency, download and upload speed (speed.cloudflare.com)",
  author = "bjorand",
  license = "MIT",
  bin = { "netbench" },   -- "netbench [-d KB] [-u KB] [-url <url>]" at the prompt
}
