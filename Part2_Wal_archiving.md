# PostgreSQL 17 High Availability Part 2: WAL Archiving and Point-in-Time Recovery with MinIO

*Part 2 of 2. In \[Part 1\] we built a PostgreSQL 17 failover cluster with pg\_auto\_failover and Docker Compose. Now we make it recoverable.*

In Part 1 we built a monitor, a primary and a standby. We stopped the primary, watched the standby take over, and brought the old primary back as a standby. That is high availability.

But there is one sentence at the end of Part 1 that deserves its own article:

> High availability is not a backup strategy.

In this part we fix that. We will add:

- A MinIO container (S3-compatible object storage) that holds our archive
- Continuous WAL archiving from both PostgreSQL nodes
- Physical base backups streamed straight into MinIO
- Point-in-time recovery (PITR): we will drop a table on purpose and get it back
- A short walkthrough of full disaster recovery when both nodes are gone

Everything here was tested on the cluster from Part 1. I also hit most of the pitfalls on the way, so I will point them out where they happen.

## 1. Why Replication Does Not Protect You

Streaming replication copies every change from the primary to the standby. Every change means every change:

```
DROP TABLE customers;      -- on pg1
                           -- pg2 drops it too, a few milliseconds later
```

The standby faithfully replays the accident. Failover does not help either, because the new primary is just as empty.

To get the data back we need two things:

1. A **base backup**: a physical copy of the whole cluster at some moment in the past.
2. **WAL archive**: every change since that moment, stored somewhere safe.

With both, we can rebuild the database as it was at any second after the base backup. That is point-in-time recovery.

## 2. The Architecture

We add one container to the three from Part 1:

```
                  +-----------------------+
                  |  MinIO Object Storage |
                  |   (pgaf-minio:9000)   |
                  +-----------^-----------+
                              |
               WAL: archive_command (mc cp)
               Base backups: pg_basebackup | mc pipe
                              |
                  +-----------+-----------+
                  |   Monitor Node        |
                  |   (pgaf-monitor)      |
                  +---------+-------------+
                            |
           +----------------+----------------+
           |                                 |
           v                                 v
  +------------------+             +------------------+
  |  Primary (pg1)   |             |  Standby (pg2)   |
  |  172.30.0.11     |             |  172.30.0.12     |
  +------------------+             +------------------+
```

The bucket will look like this:

```
pg-wal-archive/
  wal/    archived WAL segments and timeline history files
  base/   physical base backups (base-<UTC timestamp>.tar.gz)
```

Never put other files into `wal/`. During recovery PostgreSQL asks for files there by exact name.

**One warning about the lab:** MinIO runs next to the database nodes on the same Docker host. In a real deployment, keep it on separate storage or hardware. An archive that dies together with the database is not a backup.

## 3. Add MinIO and the MinIO Client

### 3.1 Add MinIO to docker-compose.yml

Add this service next to `monitor`, `pg1` and `pg2`:

```yaml
  minio:
    image: minio/minio:latest
    container_name: pgaf-minio
    hostname: minio
    environment:
      MINIO_ROOT_USER: admin
      MINIO_ROOT_PASSWORD: password123   # change this outside of a lab
    command: server /data --console-address ":9001"
    ports:
      - "9000:9000"
      - "9001:9001"
    volumes:
      - minio_data:/data
    networks:
      pgaf:
        ipv4_address: 172.30.0.5
```

And add the volume:

```yaml
volumes:
  minio_data:
  monitor_data:
  pg1_data:
  pg2_data:
```

### 3.2 Install the MinIO Client (mc) in the image

PostgreSQL will call `mc` from `archive_command`, so the client must exist inside the database containers.

> **Careful:** on Debian and Ubuntu the apt package named `mc` is Midnight Commander, a file manager. It is not the MinIO Client. Download the MinIO binary instead.

Add this to the end of the Dockerfile from Part 1:

