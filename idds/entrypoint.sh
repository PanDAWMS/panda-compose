#!/bin/sh
# iDDS REST service entrypoint: render idds.cfg from the environment, then
# bootstrap the doma_idds schema if absent (idempotent), then exec CMD.
# Config rendering must come first: the idds ORM reads IDDS_CONFIG at import
# time, so the bootstrap script cannot import it before the file exists.
set -e

# idds.core reads its config from IDDS_CONFIG (the app imports it at
# startup, so it must exist before anything imports idds).
python - <<'EOF'
import os

tpl = open('/etc/idds/idds.cfg.template').read()
vals = {
    'IDDS_DB_URL': os.environ.get('IDDS_DB_URL', ''),
    'IDDS_DB_SCHEMA': os.environ.get('IDDS_DB_SCHEMA', 'doma_idds'),
    'IDDS_REST_HOST': os.environ.get('IDDS_REST_HOST', 'http://idds:443/idds'),
    'IDDS_LOG_LEVEL': os.environ.get('IDDS_LOG_LEVEL', 'INFO'),
}
for key, val in vals.items():
    # iDS reads the rendered file with configparser, which applies
    # BasicInterpolation: a literal % (e.g. a URL-encoded password) must be
    # doubled or ConfigParser raises InterpolationSyntaxError at import.
    tpl = tpl.replace('${%s}' % key, val.replace('%', '%%'))
if '${' in tpl:
    # any unresolved placeholder means misconfiguration, fail loudly
    import re
    left = sorted(set(re.findall(r'\$\{([A-Z_]+)\}', tpl)))
    raise SystemExit('unresolved template placeholders: %s' % ', '.join(left))
open('/etc/idds/idds.cfg', 'w').write(tpl)
EOF

python /bootstrap.py

exec "$@"
