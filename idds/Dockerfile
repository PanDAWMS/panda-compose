# iDDS REST service for the compose stack.
#
# Serves the synchronous workflow_task create path: the REST app records
# requests/transforms/processings in the compose postgres and submits to
# PanDA via panda-client. The upstream HSF/iDDS production image (Oracle
# client, NATS, syslog-ng, conda) is unnecessary for this path; everything
# installs from PyPI at the version matching panda-server's bundled client.
FROM python:3.11-slim

# Pin every idds-* package: idds-doma/idds-client depend on
# idds-workflow>=2.2.0, so leaving it out would float the whole workflow
# package to the latest release. The image patches upstream code via
# exact-string anchors, so a floating dependency set breaks the build
# loudly (assertion) rather than silently - but only if everything is
# pinned. Versions below match the panda-server image's bundled client.
# psycopg[binary] is intentionally absent: idds-server already depends on
# psycopg2-binary and psycopg[binary], and the postgresql:// URL selects
# psycopg2 anyway.
RUN pip install --no-cache-dir \
    "idds-common==2.6.21" \
    "idds-server==2.6.21" \
    "idds-doma==2.6.21" \
    "idds-prompt==2.6.21" \
    "idds-workflow==2.6.21" \
    "idds-client==2.6.21" \
    "panda-client-light==2.1.7" \
    "gunicorn==26.2.0"

# the REST app's controllers write a rotating log via get_logger()
RUN mkdir -p /var/log/idds && chmod 777 /var/log/idds

# Upstream bug (HSF/iDDS as of 2.6.21): the workflow_task REST layer unpacks
# the create_workflow_task return as a 6-tuple, but the prompt handler
# returns a dict (run_id, request_id, transform_id, processing_id,
# input_coll_id, output_coll_id, workload_id) - so every successful create
# raised "too many values to unpack", or with a len()-based workaround,
# returned the dict *keys* instead of the values. Read the dict directly.
#
# The prompt handler swallows *all* PanDA submission exceptions and returns
# workload_id=None, which would surface as HTTP 200 with a null workload_id;
# raise here so callers get a 5xx when no PanDA task was created.
RUN python - <<'EOF'
p = '/usr/local/lib/python3.11/site-packages/idds/rest/v1/workflowtask.py'
src = open(p).read()
old = """            (
                request_id,
                transform_id,
                processing_id,
                input_coll_id,
                output_coll_id,
                workload_id,
            ) = _create_workflow_task(workflow, logger=logger)"""
new = """            _ret = _create_workflow_task(workflow, logger=logger)
            if not isinstance(_ret, dict):
                raise exceptions.CoreException(
                    f'unexpected create_workflow_task return: {_ret!r}')
            if _ret['workload_id'] is None:
                raise exceptions.CoreException(
                    'PanDA task submission failed; see idds_rest.log '
                    '(workload_id is None)')
            run_id = _ret.get('run_id')
            request_id = _ret['request_id']
            transform_id = _ret['transform_id']
            processing_id = _ret['processing_id']
            input_coll_id = _ret['input_coll_id']
            output_coll_id = _ret['output_coll_id']
            workload_id = _ret['workload_id']"""
assert old in src, 'workflowtask.py patch anchor not found'
open(p, 'w').write(src.replace(old, new))
print('patched', p)
EOF

# Also pass the handler's run_id through to the response body.
RUN python - <<'EOF'
p = '/usr/local/lib/python3.11/site-packages/idds/rest/v1/workflowtask.py'
src = open(p).read()
old = """            data={
                'request_id': request_id,"""
new = """            data={
                'run_id': run_id,
                'request_id': request_id,"""
assert old in src, 'response-data patch anchor not found'
open(p, 'w').write(src.replace(old, new))
print('patched', p)
EOF

# Dev identity for client-side x509_proxy validation: ClientManager checks
# that the proxy file exists and parses as a certificate before sending
# anything. Generated at build time; it is a dev identity, not a credential,
# and is only meaningful together with IDDS_DEV_DN on the server.
RUN mkdir -p /etc/idds/auth && \
    openssl req -x509 -newkey rsa:2048 -keyout /tmp/dev_key.pem \
      -out /tmp/dev_cert.pem -days 3650 -nodes \
      -subj "/CN=idds/O=Dev/C=CH" 2>/dev/null && \
    cat /tmp/dev_cert.pem /tmp/dev_key.pem > /etc/idds/auth/dev_proxy.pem && \
    rm -f /tmp/dev_key.pem /tmp/dev_cert.pem

COPY entrypoint.sh /entrypoint.sh
COPY bootstrap.py /bootstrap.py
COPY idds.cfg.template /etc/idds/idds.cfg.template
RUN chmod +x /entrypoint.sh

# Serve the app under the /idds prefix, like upstream's httpd
# (WSGIScriptAlias /idds). All iDDS clients append paths to
# <host>/idds, and gunicorn has no native equivalent.
RUN python - <<'EOF'
p = '/usr/local/lib/python3.11/site-packages/idds/rest/v1/wsgi.py'
open(p, 'w').write('''
# WSGI entry: serve the iDDS app under the /idds prefix, mirroring the
# upstream httpd deployment (WSGIScriptAlias /idds ...).
import os

from idds.rest.v1.app import create_app


class PrefixMiddleware:
    """Strip the /idds prefix, and emulate the trusted-TLS-proxy auth.

    In production httpd terminates TLS and exports the client certificate
    DN as SSL_CLIENT_S_DN in the WSGI environ. The compose stack serves
    plain HTTP, so no TLS layer can do that; instead the deployment sets
    IDDS_DEV_DN, and every caller is authenticated as that identity.

    Consequences of the model (deliberate, dev-stack only):
    - before_request_auth reads the environ first and only falls back to
      the SSL-CLIENT-S-DN header when the environ value is empty, so
      client-supplied DN/cert headers are ignored while IDDS_DEV_DN is
      set - every caller IS the dev identity;
    - the dev identity is a super_user in auth.cfg, so callers may act
      on behalf of other users via X-IDDS-Auth-Username-Original;
    - effectively unauthenticated: the compose service publishes the
      port on loopback only (127.0.0.1), and the variable is unset by
      default - a deployment behind real TLS never sets it.
    """

    def __init__(self, app, prefix='/idds'):
        self.app = app
        self.prefix = prefix
        self.dev_dn = os.environ.get('IDDS_DEV_DN')

    def __call__(self, environ, start_response):
        path = environ.get('PATH_INFO', '')
        if path == self.prefix:
            environ['PATH_INFO'] = '/'
        elif path.startswith(self.prefix + '/'):
            environ['PATH_INFO'] = path[len(self.prefix):]
        if self.dev_dn and 'SSL_CLIENT_S_DN' not in environ:
            environ['SSL_CLIENT_S_DN'] = self.dev_dn
            environ['SSL_CLIENT_CERT'] = 'dev'
        return self.app(environ, start_response)


if 'IDDS_CONFIG' not in os.environ:
    os.environ['IDDS_CONFIG'] = '/etc/idds/idds.cfg'

application = PrefixMiddleware(create_app())
''')
print('wrote', p)
EOF

# 443 mirrors the upstream httpd port; the compose service maps it to a
# host port. gunicorn serves the Flask app directly (no httpd/mod_wsgi).
ENTRYPOINT ["/entrypoint.sh"]
CMD ["gunicorn", "--bind", "0.0.0.0:443", "--workers", "2", "--threads", "4", "idds.rest.v1.wsgi:application"]