```dockerfile
ARG MC_RELEASE=RELEASE.2025-07-21T05-28-08Z
RUN curl -fsSL -o /usr/local/bin/mc \
      "https://github.com/minio/mc/releases/download/${MC_RELEASE}/mc.linux-amd64.${MC_RELEASE}" \
    && chmod +x /usr/local/bin/mc
```

On an ARM host, use `linux-arm64` in the URL.

### 3.3 Rebuild and restart the cluster processes

```bash
docker compose up -d --build
```

There is a catch here. In Part 1 our containers only run `sleep infinity`, and we started `pg_autoctl run` by hand inside each one. Recreating a container kills that process. The data survives in the volumes, but you have to start the processes again, monitor first:

```bash
docker exec -it pgaf-monitor bash
pg_autoctl run --pgdata /var/lib/postgresql/monitor &
```

Then the same on `pgaf-pg1` and `pgaf-pg2`:

```bash
pg_autoctl run --pgdata /var/lib/postgresql/data/pgdata &
```

Check that the cluster is healthy again, and that `mc` is the right one:

```bash
docker exec -u postgres pgaf-monitor pg_autoctl show state
docker exec -u postgres pgaf-pg1 mc --version
```

The second command must mention MinIO. If it prints something about Midnight Commander, you installed the wrong package.

Here's expected result:

``````bash
➜  pg_auto_failover git:(main) ✗ docker exec -u postgres pgaf-pg1 mc --version

mc version RELEASE.2025-08-13T08-35-41Z (commit-id=7394ce0dd2a80935aded936b09fa12cbb3cb8096)
Runtime: go1.24.6 linux/amd64
Copyright (c) 2015-2025 MinIO, Inc.
License GNU AGPLv3 <https://www.gnu.org/licenses/agpl-3.0.html>
``````



## 4. Connect the Nodes to MinIO

For the rest of the article I use two variables in my host shell:

```bash
export MINIO_USER=admin
export MINIO_PASS=password123
```

**Pitfall:** these variables exist only in the terminal where you exported them. If you open a new terminal and they are empty, `mc` fails with `Access Denied`. I lost some time on that one.

### 4.1 Create the alias as the postgres user

The `mc` alias is stored per operating system user. `archive_command` runs as `postgres`, so the alias must be created as `postgres`, on both nodes:

```bash
for n in pg1 pg2; do
  docker exec -u postgres pgaf-$n mc alias set myminio http://minio:9000 "$MINIO_USER" "$MINIO_PASS"
done
```

### 4.2 Create the bucket

```bash
docker exec -u postgres pgaf-pg1 mc mb --ignore-existing myminio/pg-wal-archive
docker exec -u postgres pgaf-pg1 mc ls myminio/
```

## 5. Enable WAL Archiving

WAL files are PostgreSQL’s write-ahead log. Each file is a 16 MB segment. When a segment is full, PostgreSQL calls `archive_command` to copy it somewhere safe.

We configure **both** nodes. After a failover the new primary must keep archiving, otherwise the archive would silently stop at the worst possible time.

```bash
for n in pg1 pg2; do
  docker exec -i -u postgres pgaf-$n psql -U postgres -v ON_ERROR_STOP=1 <<'SQL'
ALTER SYSTEM SET archive_mode = 'on';
ALTER SYSTEM SET archive_timeout = '300';
ALTER SYSTEM SET archive_command = 'mc stat myminio/pg-wal-archive/wal/%f >/dev/null 2>&1 || mc cp --quiet %p myminio/pg-wal-archive/wal/%f';
SQL
done
```

Why `ALTER SYSTEM`? It is per node, it is not replicated, and it does not fight with the configuration files that pg\_auto\_failover manages. A plain `pg_autoctl reload` will **not** apply these settings.

What each setting does:

- **archive\_mode = on**: archive WAL from the primary. A standby only archives after it has been promoted.
- **archive\_command**: first checks whether the file is already in MinIO (an archived segment must never be overwritten), otherwise copies it. `%p` is the full path of the segment and `%f` is its file name.
- **archive\_timeout = 300**: force a segment switch every 5 minutes, so an idle server still ships its WAL. This bounds your possible data loss to about 5 minutes.

