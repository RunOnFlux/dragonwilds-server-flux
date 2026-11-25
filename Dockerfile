# RuneScape: Dragonwilds dedicated server for Flux.
#
# A thin layer on the community image the marketplace has always deployed, pinned BY DIGEST: the
# upstream author ships :latest from a moving branch, and a server that restarts in place must not
# change its launcher underneath a customer. Bump the digest on purpose, after reading the diff.
# The digest below is indifferentbroccoli/runescape-dragonwilds-server-docker:latest as of
# 2026-10-08 (the build that fixed quoting, the SIGTERM pid bug and keeps the ServerGuid).
FROM indifferentbroccoli/runescape-dragonwilds-server-docker@sha256:ecacc3168a3bd7d723e957eab09df14757882ed2113cf1bc3c57bc4e1cdf9252

ARG FLUX_IMAGE_VERSION=1.0.2
LABEL org.opencontainers.image.title="dragonwilds-server-flux" \
      org.opencontainers.image.version="${FLUX_IMAGE_VERSION}" \
      org.opencontainers.image.description="RuneScape: Dragonwilds dedicated server for Flux, with in-place restarts, a watchdog and a patch watcher" \
      org.opencontainers.image.vendor="FluxCloud" \
      org.opencontainers.image.url="https://runonflux.com/games" \
      org.opencontainers.image.source="https://github.com/RunOnFlux/dragonwilds-server-flux" \
      org.opencontainers.image.base.name="indifferentbroccoli/runescape-dragonwilds-server-docker" \
      name="runonflux/dragonwilds-server-flux" \
      maintainer="FluxCloud" \
      github="https://github.com/RunOnFlux/dragonwilds-server-flux" \
      dockerhub="https://hub.docker.com/r/runonflux/dragonwilds-server-flux"

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh /home/steam/flux/
RUN chmod 0755 /home/steam/flux/flux-entrypoint.sh && chmod 0644 /home/steam/flux/flux-lib.sh

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION} \
    FLUX_WATCHDOG=true \
    FLUX_RESTART_TIME="" \
    TZ=UTC

# The upstream HEALTHCHECK is inherited unchanged (pgrep of the game binary, 5 min start period).
ENTRYPOINT ["/home/steam/flux/flux-entrypoint.sh"]
