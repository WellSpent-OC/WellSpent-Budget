# Running the sync server for real

Written 2026-09-29, updated 2026-10-10 for readable sync.

## What the server is, and is not

Your budgets sync through WellSpent's server. Connections and backups are
encrypted. The server can read your budgets, which is how it checks who may change
what and how it resets a forgotten password.

It stores every group's budgets, entries and members in a form it can read, and it
decides who may change what. That shapes everything below: a breach of this
server, or of its backups, exposes budgets in full, amounts, merchants and budget
names included, and who shares money with whom. **So the database's disk and its
backups must be encrypted.**

Each device also keeps a full copy of its own groups, so the server is not the only
copy. Until every account has moved off the sealed design from before readable
sync, the server also keeps that design's tables, which a later migration removes.

## Before you put anyone else's data in it

These are not polish. Each one is a real exposure.

| | Status |
|---|---|
| Rate limiting on sign-in, sign-up, invite lookup | **done**, in memory |
| Password floor, 10 characters | **done** |
| Expired tokens purged at boot, then hourly | **done** |
| Auth tokens stored as a hash, not in the clear | **done** |
| Sign-out, so a token can be revoked | **done** |
| The group log needs a token and membership to read | **done** |
| One server sequence per group, enforced by the database | **done** |
| Health check that fails when the database is unreachable | **done** |
| Runs as a non-root user in the container | **done** |
| TLS to clients | **not done here.** Terminate at a proxy or a tunnel. Nothing in this process speaks TLS |
| TLS to Postgres | **read this before setting it.** postgres-kit enforces full certificate verification whenever it uses TLS at all, so `sslmode=prefer` and `require` both fail against a self-signed certificate rather than falling back. On a private network to a Postgres on the same host, `?sslmode=disable` is the honest setting |
| Backups | **not done.** See below. The most important open item |
| Multi-instance safety | **not done.** Rate limits are per process and migrations race at boot |
| Monitoring, alerting | **not done** |

**The rate limiter is in memory.** Correct for one instance, wrong for several:
each keeps its own counters, so three instances means three times the allowance.
Stay single-instance until it moves to Redis.

## Running it

    docker build -t wellspent-server .
    docker run -p 8080:8080 -e DATABASE_URL='postgres://user:pass@host:5432/wellspent' wellspent-server

Locally, with no database at all:

    make serve          # SQLite file, http://127.0.0.1:8080

### Environment

| Variable | Meaning |
|---|---|
| `DATABASE_URL` | Postgres connection string. **Required in production**; the server refuses to start without it rather than guessing localhost |
| `WELLSPENT_SQLITE_PATH` | Development only. Where the SQLite file goes |
| `WELLSPENT_ENVIRONMENT` | `live`, `staging` or `development`. `/health` reports it, and the app checks it before signing in, so a staging build never signs in to the live server or the reverse. Unset, it is `live` in production and `development` otherwise. Any other value stops the server |
| `SKIP_AUTO_MIGRATE` | Set before running more than one instance, then run `WellSpentServer migrate --yes` as a release step. **Not on an empty database:** `configure` still purges expired tokens afterwards, which queries a `tokens` table the skipped migration would have created, so the process dies before `migrate` can run. `--yes` is not optional either, because the command otherwise waits on a confirmation a release machine cannot answer |
| `TRUSTED_PROXY` | Set only when the app really is behind a proxy you control, and then always set it. Behind one, every request arrives from the proxy, so without this the rate limiter has a single shared bucket and ten failed sign-ins from anywhere locks out everybody. With it, the caller is read from `CF-Connecting-IP` or `Fly-Client-IP`, or failing those the **last** `X-Forwarded-For` hop, because both proxies append what they saw and the first hop is whatever the client typed |
| `EMAIL_CODE_KEY` | 32 bytes in base64 (`openssl rand -base64 32`). The secret emailed codes are hashed under. **Required in production**; development and tests use a public key. Changing it voids codes already sent, nothing else |
| `RESEND_API_KEY` | A **sending-only** key from Resend. **Required on a live production server**, which refuses to start without one; a server with `WELLSPENT_ENVIRONMENT=staging` writes codes to its log instead, because staging has no internet access. Whoever can read Resend's sent mail can read every code |
| `MAIL_FROM` | Optional. Defaults to `WellSpent <no-reply@wellspent.space>`, which must be on a domain verified in Resend |

