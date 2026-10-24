# PostgreSQL 17 + pg_auto_failover

## Docker Compose — 1 Monitor + 2 PostgreSQL Nodes

This guide creates the following topology:

```text
                         Docker network
                    pgaf-network / 172.30.0.0/16
                              |
             +----------------+----------------+
             |                |                |
             v                v                v
        +---------+      +---------+      +---------+
        | monitor |      |   pg1   |      |   pg2   |
        | Monitor |      | Primary |      | Standby |
        | PG 17   |      | PG 17   |      | PG 17   |
        +---------+      +---------+      +---------+
             |                |
             |                | streaming replication
             |                +-------------------->
             |
             +------ pg_auto_failover control
```

The final cluster should look approximately like:

```text
monitor:5432
    |
    +---- pg1:5432  primary
    |
    +---- pg2:5432  standby
```

---

# 1. Important Architecture Decision

Do **not** allow the standard `postgres:17` Docker entrypoint to automatically start PostgreSQL.

That was the source of one of the earlier problems.

If the container starts the normal PostgreSQL instance automatically, then:

```text
5432
 |
 +-- PostgreSQL from Docker entrypoint
```

and later:

```text
pg_autoctl create monitor --pgport 5432
```

tries to start another PostgreSQL instance on the same port:

```text
could not bind IPv4 address "0.0.0.0": Address already in use
could not bind IPv6 address "::": Address already in use
```

Instead, this setup starts containers with:

```bash
sleep infinity
```

and we manually let `pg_autoctl` initialize and manage PostgreSQL.

---

# 2. Directory Structure

Create:

```text
pg_auto_failover/
├── docker-compose.yml
├── Dockerfile
├── .env
├── .gitignore
└── pgpass/
    ├── monitor.pgpass
    ├── pg1.pgpass
    └── pg2.pgpass
```

---

# 3. Dockerfile

Create:

```dockerfile
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
```

We are using the PostgreSQL 17 image and installing the pg_auto_failover packages.

No `make` or source compilation is required.

---

# 4. Environment File

Create `.env`:

```dotenv
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres_admin_password

AUTOCTL_USER=autoctl_node
AUTOCTL_PASSWORD=autoctl_node_password

PG_AUTO_FAILOVER_REPLICATION_USER=pgautofailover_replicator
PG_AUTO_FAILOVER_REPLICATION_PASSWORD=pg_auto_failover_replication_password

PGDATA=/var/lib/postgresql/data/pgdata

APP_USER=app
APP_PASSWORD=app_password
APP_DB=appdb
```

For a real deployment, replace these passwords with strong secrets.

---

# 5. Docker Compose

Create `docker-compose.yml`:

```yaml
services:

  monitor:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: pgaf-monitor
    hostname: monitor
    user: postgres

    environment:
      PGDATA: /var/lib/postgresql/monitor

    command: ["sleep", "infinity"]

    volumes:
      - monitor_data:/var/lib/postgresql/monitor

    networks:
      pgaf:
        ipv4_address: 172.30.0.10


  pg1:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: pgaf-pg1
    hostname: pg1
    user: postgres

    environment:
      PGDATA: /var/lib/postgresql/data/pgdata

    command: ["sleep", "infinity"]

    volumes:
      - pg1_data:/var/lib/postgresql/data/pgdata

    networks:
      pgaf:
        ipv4_address: 172.30.0.11


  pg2:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: pgaf-pg2
    hostname: pg2
    user: postgres

    environment:
      PGDATA: /var/lib/postgresql/data/pgdata

    command: ["sleep", "infinity"]

    volumes:
      - pg2_data:/var/lib/postgresql/data/pgdata

    networks:
      pgaf:
        ipv4_address: 172.30.0.12


volumes:
  monitor_data:
  pg1_data:
  pg2_data:


networks:
  pgaf:
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.0.0/16
```

The important part is:

```yaml
command: ["sleep", "infinity"]
```

This means Docker does **not** automatically start PostgreSQL.

