# The Porthole sidecar: joins your cluster as a hidden node and serves MCP
# over HTTP. Build from the repository root (the sidecar depends on the
# library in ..):
#
#   docker build -f sidecar/Dockerfile -t porthole-sidecar .
#
# Match ELIXIR_VERSION/OTP_VERSION to your cluster's major OTP version. The
# three must form an existing hexpm/elixir tag (they carry a Debian build
# date): see https://hub.docker.com/r/hexpm/elixir/tags

ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.3.3
ARG DEBIAN_VERSION=bookworm-20260610-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS build

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates \
  && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /src
# Only what the release needs: never the repository's config/ (it may hold
# local development tokens).
COPY mix.exs mix.lock ./
COPY lib lib
COPY sidecar/mix.exs sidecar/mix.lock sidecar/
COPY sidecar/lib sidecar/lib
COPY sidecar/rel sidecar/rel

WORKDIR /src/sidecar
RUN mix deps.get --only prod && mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

RUN useradd --system --uid 1000 porthole
WORKDIR /app
COPY --from=build --chown=porthole /src/sidecar/_build/prod/rel/porthole_sidecar ./
USER porthole

# Long names, as clusters usually use (-name app@10.0.1.12). Set RELEASE_NODE
# (e.g. porthole@$POD_IP), RELEASE_COOKIE and the PORTHOLE_* variables.
ENV RELEASE_DISTRIBUTION=name PORTHOLE_PORT=4040
EXPOSE 4040

CMD ["/app/bin/porthole_sidecar", "start"]
