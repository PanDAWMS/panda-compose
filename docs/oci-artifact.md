# OCI Artifact

panda-compose publishes its `docker-compose.yml` as an OCI artifact to the
[GitHub Container Registry](https://ghcr.io/pandawms/panda-compose) on every push to `main`
and on every version tag. It can also be triggered manually via `workflow_dispatch`.

## What is published

The OCI artifact contains the `docker-compose.yml` service definitions with the
correct media type (`application/vnd.docker.compose.project`).  It is compatible with
Docker Compose v2.34.0+ `include` and `-f oci://` syntax.

> **Note:** Config files that are bind-mounted from `./config/` are **not** embedded in
> the OCI artifact — only their path declarations are. See
> [Limitations](#limitations) below.

## Usage patterns

### Inspect the compose configuration

```bash
docker compose -f oci://ghcr.io/pandawms/panda-compose:latest config
```

### Include in another compose file

```yaml
# docker-compose.yml in an external project
include:
  - oci://ghcr.io/pandawms/panda-compose:latest

services:
  my-tool:
    image: my-tool:latest
    depends_on:
      panda-server:
        condition: service_healthy
```

> **Warning:** The compose file references config files with bind mounts (`./config/…`).
> When including the OCI artifact, Docker Compose extracts the compose YAML to a
> temporary directory.  The config files are not present there, so services that require
> them will fail to start.
>
> **Use [`uses: PanDAWMS/panda-compose@main`](setup-panda-action.md) in GitHub Actions
> instead** — it checks out the full repository (including config files) and waits for
> the stack to be healthy before your job continues.

## Pinning to a version

```yaml
include:
  - oci://ghcr.io/pandawms/panda-compose:v1   # semver tag
  - oci://ghcr.io/pandawms/panda-compose:latest  # always latest main
```

## Available tags

| Tag | Description |
|---|---|
| `latest` | Built from the `main` branch on every push |
| `v*` | Immutable release tags (e.g. `v1.0.0`) |

## Limitations

The OCI artifact is produced with `docker compose publish --yes`, which:

1. **Does not embed bind-mounted config files.** Services that mount files from
   `./config/` will not find those files when the artifact is extracted to a temporary
   directory.  The full stack can only be started by cloning the repository (or using the
   [setup-panda action](setup-panda-action.md)).

2. **Does not push service images.** All service images (`pandacms/panda-server`, etc.)
   are third-party; push failures are silently ignored.  The artifact contains only the
   compose YAML.

3. **Requires Docker Compose v2.34.0+.** Earlier versions do not support the
   `oci://` URI scheme or the `publish` command.

## Producing the OCI artifact locally

```bash
# install docker compose v2.34.0+ if needed
cp .env.example .env
docker compose publish --yes ghcr.io/pandawms/panda-compose:my-tag
```