`pg_autoctl` will manage the PostgreSQL processes.

---

# 6. Build the Containers

Run:

```bash
docker compose up -d
```

Check:

```bash
docker compose ps
```

Expected:

```text
NAME          STATUS
pgaf-monitor  Up
pgaf-pg1      Up
pgaf-pg2      Up
```

Check the network:

```bash
docker network inspect pg_auto_failover_pgaf
```

You should see:

```text
monitor -> 172.30.0.10
pg1     -> 172.30.0.11
pg2     -> 172.30.0.12
```

---

# 7. Verify PostgreSQL Is NOT Already Running

This is important.

On the monitor:

```bash
docker exec -it pgaf-monitor bash
```

Run:

```bash
pg_isready -h localhost -p 5432
```

It should NOT report a normal PostgreSQL server running yet.

Likewise on pg1:

```bash
docker exec -it pgaf-pg1 bash
```

and:

```bash
pg_isready -h localhost -p 5432
```

There should not already be a PostgreSQL instance.

This prevents the:

```text
Address already in use
```

problem.

---

# 8. Create the pg_auto_failover Monitor

Enter monitor:

```bash
docker exec -it pgaf-monitor bash
```

Verify:

```bash
whoami
```

It should return:

```text
postgres
```

Check:

```bash
echo $PGDATA
```

Expected:

```text
/var/lib/postgresql/monitor
```

Now create the monitor:

```bash
pg_autoctl create monitor --pgdata /var/lib/postgresql/monitor/pgdata --pgport 5432 --hostname monitor --auth scram-sha-256 --ssl-self-signed
```

Run 

``````bash
pg_autoctl run --pgdata /var/lib/postgresql/monitor/pgdata/ &
``````

The monitor PostgreSQL instance is now managed by `pg_autoctl`.

The self-signed SSL option creates certificates automatically. It encrypts traffic but does not provide protection against MITM/impersonation, so use a trusted CA/certificate setup for production.

---

# 9. Check the Monitor

Inside monitor:

```bash
pg_autoctl show state --pgdata /var/lib/postgresql/monitor/pgdata/
```

Also:

```bash
pg_autoctl show uri --pgdata /var/lib/postgresql/monitor/pgdata/
```

You should have the monitor running.

Check PostgreSQL:

```bash
psql -U postgres -d pg_auto_failover
```

Then:

```sql
SELECT current_database();
```

Expected:

```text
pg_auto_failover
```

Exit:

```sql
\q
```

---

# 10. Configure the Monitor Password

This is important.

`--auth scram-sha-256` does **not** automatically mean the password you put into `.env` has been assigned to `autoctl_node`.

pg_auto_failover documentation explicitly requires setting the password yourself.

Inside the monitor:

```bash
psql -U postgres -d pg_auto_failover
```

Run:

```sql
ALTER ROLE autoctl_node
WITH LOGIN
PASSWORD 'autoctl_node_password';
```

Check:

```sql
SELECT rolname, rolcanlogin
FROM pg_roles
WHERE rolname = 'autoctl_node';
```

Expected:

```text
rolname      | rolcanlogin
-------------+------------
autoctl_node | t
```

Exit:

```sql
\q
```

---

# 11. Create the `.pgpass` Files

We have two different passwords:

```text
autoctl_node
    |
    +-- autoctl_node_password

pgautofailover_replicator
    |
    +-- pg_auto_failover_replication_password
```

They are NOT the same credential.

`PGPASSWORD` only represents one password at a time.

`.pgpass` is the clean solution when multiple PostgreSQL connections require different passwords.

---

# 12. Create pg1 `.pgpass`

Enter pg1:

```bash
docker exec -it pgaf-pg1 bash
```

Create:

```bash
cat > /var/lib/postgresql/.pgpass <<'EOF'
monitor:5432:pg_auto_failover:autoctl_node:autoctl_node_password
pg1:5432:*:pgautofailover_replicator:pg_auto_failover_replication_password
EOF
```

