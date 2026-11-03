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

cat > /tmp/idds-overrides/idds.cfg <<EOF
[database]
default = ${IDDS_DB_URL}
schema = ${IDDS_DB_SCHEMA}

[main]
# Only the REST service runs in the compose stack; the agent chain
# (clerk, transformer, submitter, ...) is unnecessary for the
# create_workflow_task path, which submits to PanDA synchronously.
agents =

[rest]
host = ${IDDS_REST_HOST}
EOF

# panda.cfg: the image ships /opt/idds/config/panda.cfg pre-existing, so
# start-daemon's "already mounted" check skips generation and
# IDDS_OVERRIDE_PANDA_CONFIGS never applies. Write our config directly
# (the image's default points at the production DOMA server with
# panda_auth = oidc - id-token auth, unusable in the dev stack; pandaclient
# exits 255 fetching a token). insertTaskParams posts to baseURLSSL, so the
# SSL URL must also be plain HTTP: panda-server's compose deployment is
# HTTP-only.
cat > /opt/idds/config/panda.cfg <<EOF
[panda]
panda_auth = None
panda_url = http://panda-server:80/server/panda
panda_url_ssl = http://panda-server:80/server/panda
pandacache_url = http://panda-server:80/server/panda
EOF

# auth override: copy the read-only bind to a writable path so start-daemon's
# merge can consume it (IDDS_OVERRIDE_AUTH_CONFIGS is a space-separated list
# of source files merged over config_default/auth.cfg).
cp /tmp/idds-overrides/auth.cfg.source /tmp/idds-overrides/auth.cfg 2>/dev/null || true
if [ -f /tmp/idds-overrides/auth.cfg ]; then
    export IDDS_OVERRIDE_AUTH_CONFIGS="/tmp/idds-overrides/auth.cfg"
fi

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
      /opt/idds/config/idds/rucio.cfg

# Agent chain suppression: same anonymous-volume persistence would keep the
# agent supervisord programs installed by a previous boot. Remove the agent
# program definitions every boot; the /etc/supervisord.d symlinks to them
# then dangle and supervisord starts only httpd, healthmonitor and
# logrotate. The agent chain must stay off: create_workflow_task submits to
# PanDA synchronously, and running carriers would act on the records the
# handler writes (observed live: the Finisher flipped old processings to
# Broken/Finished within minutes of boot).
rm -f /opt/idds/config/idds/supervisord_idds_clerk.ini \
      /opt/idds/config/idds/supervisord_idds_transformer.ini \
      /opt/idds/config/idds/supervisord_idds_submitter.ini \
      /opt/idds/config/idds/supervisord_idds_poller.ini \
      /opt/idds/config/idds/supervisord_idds_receiver.ini \
      /opt/idds/config/idds/supervisord_idds_trigger.ini \
      /opt/idds/config/idds/supervisord_idds_finisher.ini \
      /opt/idds/config/idds/supervisord_nats.ini

export IDDS_OVERRIDE_IDDS_CONFIGS="/tmp/idds-overrides/idds.cfg"

exec /opt/idds/bin/start-daemon.sh "$@"
