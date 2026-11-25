# Watch branch

This orphan branch stores the scheduled-monitoring configuration consumed by the `watch.yml` workflow on `main`.

- `uup-watch.json` — the monitoring configuration: daily activation window, concurrency limit, and target list. The schema is documented in the repository README on `main`.
- The branch shares no history with `main`. Configuration changes are version-controlled on this branch; the history of `main` is confined to pipeline code and is unaffected by configuration changes.
- The workflow fetches the file at each cycle; changes take effect from the next cycle. The file must remain valid JSON — a parse failure terminates the cycle with an error, and the built-in defaults are applied when the branch or the file is absent.