Fix permissions:

```bash
chmod 600 /var/lib/postgresql/.pgpass
```

Check:

```bash
ls -l /var/lib/postgresql/.pgpass
```

Expected:

```text
-rw------- postgres postgres ...
```

---

# 13. Create pg2 `.pgpass`

Enter pg2:

```bash
docker exec -it pgaf-pg2 bash
```

Create:

```bash
cat > /var/lib/postgresql/.pgpass <<'EOF'
monitor:5432:pg_auto_failover:autoctl_node:autoctl_node_password
pg1:5432:*:pgautofailover_replicator:pg_auto_failover_replication_password
EOF
```

Then:

```bash
chmod 600 /var/lib/postgresql/.pgpass
```

---

# 14. IMPORTANT: Configure Replication Password on pg1

This is the part that was missing in the earlier setup.

Enter pg1:

```bash
docker exec -it pgaf-pg1 bash
```

The primary does not exist yet, so first initialize pg1.

---

# 15. Create pg1

Run:

```bash
pg_autoctl create postgres --pgdata /var/lib/postgresql/data/pgdata --pgport 5432 --hostname pg1 --monitor "postgres://autoctl_node@monitor:5432/pg_auto_failover?sslmode=require" --auth scram-sha-256 --ssl-self-signed
```

```````
pg_autoctl run --pgdata /var/lib/postgresql/data/pgdata &
```````

Because `.pgpass` exists, the monitor connection can authenticate as:

```text
autoctl_node
```

without putting the password into the command line.

---

# 16. Configure pg1 Replication Password

After pg1 has been initialized, configure the pg_auto_failover replication password:

```bash
pg_autoctl config set replication.password \
    pg_auto_failover_replication_password
```

This is the password pg_auto_failover uses for the `pgautofailover_replicator` role. The official security documentation describes this configuration step for password-authenticated replication.

Check:

```bash
pg_autoctl config get
```

Do not paste the output into public logs because it may contain credentials depending on your configuration.

---

# 17. Verify pg1

Run:

```bash
pg_autoctl show state \
    --monitor "postgres://autoctl_node@monitor:5432/pg_auto_failover?sslmode=require"
```

Initially you should see something similar to:

```text
Name   | Node | Host:Port | Reported State | Assigned State
-------+------+-----------+----------------+---------------
node_1 | 1    | pg1:5432  | single         | primary
```

The exact state may temporarily differ while initialization completes.

Wait until pg1 is healthy.

---

# 18. Verify the Replication User on pg1

Enter pg1 PostgreSQL:

```bash
psql -U postgres -d postgres
```

Check:

```sql
SELECT rolname,
       rolcanlogin,
       rolreplication
FROM pg_roles
WHERE rolname = 'pgautofailover_replicator';
```

Expected:

```text
rolname                   | rolcanlogin | rolreplication
--------------------------+-------------+---------------
pgautofailover_replicator | t           | t
```

If you need to explicitly reset its password:

```sql
ALTER ROLE pgautofailover_replicator
WITH LOGIN
REPLICATION
PASSWORD 'pg_auto_failover_replication_password';
```

Exit:

```sql
\q
```

---

# 19. Test Replication Authentication BEFORE Creating pg2

This test is extremely important.

Enter pg2:

```bash
docker exec -it pgaf-pg2 bash
```

Run:

```bash
psql \
    -h pg1 \
    -p 5432 \
    -U pgautofailover_replicator \
    -d postgres
```

Because `.pgpass` exists, it should automatically use:

```text
pg_auto_failover_replication_password
```

You should get:

```text
psql (17.x)
Type "help" for help.

postgres=>
```

If you get:

```text
FATAL: password authentication failed
```

STOP.

Do not run `pg_autoctl create postgres` yet.

Fix the replication password first.

---

# 20. Verify pg_hba.conf on pg1

`pg_autoctl --auth scram-sha-256` manages the HBA rules needed for the pg_auto_failover connections.

