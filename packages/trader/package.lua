-- trader: paper trading on real US stocks, for the text screen.
return {
  name = "trader",
  version = "2.0.0",
  description = "Paper trading on real US stocks with Yahoo Finance prices (sends ticker symbols): shorts, 2x leverage, vs the S&P 500",
  author = "bjorand",
  license = "MIT",
  bin = { "trader" },   -- "trader" at the prompt
}