## Where to host it

**The project's own server is self-hosted, at `sync.wellspent.space`.** Its operating
notes are kept privately. The options below suit anyone running their own copy.

Any of these work. The server is one container and one Postgres.

**Fly.io.** Closest fit: a `fly.toml`, `fly launch`, `fly postgres create`, and
TLS terminates at their edge with no work. Roughly $5 to $15 a month for a small
instance plus a small database.

**Railway or Render.** Both take a Dockerfile and a managed Postgres, with TLS
handled. Comparable money, slightly less control.

**A VPS (Hetzner, DigitalOcean).** Cheapest at scale and the most work: you run
Postgres, Caddy or nginx for TLS, backups, and updates yourself. From about $5 a
month. Worth it only if you want the control.

Recommendation: **Fly.io to start.** The reasons that matter here are TLS without
configuration, a managed Postgres with point-in-time recovery, and a single
instance being the normal case rather than something to fight.

## The thing to get right before anything else

**Backups, tested by restoring one.**

The server holds every budget. If Postgres is lost and the backups do not restore,
anyone who has also lost their devices has lost their budgets for good. The backups
hold the same budgets in full, so they need the same care as the database:
encrypted, and kept where only the people running the server can reach them.

Managed Postgres with point-in-time recovery covers this, but only if a restore
has actually been performed once. An untested backup is a belief, not a backup.

## Deploying, step by step

1. `docker build -t wellspent-server .` and check it starts locally.
2. Create the Postgres instance. Note the connection string.
3. Set `DATABASE_URL`. Deploy. Migrations run at boot on a single instance.
4. Check `GET /health` answers `{"status":"ok","environment":"live"}`, or the
   environment you set in `WELLSPENT_ENVIRONMENT`.
5. Sign up a throwaway account and run one sync from the Mac app against it.
6. **Take a backup and restore it into a scratch database.** Do this before the
   first real account, not after.
7. Point the Mac app at it: the sign-in sheet has a Server field, which starts
   at `https://sync.wellspent.space` in the live app and at
   `https://staging.wellspent.space` in WellSpent Staging. Each refuses the other's
   server. For a local server, type `http://127.0.0.1:8080` into WellSpent Staging,
   which `make run` builds. The live app refuses a development server.

### Upgrading a server that already holds data

Back up first, and check the backup restores. Migrations run at boot, and each
one is recorded as done only after it finishes.

`AddGroupMaxLamport` adds `groups.max_lamport` and fills it, in one transaction,
and adds the column only when it is not already there. So a start cut short
during it is safe to start again. If a server built before that change ever
loops at boot on `column "max_lamport" of relation "groups" already exists`,
first check that the migration is not recorded as done:
`SELECT name FROM _fluent_migrations WHERE name LIKE '%AddGroupMaxLamport%';`
must return no row. Only then is the recovery this one line, after which the next
start adds and fills it again. Run once the migration is recorded, it removes a
column every group request needs.

```sql
ALTER TABLE groups DROP COLUMN max_lamport;
```

## What is verified, and what is not

CI builds this image on Linux and checks the container starts and answers its
health check on every pull request, so a change that breaks the Linux build fails
before it merges.

CI also runs the server's own 32 tests against a real Postgres 17 on every pull
request, so the migrations, the unique constraints and a real connection pool are
exercised on the driver production uses.

**Still not verified:** the production boot path itself. The container smoke test
runs `serve --env development` with a SQLite path, so `--env production` with a
`DATABASE_URL` has never run anywhere. The integration tests are also SQLite
only, because they share a database with the unit suite and both register the
same email addresses.
