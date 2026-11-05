#!/bin/sh
# Entrypoint shim for the compose idds service on the official ghcr.io/hsf/idds
# image. Renders the config override from the environment (compose
# interpolation cannot reach inside mounted files), stages the repo auth.cfg
# as an override source, then execs the image's own start-daemon.sh - which
# merges config defaults + overrides into /opt/idds/config/idds/*.cfg,
# bootstraps the database (create_database.py: schema-tolerant ORM create_all
# + alembic stamp, then `alembic upgrade heads`) and starts supervisord with
# httpd serving the /idds WSGI app on 8080 (plain HTTP) and 8443 (TLS).
set -e

mkdir -p /tmp/idds-overrides

# Render the idds.cfg override from the environment. The value passes
# through TWO interpolating ConfigParser boundaries: this file is read by
# start-daemon's merge_idds_configs.py (which both reads and writes with
# interpolation), and the merged output is later read by iDDS's own
# ConfigParser. A literal % must therefore be written as %%%% to survive
# both stages - verified empirically: bare % makes the merge skip the whole
# override file (WARNING, silent sqlite fallback), and %% fails the merge's
# write leaving the default value in place.
escape_pct() {
    # % -> %%%% (both interpolation boundaries)
    printf '%s' "$1" | sed 's/%/%%%%/g'
}

cat > /tmp/idds-overrides/idds.cfg <<EOF
[database]
default = $(escape_pct "${IDDS_DB_URL}")
schema = $(escape_pct "${IDDS_DB_SCHEMA}")

[rest]
host = $(escape_pct "${IDDS_REST_HOST}")
EOF

# panda.cfg: write our config directly. The image's default (copied to
# /opt/idds/config/panda.cfg by start-daemon on the first boot; on a
# fresh volume the file does not exist until then) points at the
# production DOMA server with panda_auth = oidc - id-token auth,
# unusable in the dev stack (pandaclient exits 255 fetching a token),
# and IDDS_OVERRIDE_PANDA_CONFIGS cannot fix it because the file's
# "already mounted" check skips regeneration once a previous boot
# created it. insertTaskParams posts to baseURLSSL, so the SSL URL must
# also be plain HTTP: panda-server's compose deployment is HTTP-only.
# This file is written by us and read only by iDDS's ConfigParser (no
# merge step), so a literal % needs the single %% escape.
PCT_ESCAPED_PANDA_URL=$(printf '%s' "${PANDA_URL:-http://panda-server:80/server/panda}" | sed 's/%/%%/g')
cat > /opt/idds/config/panda.cfg <<EOF
[panda]
panda_auth = None
panda_url = ${PCT_ESCAPED_PANDA_URL}
panda_url_ssl = ${PCT_ESCAPED_PANDA_URL}
pandacache_url = ${PCT_ESCAPED_PANDA_URL}
EOF

# auth override: copy the read-only bind to a writable path so start-daemon's
# merge can consume it (IDDS_OVERRIDE_AUTH_CONFIGS is a space-separated list
# of source files merged over config_default/auth.cfg). The bind mount is
# part of the compose service definition - a missing file is a deployment
# error, not something to run without.
AUTH_SOURCE=/tmp/idds-overrides/auth.cfg.source
if [ ! -f "$AUTH_SOURCE" ]; then
    echo "FATAL: $AUTH_SOURCE missing - the idds/auth.cfg bind mount is not present." >&2
    exit 1
fi
cp "$AUTH_SOURCE" /tmp/idds-overrides/auth.cfg
export IDDS_OVERRIDE_AUTH_CONFIGS="/tmp/idds-overrides/auth.cfg"

# Config freshness: the image declares VOLUME /opt/idds/config, and
# start-daemon.sh skips generating any config that already exists
# ("already mounted"). Compose keeps the anonymous volume across container
# recreations, so after the first up the generated idds.cfg/auth.cfg stay
# frozen and changes to IDDS_DB_URL, IDDS_REST_HOST or the repo's
# idds/auth.cfg would be silently ignored. Delete the generated configs
# every boot so start-daemon re-merges them from config_default + the
# overrides rendered above. (panda.cfg is written directly by this shim, so
# it is not in the list; supervisord_idds.ini is the read-only guard bind.)
rm -f /opt/idds/config/idds/idds.cfg \
      /opt/idds/config/idds/auth.cfg \
      /opt/idds/config/idds/alembic.ini \
      /opt/idds/config/idds/gacl \
      /opt/idds/config/rucio.cfg

# Agent chain suppression. The [main] agents = setting has no effect on
# the carrier programs: each supervisord agent program sets IDDS_AGENTS
# in its environment, and load_config_agents() reads that before the
# config. What actually disables the chain is the guard bind
# (supervisord_idds.ini - see that file) plus removing the agent
# program definitions here, so their /etc/supervisord.d symlinks dangle
# and supervisord starts only the programs restored below. The agent
# chain must stay off: create_workflow_task submits to PanDA
# synchronously, and running carriers would act on the records the
# handler writes (observed live: the Finisher flipped old processings to
# Broken/Finished within minutes of boot).
rm -f /opt/idds/config/idds/supervisord_idds_clerk.ini \
      /opt/idds/config/idds/supervisord_idds_transformer.ini \
      /opt/idds/config/idds/supervisord_idds_submitter.ini \
      /opt/idds/config/idds/supervisord_idds_poller.ini \
      /opt/idds/config/idds/supervisord_idds_receiver.ini \
      /opt/idds/config/idds/supervisord_idds_trigger.ini \
      /opt/idds/config/idds/supervisord_idds_finisher.ini

