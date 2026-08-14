# syntax=docker/dockerfile:1

FROM rust:1.88.0 AS builder

ARG FLUTTER_VERSION=3.44.9
ENV FLUTTER_VERSION=${FLUTTER_VERSION}
ENV PATH="/root/.local/flutter/bin:${PATH}"
ENV PUB_HOSTED_URL="https://pub.dev"
ENV PUB_CACHE="/root/.pub-cache"

WORKDIR /app

# Install Flutter once and reuse for the build.
RUN git config --global advice.detachedHead false && \
    mkdir -p /root/.local && \
    git clone -b "$FLUTTER_VERSION" --depth 1 https://github.com/flutter/flutter.git /root/.local/flutter && \
    flutter config --no-analytics

# Build the Flutter web frontend.
COPY flutter/ ./flutter/
COPY scripts/build-flutter.sh ./scripts/build-flutter.sh
RUN ./scripts/build-flutter.sh

# Build the Rust backend, which embeds the frontend assets via include_dir!.
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY migrations ./migrations
COPY tests ./tests
RUN cargo build --release --bin devinorium

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates libssl3 && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd -r devinorium && \
    useradd -r -g devinorium -d /data -s /sbin/nologin devinorium

RUN mkdir -p /data && chown -R devinorium:devinorium /data

COPY --from=builder --chown=devinorium:devinorium /app/target/release/devinorium /usr/local/bin/devinorium

USER devinorium
WORKDIR /data

ENV DEVINORIUM_HOST=0.0.0.0
ENV DEVINORIUM_PORT=7878
ENV DEVINORIUM_DB_URL=sqlite:/data/devinorium.db?mode=rwc

EXPOSE 7878
VOLUME ["/data"]

ENTRYPOINT ["/usr/local/bin/devinorium"]
