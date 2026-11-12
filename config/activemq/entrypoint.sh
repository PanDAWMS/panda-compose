#!/bin/sh
# Entrypoint shim for the compose activemq service: renders the web console
# realm from ACTIVEMQ_CONSOLE_USER / ACTIVEMQ_CONSOLE_PASSWORD, then execs
# the image's own run-activemq-services - which copies everything from
# ACTIVEMQ_EXTRA_CONF (/data/activemq) into the conf dir at every start, so
# a realm rendered here is picked up without patching the image.
set -e

CONF_DIR="${ACTIVEMQ_EXTRA_CONF:-/data/activemq}"
mkdir -p "$CONF_DIR"
# jetty HashLoginService realm format: username: password [,rolename ...]
printf '%s: %s, admin\n' "$ACTIVEMQ_CONSOLE_USER" "$ACTIVEMQ_CONSOLE_PASSWORD" > "$CONF_DIR/jetty-realm.properties"

exec /opt/activemq/bin/run-activemq-services "$@"
