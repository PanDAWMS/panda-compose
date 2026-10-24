#!/usr/bin/env python3
"""Create the iDDS schema in the compose postgres if absent.

The upstream postgresql.sql (main/etc/sql) has drifted from the 2.6.21 ORM:
it predates several tables (throttlers, requests_group, conditions,
wp2transforms) and contains statements with missing semicolons that abort a
plain psql run partway. The ORM metadata is authoritative for the installed
code, so the schema is created from Base.metadata.create_all() and the
alembic chain is stamped at head. Both operations are no-ops when the
schema is already present, so this runs on every container start safely.

The doma_idds schema itself is expected to exist (setup-queue.sh creates it
owned by the panda role, matching how the PanDA schemas are laid out); this
script only refuses to proceed without it.
"""
import sys

from idds.orm.base import models
from idds.orm.base.session import DEFAULT_SCHEMA_NAME, get_engine


def main():
    engine = get_engine()
    with engine.connect() as conn:
        from sqlalchemy import inspect

        insp = inspect(conn)
        if not insp.has_schema(DEFAULT_SCHEMA_NAME):
            sys.exit(
                f'iDDS schema {DEFAULT_SCHEMA_NAME!r} not found; '
                'setup-queue.sh should have created it'
            )
        already = bool(insp.get_table_names(schema=DEFAULT_SCHEMA_NAME))

    models.BASE.metadata.create_all(engine)
    print(f'create_all done (schema already present: {already})')

    # Stamp alembic at head so future `alembic upgrade head` runs are no-ops
    # and operators can inspect the version table.
    # NB: str(engine.url) masks the password as '***'; render_as_string
    # with hide_password=False keeps the real credentials.
    from alembic import command
    from alembic.config import Config

    cfg = Config()
    cfg.set_main_option('script_location', 'idds.orm.base:alembic')
    cfg.set_main_option('sqlalchemy.url', engine.url.render_as_string(hide_password=False))
    cfg.set_main_option('version_table_schema', DEFAULT_SCHEMA_NAME)
    command.stamp(cfg, 'head')
    print('alembic stamped at head')


if __name__ == '__main__':
    main()
