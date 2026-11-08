# CLAUDE.md

A **Docker image repo**, not an application: `runonflux/dragonwilds-server-flux`, a layer on the
community Dragonwilds image (pinned by digest) with a supervising PID 1.

The rule that shapes everything: the hub (`~/work/games-website/src/games/dragonwilds`) reads this
image's layout, so mount, log path, process name, world file, env names and the healthcheck must
not drift. A new env var counts against FluxOS's limit of 20 per app.

- `scripts/flux-lib.sh`: pure decisions, sourced by the tests. Keep it side effect free.
- `scripts/flux-entrypoint.sh`: PID 1.
- `tests/test-flux.sh`: unit tests. `tests/test-image.sh`: live boot tests.

Never publish or tag from here without the user's say. Publishing is by hand (the image CI has no
secrets in this family of repos).