### 5.1 Restart PostgreSQL

`archive_mode` needs a real restart, not a reload. Because `pg_autoctl` supervises PostgreSQL, we stop PostgreSQL and let `pg_autoctl` bring it back. Do the **standby first**, then the primary:

```bash
docker exec -u postgres pgaf-pg2 pg_ctl -D "/var/lib/postgresql/data/pgdata" stop -m fast
docker exec -u postgres pgaf-monitor pg_autoctl show state   # wait until pg2 is healthy again

docker exec -u postgres pgaf-pg1 pg_ctl -D "/var/lib/postgresql/data/pgdata" stop -m fast
docker exec -u postgres pgaf-monitor pg_autoctl show state --pgdata /var/lib/postgresql/monitor/
```

A short failover to pg2 while pg1 restarts is normal. That is exactly what the cluster is for.

``````c
➜  pg_auto_failover git:(main) ✗ docker exec -u postgres pgaf-monitor pg_autoctl show state --pgdata /var/lib/postgresql/monitor/

    Name |  Node |  Host:Port |       TLI: LSN |   Connection |      Reported State |      Assigned State
---------+-------+------------+----------------+--------------+---------------------+--------------------
node_141 |   141 |   pg1:5432 |   3: 0/C000270 |   read-write |             primary |             primary
node_143 |   143 |   pg2:5432 |   3: 0/C000270 |    read-only |           secondary |           secondary
``````

If PostgreSQL does not come back, `pg_autoctl run` is not running in that container. Start it again as in section 3.3.



### 5.2 Verify. Do not continue until this works

Run this on the **current primary** (check `pg_autoctl show state`; I use `pgaf-pg1` here):

```bash
docker exec -u postgres pgaf-pg1 psql -U postgres -c "SHOW archive_mode;"
docker exec -u postgres pgaf-pg1 psql -U postgres -c "SELECT pg_switch_wal();"
sleep 5
docker exec -u postgres pgaf-pg1 psql -U postgres -c "SELECT archived_count, last_archived_wal, failed_count FROM pg_stat_archiver;"
docker exec -u postgres pgaf-pg1 mc ls myminio/pg-wal-archive/wal/
```

`failed_count` must be `0`, and segment files must appear under `wal/`. If `failed_count` grows, the usual causes are a missing alias for the `postgres` user, wrong credentials, or a missing bucket.

Here's expected outputs for above commands:

![image-20261024112134516](/home/cybercrow/snap/typora/119/.config/Typora/typora-user-images/image-20261024112134516.png)

## 6. Take a Base Backup

WAL alone is useless. It describes changes, so it needs a starting point. That starting point is a base backup, and it must be taken **before** the moment you want to recover to.

We stream it straight into MinIO, with no temporary files:

```bash
docker exec -u postgres pgaf-pg1 bash -c 'set -o pipefail
pg_basebackup -h localhost -U postgres -D - -Ft -X fetch -c fast -z \
  | mc pipe myminio/pg-wal-archive/base/base-$(date -u +%Y%m%dT%H%M%SZ).tar.gz'

docker exec -u postgres pgaf-pg1 mc ls myminio/pg-wal-archive/base/
```

![image-20261024114028540](/home/cybercrow/snap/typora/119/.config/Typora/typora-user-images/image-20261024114028540.png)

What the flags mean:

- `-Ft -D - -z`: a gzip-compressed tar on stdout, piped into `mc pipe`.
- `-X fetch`: includes the WAL needed to make the backup consistent.
- `-c fast`: do an immediate checkpoint instead of a spread one.
- `set -o pipefail`: if `pg_basebackup` fails, the whole command fails instead of leaving a truncated file that looks fine.

If you get a `pg_hba.conf` error for the replication connection, use `-U pgautofailover_replicator` and pass its password with `PGPASSWORD`. Also note that `-D -` does not work when the cluster has extra tablespaces. This lab has none.

### Schedule it

A daily backup from the host’s crontab:

