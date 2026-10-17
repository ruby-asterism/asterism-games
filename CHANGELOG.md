# Changelog

Versions before 0.11.1 are noted in the README where each feature is
described ("games 0.10.0" and the like).

## 0.11.1

- Jev (the `jev` AI player) is asked through TypeSafe's own API
  (`POST https://api.typesafe.ai/v1/systemone`) instead of Cloudflare
  Workers AI. Its key is `TYPESAFE_API_KEY` (console.typesafe.ai, Keys);
  `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN` are no longer read.
  Move the key in `.env` when updating, or Jev is not offered.
- `ASTERISM_GAMES_JEV_MODEL` defaults to `jev-latest` (was `typesafe/jev`,
  a Workers AI name). A versioned id such as `jev-1.13.0` keeps one model.
- The tokens counted are the answer's `usage` (`input_tokens`,
  `output_tokens`); the default price stays $0.042 per million input
  tokens, output free (TypeSafe's published price, checked 2026-10-18).
