FROM postgres:17

RUN apt-get update \
    && apt-get install -y \
        pg-auto-failover-cli \
        postgresql-17-auto-failover \
        nano \
    && rm -rf /var/lib/apt/lists/*