```
0 2 * * * docker exec -u postgres pgaf-pg1 bash -c 'set -o pipefail; pg_basebackup -h localhost -U postgres -D - -Ft -X fetch -c fast -z | mc pipe myminio/pg-wal-archive/base/base-$(date -u +\%Y\%m\%dT\%H\%M\%SZ).tar.gz'
```

After a failover the primary may be `pg2`, so the job has to target the right container. Either check `pg_autoctl show state` first, or run the backup from the standby.

Take one base backup now, before the next section. The simulation only works if a backup exists from before the accident.

## 7. Simulate an Accident

Time to break something. Connect to the current primary:

```bash
docker exec -it -u postgres pgaf-pg1 psql -U postgres
```

```sql
CREATE DATABASE simulation_db;
\c simulation_db
```

**Pitfall:** look at the prompt. It must say `simulation_db=#` before you create the table. In my first attempt the prompt still said `postgres=#`, the table landed in the wrong database, and my later checks in `simulation_db` found nothing.

Now create the data:

```sql
CREATE TABLE sensitive_records (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);
INSERT INTO sensitive_records (data) VALUES ('Alpha'), ('Beta');

SELECT now();            -- note this timestamp: it is the recovery target
SELECT pg_sleep(5);

DROP TABLE sensitive_records;   -- the "accident"
SELECT pg_switch_wal();         -- ship the segment containing the drop
\q
```

The `now()` value is the important one. In my run it printed `2026-10-24 05:06:53.61351+00`. That moment sits after the INSERT and before the DROP, so recovering to it gives us Alpha and Beta with the table intact.

Expected output for above commands:

![image-20261024114158892](/home/cybercrow/snap/typora/119/.config/Typora/typora-user-images/image-20261024114158892.png)

Save it for later (use your own value):

```bash
export TARGET='2026-10-24 06:41:11.494003+00'
```

Then wait until the segment with the DROP has reached MinIO:

```bash
docker exec -u postgres pgaf-pg1 psql -U postgres \
  -c "SELECT last_archived_wal, last_archived_time FROM pg_stat_archiver;"
```

`last_archived_time` must be later than the DROP. If it is not, recovery would not find the WAL that contains the target.

In a real incident you will not have a `now()` that you noted in advance. You will read the time of the bad statement from your logs and choose a moment a few seconds before it.

## 8. Start a Scratch Container

We will not restore into `pg1`. With pg\_auto\_failover, the monitor owns the node state. If you restore into pg1’s data directory, the monitor promotes pg2 while pg1 is down, and when pg1 returns it is treated as a stale node and re-synced from pg2. Your restore would be thrown away. A restore also rewinds every database in the cluster, losing all legitimate writes made after the target time.

Instead we rebuild a throwaway PostgreSQL from the backup and WAL, recover the lost table there, and copy only that table back. The live cluster is never touched.

Start a scratch container from the same image as `pg1`, on the same Docker network:

```bash
IMAGE=$(docker inspect -f '{{.Config.Image}}' pgaf-pg1)
NET=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' pgaf-pg1)

docker run -it --rm --name pgrestore --network "$NET" --user postgres \
  -e HOME=/tmp \
  -e TARGET="$TARGET" \
  -e MC_HOST_myminio="http://admin:password123@minio:9000" \
  --entrypoint bash "$IMAGE"
```

`MC_HOST_myminio` lets `mc` talk to MinIO without an alias file, so `restore_command` works for the PostgreSQL process in this container. Putting a password on a command line is fine in a lab. In production use a secret manager.

Check `mc` inside the container:

```bash
mc --version
mc ls myminio/pg-wal-archive/base/
```

If you see `Access Denied`, your `MINIO_USER` and `MINIO_PASS` were empty when you started the container. Exit and start it again.

## 9. Restore the Base Backup and Configure Recovery

Inside the scratch container, pick the newest backup that was taken **before** the target time:

