# Crypto Watchdesk

Hourly momentum screen of the 75 most-traded crypto perpetual swaps, plus a check on whether funding carry beats cash.

- `build.pl` fetches public exchange data (OKX, Hyperliquid, Kraken, Deribit, CoinGecko, Yahoo Finance) with perl + curl and writes `dist/index.html` and `dist/data.json`.
- `template.html` is the page; data is inlined at build time. Alert thresholds are adjustable in the page and saved in the browser.
- `data/carry_seed.json` holds funding history from a run that could reach every venue. It is only a fallback: all four funding venues (OKX, Hyperliquid, Kraken, Deribit) are fetched on every run. Binance and Bybit refuse US-hosted runners, so they are not used.
- `.github/workflows/refresh.yml` rebuilds and deploys to GitHub Pages every hour (Pages source must be set to GitHub Actions).

Local run: `perl build.pl` (about 3 minutes), then open `dist/index.html`.

Public data only. Figures can be wrong or stale. Not investment advice.