Inspect:

```bash
psql -U postgres -Atc "SHOW hba_file;"
```

Then:

```bash
cat "$(psql -U postgres -Atc 'SHOW hba_file;')"
```

Look for SCRAM rules that allow pg2 to connect.

For a manually managed application connection, you may additionally need rules such as:

```text
host    all    app    172.30.0.0/16    scram-sha-256
```

Do not blindly replace the HBA file generated by pg_auto_failover.

---

# 21. Create pg2

Make sure pg2's PGDATA is empty.

Check:

```bash
ls -la /var/lib/postgresql/data/pgdata
```

For a new standby it should not contain an existing PostgreSQL cluster.

Then:

```bash
pg_autoctl create postgres \
    --pgdata /var/lib/postgresql/data/pgdata \
    --pgport 5432 \
    --hostname pg2 \
    --monitor "postgres://autoctl_node@monitor:5432/pg_auto_failover?sslmode=require" \
    --auth scram-sha-256 \
    --ssl-self-signed
```

``````bash
pg_autoctl run --pgdata /var/lib/postgresql/monitor/pgdata/ &
``````

At this point pg_auto_failover should:

```text
pg2
 |
 | connect to monitor
 v
monitor
 |
 | monitor says pg1 is primary
 v
pg1
 |
 | pg_basebackup / streaming replication
 v
pg2
```

The pg2 data directory will be initialized from pg1.

---

# 22. If pg2 Says Password Authentication Failed

If you see:

```text
FATAL: password authentication failed for user
"pgautofailover_replicator"
```

do not repeatedly execute:

```bash
pg_autoctl create postgres
```

Instead, test:

```bash
psql \
    -h pg1 \
    -p 5432 \
    -U pgautofailover_replicator \
    -d postgres
```

If this fails, fix:

```text
pg1 role
    +
pg1 password
    +
pg1 pg_hba.conf
    +
pg2 .pgpass
```

Only after that succeeds should you retry pg_auto_failover.

---

# 23. Check Cluster State

From monitor:

```bash
docker exec -it pgaf-monitor bash
```

Run:

```bash
pg_autoctl show state
```

Or:

```bash
pg_autoctl show state \
    --monitor "postgres://autoctl_node@monitor:5432/pg_auto_failover?sslmode=require"
```

The desired final state is approximately:

```text
Name   | Node | Host:Port | Reported State | Assigned State
-------+------+-----------+----------------+---------------
node_1 | 1    | pg1:5432  | primary        | primary
node_2 | 2    | pg2:5432  | secondary      | secondary
```

Exact state names can vary while the nodes are transitioning.

---

# 24. Check pg_autoctl on pg1

```bash
docker exec -it pgaf-pg1 bash
```

Run:

```bash
pg_autoctl show state \
    --monitor "postgres://autoctl_node@monitor:5432/pg_auto_failover?sslmode=require"
```

---

# 25. Check pg_autoctl on pg2

```bash
docker exec -it pgaf-pg2 bash
```

Run:

```bash
pg_autoctl show state \
    --monitor "postgres://autoctl_node@monitor:5432/pg_auto_failover?sslmode=require"
```

---

# 26. Verify Streaming Replication

On pg1:

```bash
psql -U postgres -c "
SELECT
    application_name,
    client_addr,
    state,
    sync_state
FROM pg_stat_replication;
"
```

You should see pg2.

For example:

```text
application_name | client_addr  | state     | sync_state
-----------------+--------------+-----------+-----------
pg2              | 172.30.0.12  | streaming | async
```

---

# 27. Verify pg2 Is a Standby

On pg2:

```bash
psql -U postgres -c "SELECT pg_is_in_recovery();"
```

Expected:

```text
 t
```

This confirms pg2 is currently a standby.

---

# 28. Create an Application Database

On pg1:

```bash
psql -U postgres
```

Create:

```sql
CREATE ROLE app
WITH LOGIN
PASSWORD 'app_password';

CREATE DATABASE appdb
OWNER app;
```