```bash
mc ls myminio/pg-wal-archive/base/

mkdir -m 700 /tmp/restore
mc cat myminio/pg-wal-archive/base/base-XXXXXXXXTXXXXXXZ.tar.gz | tar -xz -C /tmp/restore

cd /tmp/restore
rm -f postmaster.pid standby.signal recovery.signal
```

Expected output:

![image-20261024114520197](/home/cybercrow/snap/typora/119/.config/Typora/typora-user-images/image-20261024114520197.png)

Now tell PostgreSQL how to recover:

```bash
cat >> postgresql.auto.conf <<EOF
archive_mode = 'off'
restore_command = 'mc cp --quiet myminio/pg-wal-archive/wal/%f %p'
recovery_target_time = '$TARGET'
recovery_target_action = 'pause'
hot_standby = 'on'
port = 5433
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
synchronous_standby_names = ''
ssl = 'off'
EOF

touch recovery.signal
```

Why each line matters:

- **archive\_mode = 'off' is mandatory.** The restored configuration contains the live cluster’s archive settings. Without this line the scratch instance would push its own timeline files into your real archive and corrupt it.
- **restore\_command** fetches WAL segments from MinIO. `%f` is the file name PostgreSQL wants, `%p` is where to put it.
- **recovery\_target\_time** is the moment to stop at.
- **recovery\_target\_action = 'pause'** stops at the target instead of finishing recovery, so we can check where we stopped before committing to it. More on this below.
- **port, listen\_addresses, unix\_socket\_directories, synchronous\_standby\_names** override what pg\_auto\_failover put in its own configuration files, so the scratch instance does not try to talk to the real cluster.
- **ssl = 'off'** avoids startup errors from certificate paths that existed in the original container but not here.

`postgresql.auto.conf` is read last, so it wins over the pg\_auto\_failover configuration.

## 10. Run Recovery

```bash
pg_ctl -D /tmp/restore -l /tmp/restore.log -w -t 600 start
tail -n 30 /tmp/restore.log
```

If last command says:

``````
postgres@337f6eed70c3:~/restore$ tail -n 30 /tmp/restore.log
2026-10-24 06:45:30.761 UTC [121] LOG:  redirecting log output to logging collector process
2026-10-24 06:45:30.761 UTC [121] HINT:  Future log output will appear in directory "log".
``````

Our log files located at `$PGDATA/logs/*.log`. If it is then run `tail -f /tmp/restore/logs/*.log`
Last lines looks like this.

``````
==> /tmp/restore/log/postgresql-2026-10-24_064530.log <==
│ 16.00 MiB │ 16.00 MiB   │ 00m00s   │ 395.23 MiB/s │
└───────────┴─────────────┴──────────┴──────────────┘
2026-10-24 06:45:31.177 UTC [125] LOG:  restored log file "000000030000000000000011" from archive
2026-10-24 06:45:31.192 UTC [125] LOG:  completed backup recovery with redo LSN 0/10000028 and end LSN 0/10000120
2026-10-24 06:45:31.192 UTC [125] LOG:  consistent recovery state reached at 0/10000120
2026-10-24 06:45:31.192 UTC [121] LOG:  database system is ready to accept read-only connections
mc: <ERROR> Unable to prepare URL for copying. Unable to guess the type of copy operation.
2026-10-24 06:45:31.306 UTC [125] LOG:  recovery stopping before commit of transaction 760, time 2026-10-24 06:41:27.337194+00
2026-10-24 06:45:31.306 UTC [125] LOG:  pausing at the end of recovery
2026-10-24 06:45:31.306 UTC [125] HINT:  Execute pg_wal_replay_resume() to promote.
``````

Read the stop line carefully. Recovery replays commits up to the first one **after** your target and stops right before it. Transaction 760 committed at **06:41:27**, about **16** seconds after my target of **06:41:11**. That transaction is the `DROP TABLE`.

You will probably also see this line in the log:

```
mc: <ERROR> Unable to prepare URL for copying. Unable to guess the type of copy operation.
```

It looks alarming, but it is harmless. After the last available segment, PostgreSQL asks for the next WAL file, which does not exist yet. `restore_command` fails for it, and that failure is how PostgreSQL learns the archive has ended. Do not try to make that command always succeed.

