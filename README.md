# grid-backup-image

A tool image for Postgres backup jobs: **pg_dump / pg_dumpall / psql 17, age, rclone, curl and
jq** on `postgres:17-trixie`, for `linux/amd64` and `linux/arm64`.

It holds **no scripts and no credentials**. A job mounts its script and its credentials at run
time (a ConfigMap and Secret files, say), so this image is a generic toolbox and is safe to
publish. It is public so it can be pulled without a registry credential.

| Tool | Version | Pinned how |
|---|---|---|
| base | `postgres:17-trixie` (17.11) | multi-arch index digest, in the `Dockerfile` |
| age | 1.2.1 | Debian package, **upstream version asserted** at build time |
| rclone | 1.60.1 | Debian package, upstream version asserted |
| pg_dump | 17.x | from the base; major version asserted |
| curl, jq | Debian trixie | — |

Versions are asserted by upstream version, never by Debian revision: a security update retires
old revisions from the archive, and a revision pin would break the build for nothing. A new
upstream version breaks it on purpose, so that someone reads the changelog first.

The image runs as uid 65532 with no entrypoint. `ENTRYPOINT []` replaces the postgres image's
entrypoint, which would otherwise initialise and start a database server.

## How it is built and proven

`.github/workflows/image.yml`, on every push to `main`:

1. Each architecture is built on a **native** runner and pushed by digest only (untagged).
2. `test/smoke.sh` runs against that exact digest, under a pod's constraints (uid 65532,
   read-only root, no capabilities). It runs a live `pg_dump` through a `.pgpass` file and a
   read-only role, then `age` to two recipients. Both identities must decrypt the result and a
   stranger's must not; `pg_restore` must read it; `rclone` and `curl -K` must work.
3. Only if both smoke tests pass is the multi-arch index created and tagged `:<commit sha>`.
   The run summary prints the index digest to pin.
   Every GitHub Action is pinned by full commit SHA: the image reads databases in plaintext
   before it encrypts them, so a moved tag must not be able to run code in its build.
4. The `public` job proves an anonymous client can pull that digest, with a control showing
   the same procedure returns something other than 200 for a package that does not exist.

**Pin the index digest from a green run's summary, and cite the run.** Nothing else is a pin:
not a tag, and not a digest looked up later.

A new GHCR package starts **private**, so the first run's `public` job fails. Change the
package's visibility to public in its settings, then re-run that job.

Run the smoke test locally:

```sh
docker build -t grid-backup-image:local .
test/smoke.sh grid-backup-image:local "$(uname -m)"
```
