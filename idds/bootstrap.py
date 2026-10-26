#!/usr/bin/env python3
"""Create or upgrade the iDDS schema in the compose postgres.

The upstream postgresql.sql (main/etc/sql) has drifted from the 2.6.21 ORM:
it predates several tables (throttlers, requests_group, conditions,
wp2transforms) and contains statements with missing semicolons that abort a
plain psql run partway. The ORM metadata is authoritative for the installed
code, so on a fresh schema the tables are created from
Base.metadata.create_all() and the alembic chain is stamped at head.

On an existing schema, create_all() alone cannot apply structural changes
from newer idds-* releases (it only creates *missing* tables, never alters
existing ones), and stamping head again would mark new migrations as
applied and silently drift the schema from the ORM. So an existing schema
is brought forward with `alembic upgrade head` instead: migrations record
their version in the version table, and upgrade only applies what is
missing.

The doma_idds schema itself is expected to exist (setup-queue.sh creates it
owned by the panda role, matching how the PanDA schemas are laid out); this
script only refuses to proceed without it.
"""
import sys

from idds.orm.base import models
from idds.orm.base.session import DEFAULT_SCHEMA_NAME, get_engine


def alembic_config(engine):
    from alembic.config import Config

    cfg = Config()
    cfg.set_main_option('script_location', 'idds.orm.base:alembic')
    # NB: str(engine.url) masks the password as '***'; render_as_string
    # with hide_password=False keeps the real credentials. set_main_option
    # goes through ConfigParser interpolation, so literal % must be doubled.
    url = engine.url.render_as_string(hide_password=False).replace('%', '%%')
    cfg.set_main_option('sqlalchemy.url', url)
    cfg.set_main_option('version_table_schema', DEFAULT_SCHEMA_NAME)
    return cfg


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
        tables = set(insp.get_table_names(schema=DEFAULT_SCHEMA_NAME))
        # A populated schema with no alembic version ROW means a previous
        # start died between create_all and stamp (e.g. on the % password
        # bug this script once had), or the version row was lost. Running
        # `upgrade head` from base there would fail on the very first
        # revision (DuplicateColumn: create_all already made the column),
        # crash-looping the container - so treat it as fresh and stamp.
        # NB: checking the row, not just the table's existence - an empty
        # alembic_version table sends alembic back to base all the same.
        has_version = False
        if 'alembic_version' in tables:
            from sqlalchemy import text

            result = conn.execute(
                text(f'SELECT 1 FROM {DEFAULT_SCHEMA_NAME}.alembic_version LIMIT 1')
            )
            has_version = result.scalar() is not None

    from alembic import command

    if not tables:
        models.BASE.metadata.create_all(engine)
        command.stamp(alembic_config(engine), 'head')
        print('fresh schema: created from ORM metadata, alembic stamped at head')
    elif not has_version:
        # no-op for existing tables, creates anything missing. The stamp
        # below assumes those tables came from create_all of the SAME idds
        # version as this image - which does not hold if the image was
        # bumped between the crashed start and this recovery (create_all
        # never alters existing tables, so the stamp would skip migrations
        # they need). Unlikely in a dev stack; if it ever bites, wipe the
        # doma_idds schema (it holds no user state in this deployment) and
        # let the fresh-schema branch rebuild it.
        models.BASE.metadata.create_all(engine)
        command.stamp(alembic_config(engine), 'head')
        print('WARNING: unversioned schema stamped at head; if the idds '
              'version changed since these tables were created, drop the '
              f'{DEFAULT_SCHEMA_NAME} schema and restart to rebuild it')
        print('unversioned schema: create_all no-op + alembic stamped at head')
    else:
        # applies only migrations newer than the recorded version
        command.upgrade(alembic_config(engine), 'head')
        print('existing schema: alembic upgrade head done')


if __name__ == '__main__':
    main()
