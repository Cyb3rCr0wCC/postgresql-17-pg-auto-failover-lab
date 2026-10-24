# PostgreSQL 17 High Availability Lab: pg_auto_failover + WAL Archiving + PITR

A hands-on lab that builds a **PostgreSQL 17 high-availability cluster** with [pg_auto_failover](https://github.com/hapostgres/pg_auto_failover) and Docker Compose, then makes it **recoverable** with WAL archiving, base backups and point-in-time recovery (PITR) on MinIO.

The lab is split into two parts. Each part is a step-by-step guide you can follow on its own machine.

| Part       | Goal                                                         | Guide                                                        |
| ---------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| **Part 1** | Build the HA cluster: monitor, primary, standby, automatic failover | [Part1_Setup_pg_auto_failover_cluster.md](https://claude.ai/chat/Part1_Setup_pg_auto_failover_cluster.md) |
| **Part 2** | Add WAL archiving, base backups and PITR with MinIO          | [Part2_Wal_archiving.md](https://claude.ai/chat/Part2_Wal_archiving.md) |

> High availability is not a backup strategy. Replication copies mistakes (a dropped table, a bad `DELETE`) to the standby within milliseconds. Part 1 keeps the database **available**; Part 2 keeps it **recoverable**.

------

## Part 1: Failover cluster with pg_auto_failover

Builds a three-node cluster on a Docker bridge network (`172.30.0.0/16`):

- **monitor**: the pg_auto_failover monitor, which tracks node state and orchestrates failover
- **pg1**: PostgreSQL 17 primary
- **pg2**: PostgreSQL 17 standby with streaming replication

What you will do:

- Build a Docker image with PostgreSQL 17 and pg_auto_failover
- Start the containers with `sleep infinity` so `pg_autoctl` (not the Docker entrypoint) owns PostgreSQL
- Create the monitor and both nodes with `pg_autoctl`
- Set up the three separate authentication paths (node to monitor, standby to primary, application to primary) using `.pgpass`
- Verify streaming replication
- Stop the primary, watch the standby get promoted, and bring the old primary back as a standby
- Troubleshoot common problems (`Address already in use`, `root execution is not permitted`, `password authentication failed`, missing `pg_autoctl.state`)

## Part 2: WAL archiving and point-in-time recovery with MinIO

Adds a **MinIO** container (S3-compatible object storage) as the archive and builds a full backup and recovery workflow on top of the cluster from Part 1.

What you will do:

- Add MinIO to Docker Compose and install the MinIO Client (`mc`) in the image
- Enable continuous **WAL archiving** on both nodes, so archiving survives a failover
- Take **physical base backups** streamed straight into MinIO with `pg_basebackup`
- **Simulate an accident** by dropping a table, then recover it with **PITR** in a throwaway scratch container
- Understand why a paused recovery cannot read a dropped table (the replayed `ACCESS EXCLUSIVE` lock), and how `pg_wal_replay_resume()` fixes it
- Copy the recovered data back into the live primary with `pg_dump`
- Walk through **full disaster recovery** when both nodes and their disks are gone
- Prune the archive safely (retention) and troubleshoot archiving and recovery problems

------

## Architecture

```
                  +-----------------------+
                  |  MinIO Object Storage |   <- Part 2
                  |   (pgaf-minio:9000)   |
                  +-----------^-----------+
                              |
               WAL: archive_command (mc cp)
               Base backups: pg_basebackup | mc pipe
                              |
                  +-----------+-----------+
                  |   Monitor Node        |   <- Part 1
                  |   (pgaf-monitor)      |
                  +---------+-------------+
                            |
           +----------------+----------------+
           |                                 |
           v                                 v
  +------------------+             +------------------+
  |  Primary (pg1)   |  == repl => |  Standby (pg2)   |
  |  172.30.0.11     |             |  172.30.0.12     |
  +------------------+             +------------------+
```

MinIO bucket layout:

```
pg-wal-archive/
  wal/    archived WAL segments and timeline history files
  base/   physical base backups (base-<UTC timestamp>.tar.gz)
```

## Repository contents

```
pg_auto_failover/
├── Dockerfile                               # PostgreSQL 17 + pg_auto_failover (+ MinIO client for Part 2)
├── Part1_Setup_pg_auto_failover_cluster.md  # HA cluster guide
├── Part2_Wal_archiving.md                   # WAL archiving, base backups, PITR guide
└── README.md
```

## Prerequisites

- Docker and Docker Compose v2
- A Linux, macOS or WSL2 shell
- About 2 GB of free disk space
- Basic familiarity with PostgreSQL and the command line

## Quick start

```bash
git clone <your-repo-url>
cd pg_auto_failover
```

1. Follow **Part 1** to start the containers and create the monitor, `pg1` and `pg2`.

2. Confirm the cluster is healthy:

   ```bash
   docker exec -u postgres pgaf-monitor pg_autoctl show state
   ```

   You should see 

   ```
   pg1
   ```

    as 

   ```
   primary
   ```

    and 

   ```
   pg2
   ```

    as 

   ```
   secondary
   ```

   .

3. Follow **Part 2** to add MinIO, enable archiving, take a base backup and run the recovery exercise.

Part 2 builds directly on the cluster from Part 1, so do them in order.

## Good to know

- The containers run `sleep infinity` and `pg_autoctl run` is started by hand inside them. If you recreate a container (for example with `docker compose up -d --build`), start `pg_autoctl run` again, monitor first.
- Run the recovery exercise in a **scratch container**, never in a node managed by pg_auto_failover. The monitor owns node state and would throw a restored node away.
- In the scratch instance, always set `archive_mode = 'off'`. Otherwise it can write into your real archive.
- Re-export `MINIO_USER` and `MINIO_PASS` in every new terminal, or `mc` fails with `Access Denied`.

## Security notice

This is a **learning lab**. It uses demonstration credentials (`admin` / `password123` and similar) in plain text and self-signed TLS, and MinIO runs on the same host as the databases. Before using anything like this in production:

- Use a secret manager instead of plain-text passwords
- Use trusted TLS certificates
- Keep the archive on separate storage or hardware, ideally in another location
- Monitor `pg_stat_archiver` and alert on failed archiving and old base backups
- Automate retention and test restores on a schedule
- Consider a dedicated tool such as pgBackRest or Barman for incremental backups and built-in retention

## Useful commands

```bash
# Cluster state
docker exec -u postgres pgaf-monitor pg_autoctl show state

# Is a node a standby? (t = standby, f = primary)
docker exec -u postgres pgaf-pg1 psql -U postgres -c "SELECT pg_is_in_recovery();"

# Is WAL archiving healthy? (failed_count must stay 0)
docker exec -u postgres pgaf-pg1 psql -U postgres -c \
  "SELECT archived_count, last_archived_wal, failed_count FROM pg_stat_archiver;"

# List archived WAL and base backups
docker exec -u postgres pgaf-pg1 mc ls myminio/pg-wal-archive/wal/
docker exec -u postgres pgaf-pg1 mc ls myminio/pg-wal-archive/base/
```

## Resetting the lab

To wipe everything and start over (this deletes all data in the volumes):

```bash
docker compose down -v
docker compose up -d
```

Never run `docker compose down -v` on a cluster whose data you care about.

## License

Add a license of your choice (for example MIT) and reference it here.