# Restore the programs this stack DOES need. start-daemon copies these from
# config_default only inside the same branch the guard file suppresses, so
# on a fresh /opt/idds/config volume they would be missing - and the image's
# /etc/supervisord.d symlinks point into this directory, so without
# supervisord_httpd.ini supervisord starts no httpd at all and the container
# sits unhealthy forever (restart: unless-stopped does not restart unhealthy
# containers). Copy them explicitly, every boot.
for f in supervisord_httpd.ini \
         supervisord_logrotate.ini \
         supervisord_healthmonitor.ini \
         logrotate_idds \
         logrotate_daemon \
         healthmonitor_daemon \
         idds_health_check.py; do
    rm -f "/opt/idds/config/idds/$f"
    cp "/opt/idds/config_default/$f" "/opt/idds/config/idds/$f"
done
chmod +x /opt/idds/config/idds/logrotate_daemon \
         /opt/idds/config/idds/healthmonitor_daemon \
         /opt/idds/config/idds/idds_health_check.py

# The httpd vhosts run at LogLevel debug and write httpd_error_log /
# httpd_access_log (no .log suffix) directly into the /var/log/idds volume.
# The stock logrotate_idds pattern only matches /var/log/idds/*.log, so
# those two files would grow without limit even with the logrotate program
# running. /etc/logrotate.d/idds symlinks into this volume, so extending
# the pattern here covers them.
#
# Both stanzas need `su root root`: the image chmods /var/log/idds to 0777
# (so the apache user can write), and logrotate refuses to rotate logs in
# world-writable directories without it - without the directive, the stock
# stanza fails the same way (pre-existing upstream: logrotate.log fills
# with "skipping ... insecure permissions"). copytruncate because httpd
# and supervisord hold the fds open.
cat > /opt/idds/config/idds/logrotate_idds <<'EOF'
/var/log/idds/*.log
/var/log/idds/httpd_error_log /var/log/idds/httpd_access_log {
    su root root
    daily
    missingok
    rotate 3
    size 2G
    compress
    delaycompress
    copytruncate
}
EOF

export IDDS_OVERRIDE_IDDS_CONFIGS="/tmp/idds-overrides/idds.cfg"

# Pre-merge validation: merge_idds_configs.py swallows per-source errors
# with a WARNING ("Skipping config file ... due to error") and carries on
# with upstream defaults - which for this service means sqlite, every
# agent enabled, and a rest host of https://localhost:443/idds, with
# nothing failing at startup. Run the same merge the daemon will run and
# verify our values survived; abort loudly if not.
python3 /opt/idds/tools/env/merge_idds_configs.py \
    -s /opt/idds/config_default/idds.cfg "$IDDS_OVERRIDE_IDDS_CONFIGS" \
    -d /tmp/idds-overrides/idds.merged.cfg 2>&1 | tee /tmp/idds-overrides/merge.log
if grep -q "Skipping config file" /tmp/idds-overrides/merge.log; then
    echo "FATAL: an idds config override was rejected by the merge (see above). Refusing to start with upstream defaults." >&2
    exit 1
fi
python3 /opt/idds/tools/env/merge_idds_configs.py \
    -s /opt/idds/config_default/auth.cfg "$IDDS_OVERRIDE_AUTH_CONFIGS" \
    -d /tmp/idds-overrides/auth.merged.cfg 2>&1 | tee /tmp/idds-overrides/auth-merge.log
if grep -q "Skipping config file" /tmp/idds-overrides/auth-merge.log; then
    echo "FATAL: the auth config override was rejected by the merge (see above). Refusing to start with upstream defaults." >&2
    exit 1
fi
# Spot-check the values that must not silently fall back.
python3 - <<'PYEOF'
import configparser, os, sys

def check(path, section, option, expected, what):
    c = configparser.ConfigParser()
    c.read(path)
    try:
        got = c.get(section, option)
    except Exception as exc:
        print(f"FATAL: {what}: cannot read [{section}] {option}: {exc}", file=sys.stderr)
        sys.exit(1)
    if got != expected:
        print(f"FATAL: {what}: [{section}] {option} is {got!r}, expected {expected!r}", file=sys.stderr)
        sys.exit(1)

db_url = os.environ["IDDS_DB_URL"]
check("/tmp/idds-overrides/idds.merged.cfg", "database", "default", db_url, "idds override")
check("/tmp/idds-overrides/idds.merged.cfg", "database", "schema", os.environ.get("IDDS_DB_SCHEMA", "doma_idds"), "idds override")

src = configparser.ConfigParser()
src.read("/tmp/idds-overrides/auth.cfg")
expected_allow = src.get("Users", "allow_users")
check("/tmp/idds-overrides/auth.merged.cfg", "Users", "allow_users", expected_allow, "auth override")
print("config pre-merge validation OK")
PYEOF

exec /opt/idds/bin/start-daemon.sh "$@"