Then:

```sql
\q
```

Because pg1 is the primary, the database creation will be replicated to pg2.

---

# 29. Test Replication

On pg1:

```bash
psql -U postgres -d appdb
```

Create a table:

```sql
CREATE TABLE test (
    id BIGSERIAL PRIMARY KEY,
    message TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);
```

Insert:

```sql
INSERT INTO test(message)
VALUES ('hello from pg1');
```

Exit:

```sql
\q
```

On pg2:

```bash
psql -U postgres -d appdb
```

Run:

```sql
SELECT * FROM test;
```

You should see:

```text
 id |     message     |          created_at
----+-----------------+-------------------------------
  1 | hello from pg1  | ...
```

---

# 30. Test Failover

First check:

```bash
pg_autoctl show state
```

Identify the current primary.

Assuming:

```text
pg1 = primary
pg2 = secondary
```

Stop pg1:

```bash
docker stop pgaf-pg1
```

Wait a few seconds.

From monitor:

```bash
docker exec -it pgaf-monitor bash
```

Run:

```bash
pg_autoctl show state
```

pg2 should eventually be promoted.

Expected conceptually:

```text
pg1 -> demoted / unavailable

pg2 -> primary
```

The exact state transition can take some time.

---

# 31. Check pg2 After Failover

Start pg2 shell:

```bash
docker exec -it pgaf-pg2 bash
```

Run:

```bash
psql -U postgres -c "SELECT pg_is_in_recovery();"
```

Expected after promotion:

```text
 f
```

`false` means pg2 is now writable.

Test:

```bash
psql -U postgres -d appdb
```

Then:

```sql
INSERT INTO test(message)
VALUES ('hello after failover');
```

---

# 32. Restart pg1

Start:

```bash
docker start pgaf-pg1
```

Then inspect:

```bash
pg_autoctl show state
```

pg1 should eventually rejoin as a standby.

The topology should become:

```text
                 monitor
                    |
                    |
             +------+------+
             |             |
             v             v
          pg2 PRIMARY    pg1 STANDBY
```

---

# 33. The Two Passwords You Must Understand

This is the key concept.

## Monitor password

```text
Username:
autoctl_node

Password:
autoctl_node_password
```

Used for:

```text
pg1 -> monitor
pg2 -> monitor
```

Connection:

```text
postgres://autoctl_node@monitor:5432/pg_auto_failover?sslmode=require
```

Password comes from:

```text
.pgpass
```

---

## Replication password

```text
Username:
pgautofailover_replicator

Password:
pg_auto_failover_replication_password
```

Used for:

```text
pg2 -> pg1
```

during initial base backup and subsequent replication.

Password comes from:

```text
.pgpass
```

and pg_auto_failover's replication configuration.

The official pg_auto_failover security documentation explicitly describes the replication password configuration and the use of a password file to avoid putting passwords into commands/environment variables.

---

# 34. Recommended `.pgpass`

For pg1:

```text
monitor:5432:pg_auto_failover:autoctl_node:autoctl_node_password
pg1:5432:*:pgautofailover_replicator:pg_auto_failover_replication_password
```

For pg2:

```text
monitor:5432:pg_auto_failover:autoctl_node:autoctl_node_password
pg1:5432:*:pgautofailover_replicator:pg_auto_failover_replication_password
```

Permissions:

```bash
chmod 600 ~/.pgpass
```

The password file belongs to the `postgres` user.

---

# 35. Why We Do NOT Use Two PGPASSWORD Variables

This is invalid conceptually:

```bash
PGPASSWORD=password1 \
PGPASSWORD=password2 \
pg_autoctl create postgres ...
```

There is only one final `PGPASSWORD` value.

Instead:

```text
.pgpass
    |
    +-- monitor:5432
    |       |
    |       +-- autoctl_node
    |             password A
    |
    +-- pg1:5432
            |
            +-- pgautofailover_replicator
                  password B
```