Confirm that recovery is paused and where it stopped:

```bash
psql -h /tmp -p 5433 -U postgres -At -c "SELECT pg_get_wal_replay_pause_state();"   # expect: paused
psql -h /tmp -p 5433 -U postgres -At -c "SELECT pg_last_xact_replay_timestamp();"   # must be before the bad statement
```

The replay timestamp has to be earlier than the time of the `DROP`. If it is, the target is right.

## 11. Why SELECT Hangs While Paused (and What to Do)

This is the part that surprised me, and it is the reason `pause` needs a second step.

My first instinct was to query the table while recovery was paused:

```bash
psql -h /tmp -p 5433 -U postgres -d simulation_db -c "SELECT * FROM sensitive_records;"
```

It did not return an error. It did not return rows. It simply hung.

Here is why. A `DROP TABLE` writes several things to the WAL, in this order:

1. A lock record: an `ACCESS EXCLUSIVE` lock on the table.
2. Changes to the system catalogs, marking the table’s rows in `pg_class`, `pg_attribute` and friends as deleted by that transaction.
3. The **commit record** of the transaction.

PostgreSQL checks the recovery target at commit records. So the scratch instance replayed items 1 and 2 and stopped before item 3. The startup process is now holding the `ACCESS EXCLUSIVE` lock on the table, waiting for a commit that it will never replay. Any query that touches the table waits for that lock. That includes `pg_dump`.

Catalog-only commands such as `\dt` and `\l` still work, because they never touch the table itself. That is a good trick to know: `\dt` showing your table while `SELECT` hangs is exactly the symptom of this situation.

The fix is to end recovery:

```bash
psql -h /tmp -p 5433 -U postgres -c "SELECT pg_wal_replay_resume();"
```

Because the recovery target was already reached, this ends recovery and **promotes** the instance. At promotion, any transaction that is still open is treated as aborted. The `DROP` never committed in this copy, so it is rolled back: the catalog rows count as alive again, the data files were never deleted (that only happens when the commit record is replayed), and the lock is released.

Promotion takes a moment, so wait for it to finish instead of querying immediately:

```bash
until [ "$(psql -h /tmp -p 5433 -U postgres -At -c 'SELECT pg_is_in_recovery()')" = f ]; do sleep 1; done

psql -h /tmp -p 5433 -U postgres -d simulation_db -c "SELECT * FROM sensitive_records;"
```

You should see:

```
 id | data  |          created_at           
----+-------+-------------------------------
  1 | Alpha | 2026-10-24 06:41:08.486385+00
  2 | Beta  | 2026-10-24 06:41:08.486385+00
```

The table is back.

### What if the target was wrong?

Once promoted, the instance is on a new timeline and cannot move backwards. Stop it with `pg_ctl -D /tmp/restore stop -m immediate`, delete `/tmp/restore`, and redo section 9 from the base backup with a different `TARGET`. That is safe because `archive_mode = 'off'` keeps the scratch instance away from your real archive.

### Two alternatives

**Skip the pause.** If you do not need to check the stop point before promoting, set `recovery_target_action = 'promote'`. The instance promotes itself at the target and the table is readable immediately.

**Target a transaction instead of a time.** Clocks are fuzzy, but transaction IDs are exact. The stop line in the log gave us the xid of the DROP (769). You could recover to just before it with:

```
recovery_target_xid = '769'
recovery_target_inclusive = 'false'
```

In a real incident, you can find the xid of the bad transaction with `pg_waldump` on the archived segment:

```bash
mc cp myminio/pg-wal-archive/wal/000000010000000000000010 /tmp/
pg_waldump -r Transaction /tmp/000000010000000000000010 | grep COMMIT
```

Each line shows the xid, commit time and, for a DROP, the files it removes.

But in my case I got my data back and now I need to copy that data from temporary docker container to primary db.

First check if **simulation_db** really doesnt contain any tables.

![image-20261024115113843](/home/cybercrow/snap/typora/119/.config/Typora/typora-user-images/image-20261024115113843.png)

