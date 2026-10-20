## Before opening a pull request

Read [CONTRIBUTING.md](../CONTRIBUTING.md). In particular the **hard
boundaries** section — site-specific parsers, signature reverse engineering,
paid-content helpers, and bundled third-party binaries will be rejected.

## Checklist

- [ ] `python3 -m py_compile server.py` passes
- [ ] frontend `<script>` block passes `node --check`
- [ ] `python3 selftest.py` passes
- [ ] `node sync_install.mjs` was run and `install.sh` is committed
- [ ] every new user-visible string exists in **both** `zh` and `en`
- [ ] switching language leaves no untranslated text (placeholders included)
- [ ] no cookies, tokens, private links, or local absolute paths in the diff
- [ ] no site-specific identifiers introduced in the source

## What

<!-- What does this change? -->

## Why

<!-- Why is it needed? Link an issue if there is one -->