libpq chooses the appropriate `.pgpass` entry based on:

```text
hostname
port
database
username
```

---

# 36. Troubleshooting: `Address Already in Use`

If you see:

```text
could not bind IPv4 address "0.0.0.0":
Address already in use
```

Check:

```bash
pgrep -a postgres
```

and:

```bash
ss -lntp | grep 5432
```

The usual cause is that Docker's standard PostgreSQL startup already launched PostgreSQL.

Our Compose setup avoids this by using:

```yaml
command: ["sleep", "infinity"]
```

---

# 37. Troubleshooting: `root execution is not permitted`

If you see:

```text
"root" execution of the PostgreSQL server is not permitted.
```

You started pg_autoctl as root.

Check:

```bash
whoami
```

It must be:

```text
postgres
```

The Compose file therefore contains:

```yaml
user: postgres
```

---

# 38. Troubleshooting: `postmaster.pid` Does Not Exist

If you see:

```text
Failed to open file ".../postmaster.pid"
```

followed by:

```text
Postgres is not running
```

check the PostgreSQL startup log:

```bash
cat /var/lib/postgresql/monitor/startup.log
```

or:

```bash
ls /var/lib/postgresql/monitor/log/
```

If you see:

```text
Address already in use
```

another PostgreSQL instance is occupying port 5432.

If you see:

```text
root execution is not permitted
```

pg_autoctl was started as root.

---

# 39. Troubleshooting: `pg_autoctl.state` Missing

If you see:

```text
Failed to open file:

/var/lib/postgresql/.local/share/pg_autoctl/...
/pg_autoctl.state
```

and the node was previously half-created, don't keep retrying indefinitely.

First stop pg_autoctl:

```bash
pkill -f pg_autoctl
```

Then inspect:

```bash
ls -la /var/lib/postgresql/.local/share/pg_autoctl/
```

For a completely fresh pg2, the cleanest reset is to destroy the pg2 Docker volume.

---

# 40. Completely Reset pg2

From the host:

```bash
docker compose stop pg2
```

Then:

```bash
docker compose rm -f pg2
```

Find the volume:

```bash
docker volume ls | grep pg_auto_failover
```

Then remove the pg2 volume.

For example:

```bash
docker volume rm pg_auto_failover_pg2_data
```

Recreate pg2:

```bash
docker compose up -d pg2
```

Enter:

```bash
docker exec -it pgaf-pg2 bash
```

Recreate `.pgpass`:

```bash
cat > ~/.pgpass <<'EOF'
monitor:5432:pg_auto_failover:autoctl_node:autoctl_node_password
pg1:5432:*:pgautofailover_replicator:pg_auto_failover_replication_password
EOF

chmod 600 ~/.pgpass
```

Then retry:

```bash
pg_autoctl create postgres \
    --pgdata /var/lib/postgresql/data/pgdata \
    --pgport 5432 \
    --hostname pg2 \
    --monitor "postgres://autoctl_node@monitor:5432/pg_auto_failover?sslmode=require" \
    --auth scram-sha-256 \
    --ssl-self-signed
```

---

# 41. Completely Reset Everything

For a development/lab environment, the easiest complete reset is:

```bash
docker compose down -v
```

Then:

```bash
docker compose up -d
```

This removes:

```text
monitor data
pg1 data
pg2 data
```

and starts over.

Then repeat:

```text
1. Create monitor
2. Set autoctl_node password
3. Create pg1
4. Set replication password
5. Verify pg1
6. Create .pgpass
7. Test pg1 replication login
8. Create pg2
9. Verify replication
10. Test failover
```

---

# 42. Useful Commands

## Show cluster state

```bash
pg_autoctl show state
```

## Show monitor URI

```bash
pg_autoctl show uri
```

## Show node configuration

```bash
pg_autoctl config show
```

## Check PostgreSQL

```bash
pg_isready -p 5432
```

## Check replication