## 12. Copy the Data Back into the Live Cluster

The recovered table exists only in the scratch container, so we copy it into the real primary. From a second host terminal:

```bash
docker exec pgrestore pg_dump -h /tmp -p 5433 -U postgres -d simulation_db -t sensitive_records \
  | docker exec -i -u postgres pgaf-pg1 psql -U postgres -d simulation_db -v ON_ERROR_STOP=1
```

Write to whichever node is the current primary. Do not promote the scratch instance into the cluster, and do not touch the standby: it follows the primary and will receive the table through replication.

The right command depends on what was lost:

- **Table dropped:** dump it as above, schema and data.
- **Rows deleted but the table still exists:** use `--data-only` and load into a staging table first. Then merge only the missing rows with `INSERT ... SELECT`.
- **Whole database dropped:** add `-C` to the dump and load it while connected to the `postgres` database.

Check the result on the live cluster, then `exit` the scratch container. Because we started it with `--rm`, Docker deletes it. Copy anything you still need out of it before you exit.

Expected ouput:

![image-20261024115219104](/home/cybercrow/snap/typora/119/.config/Typora/typora-user-images/image-20261024115219104.png)

Check if we could get table back.

![image-20261024115257251](/home/cybercrow/snap/typora/119/.config/Typora/typora-user-images/image-20261024115257251.png)

## 13. Full Disaster Recovery: Both Nodes Gone

Sometimes the problem is not a dropped table. Both database nodes and their disks are gone. As long as **MinIO and its data survived**, everything can be rebuilt from the archive.

Simulate it:

```bash
docker compose stop pg1 pg2
docker compose rm -f pg1 pg2
docker volume ls | grep -E 'pg1_data|pg2_data'     # note the exact volume names
docker volume rm <project>_pg1_data <project>_pg2_data
```

The recovery itself is the same scratch-instance procedure from sections 8 and 9, with two differences: leave out `recovery_target_time` and `recovery_target_action`, and you do not need `TARGET`. With no target, PostgreSQL replays everything in the archive and promotes itself when the archive runs out. Confirm it finished:

```bash
psql -h /tmp -p 5433 -U postgres -c "SELECT pg_is_in_recovery();"    # f means done
```

Keep this container running. Then rebuild a fresh cluster, so the monitor holds no stale state:

1. Remove the monitor and node containers and their volumes, then `docker compose up -d`.
2. Recreate the monitor, pg1 and pg2 with the commands from Part 1, using the same passwords.
3. Redo sections 4 and 5 of this article (alias, archiving, restart).

Reload the roles first, skipping the ones pg\_auto\_failover just created:

```bash
docker exec pgrestore pg_dumpall -h /tmp -p 5433 -U postgres --roles-only \
  | grep -v -E 'ROLE (postgres|pgautofailover[a-z_]*)( |;)' \
  | docker exec -i -u postgres pgaf-pg1 psql -U postgres -d postgres
```

Then every user database:

```bash
for db in $(docker exec pgrestore psql -h /tmp -p 5433 -U postgres -At \
    -c "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'"); do
  docker exec pgrestore pg_dump -h /tmp -p 5433 -U postgres -C -d "$db" \
    | docker exec -i -u postgres pgaf-pg1 psql -U postgres -d postgres -v ON_ERROR_STOP=1
done
```

Run these against the new primary. The standby receives everything through replication. Finally, take a **fresh base backup** (section 6). The old backups belong to the old cluster’s history.

There is one limit to remember. Data in the current, not yet archived segment on the dead primary is lost. With `archive_timeout = 300` that is at most about five minutes of writes.

## 14. Retention: Do Not Delete What a Backup Needs

Your archive will grow forever unless you prune it, but pruning has one rule:

> Delete only WAL older than the oldest base backup you still want to restore from.

If you delete a segment that a kept backup needs, that backup is silently unusable.

Each base backup leaves a small history file in `wal/`. In my archive it looked like this:

```
00000001000000000000000B.00000028.backup
```

