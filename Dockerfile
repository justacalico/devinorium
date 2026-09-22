# syntax=docker/dockerfile:1

# Devinorium all-in-one image: Flutter web bundle -> Rust binary -> slim
# runtime. The frontend is built in a dedicated stage because the backend
# embeds frontend/dist/ at compile time via include_dir!.

# No reliable versioned Flutter image exists, so install the same pinned
# release the CI workflow builds with.
FROM debian:bookworm-slim AS frontend
ARG FLUTTER_VERSION=3.44.9
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        unzip \
        xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 --branch "$FLUTTER_VERSION" \
        https://github.com/flutter/flutter.git /opt/flutter
ENV PATH="/opt/flutter/bin:$PATH"
RUN flutter precache --web
WORKDIR /app
COPY flutter/pubspec.yaml flutter/pubspec.* flutter/
RUN cd flutter && flutter pub get
COPY flutter/ flutter/
COPY scripts/build-flutter.sh scripts/build-flutter.sh
RUN bash scripts/build-flutter.sh

FROM rust:1.88-slim-bookworm AS backend
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
COPY migrations/ migrations/
COPY --from=frontend /app/frontend/dist/ frontend/dist/
RUN cargo build --release

FROM debian:bookworm-slim
# git: repository clone/worktree operations. openssh-client: SSH remotes.
# ca-certificates: HTTPS remotes and registry checks from git/curl calls.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --shell /usr/sbin/nologin devinorium
COPY --from=backend /app/target/release/devinorium /usr/local/bin/devinorium
USER devinorium
WORKDIR /home/devinorium
ENV DEVINORIUM_HOST=0.0.0.0 \
    DEVINORIUM_PORT=7878
EXPOSE 7878
VOLUME ["/home/devinorium/data"]
ENTRYPOINT ["devinorium"]