```bash
psql -U postgres -c \
"SELECT application_name, client_addr, state, sync_state
 FROM pg_stat_replication;"
```

## Check whether standby

```bash
psql -U postgres -c \
"SELECT pg_is_in_recovery();"
```

## Check PostgreSQL port

```bash
ss -lntp | grep 5432
```

---

# 43. Final Validation Checklist

Before considering the cluster ready, verify each item.

## Docker

```text
[ ] monitor container running
[ ] pg1 container running
[ ] pg2 container running
[ ] all containers use postgres user
[ ] Docker DNS resolves monitor/pg1/pg2
```

## Monitor

```text
[ ] monitor PostgreSQL initialized
[ ] monitor listening on 5432
[ ] pg_auto_failover extension installed
[ ] autoctl_node exists
[ ] autoctl_node has SCRAM password
[ ] monitor SSL enabled
```

## pg1

```text
[ ] pg1 PostgreSQL initialized by pg_autoctl
[ ] pg1 registered with monitor
[ ] pg1 is primary
[ ] pgautofailover_replicator exists
[ ] replication password configured
[ ] pg1 SSL enabled
[ ] pg1 HBA allows pg2
```

## pg2

```text
[ ] pg2 PGDATA initially empty
[ ] pg2 .pgpass exists
[ ] pg2 can authenticate to monitor
[ ] pg2 can authenticate to pg1 as pgautofailover_replicator
[ ] pg2 initialized by pg_basebackup
[ ] pg2 registered with monitor
[ ] pg2 is standby
```

## Replication

```text
[ ] pg_stat_replication shows pg2
[ ] pg2 pg_is_in_recovery() = true
[ ] data written on pg1 appears on pg2
```

## Failover

```text
[ ] pg1 stopped
[ ] pg2 promoted
[ ] pg2 becomes writable
[ ] pg1 can rejoin after restart
```

---

# 44. Final Topology

When everything is working:

```text
                          +----------------------+
                          |       MONITOR        |
                          |      PostgreSQL      |
                          |       :5432          |
                          |                      |
                          | pg_auto_failover     |
                          +----------+-----------+
                                     |
                    +----------------+----------------+
                    |                                 |
                    v                                 v
             +-------------+                    +-------------+
             |     PG1     |                    |     PG2     |
             | PostgreSQL  |                    | PostgreSQL  |
             |    :5432    |                    |    :5432    |
             |             |                    |             |
             |  PRIMARY    | === replication => |  STANDBY    |
             +-------------+                    +-------------+
```

After a failure:

```text
                          +----------------------+
                          |       MONITOR        |
                          |      :5432           |
                          +----------+-----------+
                                     |
                                     |
                                     v
                              +-------------+
                              |     PG2     |
                              | PostgreSQL  |
                              |    :5432    |
                              |             |
                              |  PRIMARY    |
                              +-------------+

                              PG1 = DOWN
```

After pg1 returns:

```text
                              +-------------+
                              |     PG2     |
                              |  PRIMARY    |
                              +------+------+
                                     |
                                     | replication
                                     v
                              +-------------+
                              |     PG1     |
                              |  STANDBY    |
                              +-------------+
```

---

# 45. The Golden Rule

When troubleshooting this setup, always separate these three connections:

```text
                    CONNECTION 1
                    -------------
pg1/pg2 ----------> monitor:5432
                    user:
                    autoctl_node
                    password:
                    autoctl_node_password


                    CONNECTION 2
                    -------------
pg2 ----------------> pg1:5432
                      user:
                      pgautofailover_replicator
                      password:
                      pg_auto_failover_replication_password


                    CONNECTION 3
                    -------------
application --------> current primary:5432
                      user:
                      app
                      password:
                      app_password
```

If you remember these three separate authentication paths, most of the errors encountered during this setup become much easier to diagnose.

For production, replace the self-signed SSL certificates with certificates signed by a trusted CA and use a proper secret-management mechanism rather than storing example passwords in `.env` or `.pgpass`.
