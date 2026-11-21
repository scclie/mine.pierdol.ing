FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS builder

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils build-essential pkg-config libpq-dev libcurl4-openssl-dev \
 && rm -rf /var/lib/apt/lists/*
RUN curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
      -o /tmp/zig.tar.xz https://mirror.pierdol.ing/zig/0.13.0/zig-x86_64-linux-0.13.0.tar.xz \
 && printf '%s  %s\n' 'd45312e61ebcc48032b77bc4cf7fd6915c11fa16e4aad116b66c9468211230ea' /tmp/zig.tar.xz | sha256sum --check --strict \
 && tar -xJf /tmp/zig.tar.xz -C /opt \
 && ln -s /opt/zig-linux-x86_64-0.13.0/zig /usr/local/bin/zig

RUN set -eu; \
    curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
      -o /tmp/c-ares.tar.gz https://github.com/c-ares/c-ares/releases/download/v1.34.9/c-ares-1.34.9.tar.gz; \
    curl --fail --show-error --location --proto '=https' --proto-redir '=https' \
      -o /tmp/curl.tar.xz https://curl.se/download/curl-8.23.0.tar.xz; \
    printf '%s  %s\n' \
      '9364b70a12eb59a06830fb488d9357f90100dff0d98b23ea3593a183d43e6f2f' /tmp/c-ares.tar.gz \
      '8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5' /tmp/curl.tar.xz \
      | sha256sum --check --strict; \
    tar -xzf /tmp/c-ares.tar.gz -C /tmp; \
    tar -xJf /tmp/curl.tar.xz -C /tmp; \
    cd /tmp/c-ares-1.34.9; \
    ./configure --prefix=/opt/transport --libdir=/opt/transport/lib --enable-shared --disable-static --disable-tests; \
    make -j2; make install; \
    cd /tmp/curl-8.23.0; \
    ./configure --prefix=/opt/transport --libdir=/opt/transport/lib \
      --enable-shared --disable-static \
      --enable-ares=/opt/transport --with-openssl=/usr \
      --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
      --without-zlib --without-brotli --without-zstd --without-libpsl \
      --without-libidn2 --without-nghttp2 --without-nghttp3 \
      --without-libssh --without-libssh2 --without-gssapi \
      --disable-ldap --disable-ldaps; \
    make -j2; make install; \
    printf '%s\n' /opt/transport/lib > /etc/ld.so.conf.d/private-transport.conf; \
    ldconfig; \
    /opt/transport/bin/curl --version; \
    /opt/transport/bin/curl --version | grep -F 'c-ares/1.34.9'; \
    rm -rf /tmp/c-ares.tar.gz /tmp/curl.tar.xz /tmp/c-ares-1.34.9 /tmp/curl-8.23.0
ENV PATH="/opt/transport/bin:${PATH}"

WORKDIR /build
COPY build.zig ./
COPY src/ ./src/
COPY db/migrations/ ./db/migrations/
COPY assets/password-deny-list.txt ./assets/password-deny-list.txt
RUN set -eu; \
    curl_info="$(curl --version)"; \
    printf '%s\n' "$curl_info"; \
    curl_version="$(printf '%s\n' "$curl_info" | sed -n '1s/.*libcurl\/\([^ ]*\).*/\1/p')"; \
    ares_version="$(printf '%s\n' "$curl_info" | sed -n '1s/.*c-ares\/\([^ ]*\).*/\1/p')"; \
    openssl_info="$(openssl version)"; \
    openssl_version="$(printf '%s\n' "$openssl_info" | awk 'NR == 1 { print $2 }')"; \
    test -n "$curl_version"; \
    test -n "$ares_version"; \
    test -n "$openssl_version"; \
    C_INCLUDE_PATH=/usr/include/postgresql zig build -Doptimize=ReleaseSafe \
      -Dmojang-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
      -Dmojang-curl-version="$curl_version" \
      -Dmojang-ares-version="$ares_version" \
      -Dmojang-openssl-version="$openssl_version" \
      --search-prefix /opt/transport --search-prefix /usr --search-prefix /usr/lib/x86_64-linux-gnu --prefix /out

FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libpq5 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 20903 mine-platform \
 && useradd --uid 20903 --gid 20903 --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin mine-platform
WORKDIR /app
COPY --from=builder /opt/transport/lib/libcurl.so.4* /opt/transport/lib/libcares.so.2* /usr/local/lib/
RUN ldconfig
COPY --from=builder /out/bin/mine-api /app/mine-api
USER 20903:20903
EXPOSE 8088
ENTRYPOINT ["/app/mine-api"]
