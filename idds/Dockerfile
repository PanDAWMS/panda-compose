# iDDS REST service for the compose stack, on the official image.
#
# The upstream ghcr.io/hsf/idds image provides everything the service needs:
# httpd + WSGI under the /idds prefix, config generation from environment
# (start-daemon.sh merging config defaults with IDDS_OVERRIDE_*_CONFIGS
# sources), and database bootstrap (create_database.py + alembic upgrade).
# This layer only patches the remaining upstream bugs in the
# create_workflow_task path and wraps the wsgi entry for the dev-stack
# auth model.
FROM ghcr.io/hsf/idds:latest

USER root

# Upstream bug (HSF/iDDS as of 2.6.22): the workflow_task REST layer unpacks
# the create_workflow_task return as a 6-tuple, but the prompt handler
# returns a dict (run_id, request_id, transform_id, processing_id,
# input_coll_id, output_coll_id, workload_id) - so every successful create
# raises ValueError. Read the dict directly. (The transform-naming collision
# was fixed upstream in 2.6.22 via the fast_processing flag.)
#
# The prompt handler also swallows *all* PanDA submission exceptions
# (workflowtaskhandler.py: create_workflow_task's try/except around
# PandaClient().submit()) and returns workload_id=None, which upstream
# surfaces as HTTP 200 with workload_id: null. Raise (5xx, InternalError)
# when the submission failed so callers see the failure - the iDDS
# request/transform/processing rows are already committed at that point, so
# the ids are included in the message for correlation/cleanup and retries
# must go through the run_id mapping (see docs/architecture.md, "Create is
# not idempotent").
RUN /opt/idds/bin/python - <<'EOF'
p = '/opt/idds/lib/python3.11/site-packages/idds/rest/v1/workflowtask.py'
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
                    f"PanDA task submission failed "
                    f"(request_id={_ret['request_id']}, "
                    f"transform_id={_ret['transform_id']}); "
                    f"see idds_rest.log. The iDDS records above are "
                    f"already committed; retrying will duplicate them.")
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

# pass run_id through to the response body (handler returns it; upstream drops it)
RUN /opt/idds/bin/python - <<'EOF'
p = '/opt/idds/lib/python3.11/site-packages/idds/rest/v1/workflowtask.py'
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

# Dev-stack auth: the compose stack serves plain HTTP (no TLS), so no client
# certificate DN ever reaches the WSGI environ, and the app's x509 auth
# rejects every request ("User DN cannot be found"). In production httpd
# terminates TLS and exports the DN as SSL_CLIENT_S_DN via GridSiteEnvs;
# here the deployment sets IDDS_DEV_DN and this wrapper injects it as the
# client DN for every request - the trusted-proxy model. Access is still
# governed by auth.cfg (allow_users); the variable is unset by default, so
# a real TLS deployment never sets it and the header/env path applies again.
#
# Consequences of the model (deliberate, dev-stack only):
# - client-supplied DN env/headers are ignored while IDDS_DEV_DN is set;
# - the dev identity is a super_user in auth.cfg, so callers may act on
#   behalf of other users via X-IDDS-Auth-Username-Original;
# - effectively unauthenticated: the compose service publishes the port
#   on loopback only.
RUN /opt/idds/bin/python - <<'EOF'
p = '/opt/idds/bin/idds.wsgi'
src = open(p).read()
old = """from idds.rest.v1.app import create_app  # noqa: E402


application = create_app()"""
new = """from idds.rest.v1.app import create_app  # noqa: E402


class DevDNMiddleware:
    \"\"\"Inject IDDS_DEV_DN as the client DN (plain-HTTP dev stacks).\"\"\"

    def __init__(self, app):
        self.app = app
        self.dev_dn = os.environ.get('IDDS_DEV_DN')

    def __call__(self, environ, start_response):
        if self.dev_dn and 'SSL_CLIENT_S_DN' not in environ:
            environ['SSL_CLIENT_S_DN'] = self.dev_dn
            environ['SSL_CLIENT_CERT'] = 'dev'
        return self.app(environ, start_response)


application = DevDNMiddleware(create_app())"""
assert old in src, 'idds.wsgi patch anchor not found'
open(p, 'w').write(src.replace(old, new))
print('patched', p)
EOF

COPY entrypoint.sh /opt/idds/bin/compose-entrypoint.sh
RUN chmod +x /opt/idds/bin/compose-entrypoint.sh

# The image's start-daemon.sh (config merge, DB bootstrap, supervisord with
# httpd on 8080/8443) remains the entrypoint; the shim execs it after
# rendering the compose environment into config-override sources.
ENTRYPOINT ["/opt/idds/bin/compose-entrypoint.sh"]
CMD ["all"]
