FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS builder

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils build-essential pkg-config libpq-dev \
 && rm -rf /var/lib/apt/lists/*
RUN curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
      -o /tmp/zig.tar.xz https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz \
 && printf '%s  %s\n' 'd45312e61ebcc48032b77bc4cf7fd6915c11fa16e4aad116b66c9468211230ea' /tmp/zig.tar.xz | sha256sum --check --strict \
 && tar -xJf /tmp/zig.tar.xz -C /opt \
 && ln -s /opt/zig-linux-x86_64-0.13.0/zig /usr/local/bin/zig

WORKDIR /build
COPY build.zig ./
COPY src/ ./src/
COPY db/migrations/ ./db/migrations/
COPY assets/password-deny-list.txt ./assets/password-deny-list.txt
RUN zig build -Doptimize=ReleaseSafe --search-prefix /usr --search-prefix /usr/lib/x86_64-linux-gnu --prefix /out

FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libpq5 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 20903 mine-platform \
 && useradd --uid 20903 --gid 20903 --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin mine-platform
WORKDIR /app
COPY --from=builder /out/bin/mine-api /app/mine-api
USER 20903:20903
EXPOSE 8088
ENTRYPOINT ["/app/mine-api"]
