# syntax=docker/dockerfile:1
#
# grid-backup-image — generic tooling for Postgres backup jobs:
#   pg_dump / pg_dumpall / psql 17 (from the base), plus age, rclone, curl, jq.
#
# It deliberately contains NO scripts and NO credentials. A job mounts its script (from a
# ConfigMap, say) and its credentials (as Secret files) at run time, so this image is the same
# generic toolbox for every job and is safe to publish.
#
# The base is pinned by the multi-arch INDEX digest of postgres:17-trixie (17.11; the index
# carries linux/amd64 and linux/arm64/v8, read 2026-09-30). pg_dump must be at least the
# server's major version, so this image dumps servers up to 17.
FROM postgres:17-trixie@sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f

# Pinned by UPSTREAM version and ASSERTED, never by Debian revision. A security update retires
# an old revision from the archive, and a revision pin would then break the build for nothing;
# a new upstream version breaks it on purpose, so that someone reads the changelog first.
# NAMED WANT_*, NOT RCLONE_*: rclone reads every RCLONE_<FLAG> environment variable as a flag,
# and a build ARG is in the RUN environment. `ARG RCLONE_VERSION` became `--version=1.60.1` and
# broke this very step (2026-09-30). PG_MAJOR is the base image's own ENV; left alone.
ARG WANT_AGE=1.2.1
ARG WANT_RCLONE=1.60.1
ARG WANT_PG_MAJOR=17
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends age rclone curl jq ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    case "$(age --version)" in "${WANT_AGE}"|"v${WANT_AGE}") ;; *) echo "age is not ${WANT_AGE}"; exit 1;; esac; \
    rclone version | head -1 | sed 's/-DEV$//' | grep -qxF "rclone v${WANT_RCLONE}"; \
    pg_dump --version | grep -q "^pg_dump (PostgreSQL) ${WANT_PG_MAJOR}\."; \
    jq --version; curl --version | head -1

# The postgres image's entrypoint initialises and starts a server. This image never runs one.
ENTRYPOINT []
# A numeric non-root user, so Pod Security `restricted` (runAsNonRoot) can verify it.
USER 65532:65532
WORKDIR /tmp
CMD ["bash"]

LABEL org.opencontainers.image.source="https://github.com/nerdoutcj/grid-backup-image" \
      org.opencontainers.image.description="Postgres backup tooling: pg_dump 17, age, rclone, curl, jq. No scripts, no credentials."
