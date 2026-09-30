#!/usr/bin/env bash
# test/smoke.sh IMAGE ARCH — the image does what a Postgres backup job needs, on THIS machine's
# architecture, under the pod's constraints: uid 65532, read-only root, no capabilities, no
# privilege escalation, a memory-backed /work.
#
# Run by .github/workflows/image.yml against each pushed per-architecture digest, on a NATIVE
# runner (ARCH is x86_64 or aarch64, and must equal the host's). Locally:
#   test/smoke.sh grid-backup-image:local x86_64
#
# What it proves: the tools start and are the pinned upstream versions; a live pg_dump from a
# Postgres 17 server, through a .pgpass file and a read-only role, pipes into age for TWO
# recipients; both identities decrypt it, a stranger's does not; pg_restore reads the result;
# rclone copies a file intact. Everything happens INSIDE one container run, so no plaintext
# leaves it. What it does not prove: object-storage behaviour, which belongs to the consuming
# job's own tests. Needs Docker. Leaves nothing behind.
set -uo pipefail
IMG=${1:?usage: test/smoke.sh IMAGE ARCH}; WANT=${2:?usage: test/smoke.sh IMAGE ARCH}
# Pinned by digest: this container runs inside the build jobs, like the actions (see the
# workflow's header). The tag is kept for the reader; Docker pulls by the digest.
PG=postgres:17.11@sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f
P=smoke$$; NET=$P-net
cleanup() { docker rm -f "$P-pg" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
trap cleanup EXIT
pass=0; fail=0
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $d"; pass=$((pass + 1)); else echo "FAIL  $d"; fail=$((fail + 1)); fi; }
pod() { docker run --rm --network "$NET" --read-only --tmpfs /work:rw,mode=1777 --user 65532:65532 \
          --cap-drop ALL --security-opt no-new-privileges -e HOME=/work -e TMPDIR=/work -w /work "$@"; }

[[ $(uname -m) == "$WANT" ]] || { echo "FAIL  this host is $(uname -m), not $WANT: the proof must run natively"; exit 1; }
docker network create --internal "$NET" >/dev/null
docker run -d --name "$P-pg" --network "$NET" --network-alias pg.test -e POSTGRES_PASSWORD=smoke "$PG" >/dev/null
for _ in $(seq 1 60); do docker exec "$P-pg" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && break; sleep 1; done
docker exec -i "$P-pg" psql -X -q -v ON_ERROR_STOP=1 -U postgres <<'EOF' >/dev/null
CREATE ROLE backup_reader LOGIN PASSWORD 'smoke-only-password';
GRANT pg_read_all_data TO backup_reader;
ALTER ROLE backup_reader SET default_transaction_read_only = on;
CREATE TABLE smoke_rows AS SELECT g AS id, md5(g::text) AS v FROM generate_series(1, 1000) g;
EOF

check "the image's machine is $WANT" test "$(pod "$IMG" uname -m)" = "$WANT"
check "the image's default user is 65532" test "$(docker run --rm --network none "$IMG" id -u)" = 65532
# jq, not a Go template: with ENTRYPOINT [] Docker OMITS the key, and `{{.Config.Entrypoint}}`
# then errors on a correct image.
check "the image has no entrypoint" bash -c "[[ \$(docker image inspect '$IMG' | jq -c '.[0].Config.Entrypoint') =~ ^(null|\[\])$ ]]"
check "age is 1.2.1" bash -c "[[ \$(docker run --rm --network none '$IMG' age --version) =~ ^v?1\.2\.1$ ]]"
check "rclone is v1.60.1" bash -c "docker run --rm --network none '$IMG' rclone version | head -1 | grep -Eq '^rclone v1\.60\.1(-DEV)?$'"
check "pg_dump is 17" bash -c "docker run --rm --network none '$IMG' pg_dump --version | grep -q '^pg_dump (PostgreSQL) 17\.'"
check "jq and curl run" docker run --rm --network none "$IMG" bash -c 'jq --version && curl --version'

out=$(pod "$IMG" bash -c '
  set -u
  printf "pg.test:5432:*:backup_reader:smoke-only-password\n" > .pgpass; chmod 600 .pgpass
  export PGPASSFILE=/work/.pgpass PGUSER=backup_reader
  for k in one two stranger; do age-keygen -o "$k.key" 2>/dev/null; done
  rcpt1=$(age-keygen -y one.key); rcpt2=$(age-keygen -y two.key)
  pg_dump -h pg.test -d postgres -Fc | age -r "$rcpt1" -r "$rcpt2" > dump.age
  echo "PIPE ${PIPESTATUS[0]} ${PIPESTATUS[1]}"
  head -c 21 dump.age | grep -q "^age-encryption.org/v1" && echo "HEADER ok"
  age -d -i one.key dump.age | pg_restore --list | grep -q "TABLE DATA public smoke_rows" && echo "ONE ok"
  age -d -i two.key dump.age | head -c 5 | grep -q PGDMP && echo "TWO ok"
  age -d -i stranger.key dump.age > /dev/null 2>&1 || echo "STRANGER refused"
  mkdir -p copy; rclone copyto dump.age copy/dump.age 2>/dev/null
  [ "$(sha256sum < dump.age)" = "$(sha256sum < copy/dump.age)" ] && echo "RCLONE ok"
  printf "url = \"file:///work/copy/dump.age\"\n" > c.cfg; curl -fsS -K c.cfg -o fetched.age && cmp -s dump.age fetched.age && echo "CURL ok"
' 2>&1)
check "pg_dump | age: both stages exit 0" grep -qx 'PIPE 0 0' <<<"$out"
check "the output is age ciphertext" grep -qx 'HEADER ok' <<<"$out"
check "recipient one decrypts, and pg_restore reads the table" grep -qx 'ONE ok' <<<"$out"
check "recipient two decrypts" grep -qx 'TWO ok' <<<"$out"
check "control: a stranger's identity is refused" grep -qx 'STRANGER refused' <<<"$out"
check "rclone copies it intact" grep -qx 'RCLONE ok' <<<"$out"
check "curl reads its URL from a config file (-K), as the job does" grep -qx 'CURL ok' <<<"$out"
echo "== $pass passed, $fail failed"
(( fail == 0 ))