The part before the first dot is the first WAL segment that backup needs. So if the oldest backup you keep needs `00000001000000000000000B`, every segment with a smaller name can go:

```bash
KEEP_FROM=00000001000000000000000B

for f in $(mc ls myminio/pg-wal-archive/wal/ | awk '{print $NF}' | grep -E '^[0-9A-F]{24}$'); do
  if [[ "$f" < "$KEEP_FROM" ]]; then
    mc rm myminio/pg-wal-archive/wal/$f
  fi
done
```

The `grep` keeps the loop away from `.backup` and `.history` files. Those are small, and timeline history files in particular are needed for recovery across a failover, so leave them alone. Run the loop with `echo mc rm` first to see what it would delete, and test a restore after changing any retention rule. A backup you have never restored is a hope, not a backup.

## 15. Troubleshooting

**`failed_count` grows in `pg_stat_archiver`** The `mc` alias is missing for the `postgres` user, the credentials are wrong, or the bucket does not exist. Test with `docker exec -u postgres pgaf-pg1 mc ls myminio/pg-wal-archive`.

**`mc: command not found`, or a strange text interface appears** You installed Midnight Commander from apt. Use the MinIO binary from section 3.2.

**`Access Denied` from `mc`** `MINIO_USER` and `MINIO_PASS` are empty in the terminal you are using. Export them again.

**Recovery log ends early with `could not open file`** The WAL is not in `wal/`. Check the verification in section 5.2, and make sure `restore_command` uses the same `wal/` prefix as `archive_command`.

**`recovery ended before configured recovery target was reached`** Your target is later than the last archived WAL. Run `pg_switch_wal()` on the primary, wait for archiving, and retry.

**`SELECT` or `pg_dump` hangs on the scratch instance** Recovery is still paused with a dropped table locked by replay. Run `pg_wal_replay_resume()`, or use `recovery_target_action = 'promote'` next time.

**The table is not found after recovery** Check which database you were in when you created it (section 7). Run `\l` and `\dt` in the scratch instance.

**PostgreSQL will not start in the scratch container** Read `/tmp/restore.log`. It is usually something in the restored pg\_auto\_failover configuration, such as SSL paths or the hba file. Override it in `postgresql.auto.conf`.

**The restored instance starts shipping WAL to the archive** `archive_mode = 'off'` is missing from the scratch configuration. Stop it immediately and check `wal/` for unexpected timeline files.

**`pg_dump` or `psql` cannot connect in the scratch container** Use the socket: `-h /tmp -p 5433`. The scratch instance only listens inside its own container.

## 16. Production Considerations

This is a lab, and a few things need more work before you trust it with real data:

- Keep MinIO (or whichever object store you use) on separate hardware, ideally in another location
- Use strong credentials and a secret manager instead of plain text in Compose files and `docker run`
- Use trusted TLS certificates for MinIO and PostgreSQL
- Monitor `pg_stat_archiver`. Archiving that quietly fails is the most dangerous failure in this whole setup
- Alert when the newest base backup is older than you expect
- Automate retention and test restores on a schedule
- Consider a dedicated tool such as pgBackRest or Barman when you need parallel backups, incremental backups, or built-in retention

## Conclusion

In Part 1 we built a cluster that survives a dead server. In this part we built one that survives a bad statement.

The moving pieces are simple once you see them together:

```
base backup  +  archived WAL  +  recovery target
   (start)         (history)        (where to stop)
```

The lessons I would keep:

1. Replication copies mistakes. Only a backup plus WAL gives you a way back.
2. Never restore into a node managed by pg\_auto\_failover. Recover into a scratch instance and copy the data back.
3. Always set `archive_mode = 'off'` in the scratch instance.
4. A paused recovery cannot read a table whose `DROP` was replayed. Resume, which promotes, and then query.
5. Test the whole thing before you need it. Drop a table on purpose, recover it, and write down how long it took.

That is the full path: failover for availability, WAL archiving and base backups for recoverability. If you build it, break it on purpose at least once.
