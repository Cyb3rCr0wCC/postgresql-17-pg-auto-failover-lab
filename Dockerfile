FROM postgres:17

RUN apt-get update \
    && apt-get install -y \
        curl \
        ca-certificates \
        build-essential \
        pkg-config \
        libssl-dev \
        liblz4-dev \
        libzstd-dev \
        libreadline-dev \
        libkrb5-dev \
        libcurl4-openssl-dev \
        libsystemd-dev \
        libseccomp-dev \
        libpq-dev \
        pg-auto-failover-cli \
        postgresql-17-auto-failover \
        git \
    && rm -rf /var/lib/apt/lists/*

# MinIO Client, pinned release from GitHub
ARG MC_RELEASE=RELEASE.2025-07-21T05-28-08Z
RUN curl -fsSL -o /usr/local/bin/mc \
      "https://github.com/minio/mc/releases/download/${MC_RELEASE}/mc.linux-amd64.${MC_RELEASE}" \
    && chmod +x /usr/local/bin/mc