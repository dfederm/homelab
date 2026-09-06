#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON=$(command -v python3 || command -v python || command -v python.exe || true)

if [ -z "$PYTHON" ]; then
    echo "Python is required for Compose validation" >&2
    exit 1
fi

"$PYTHON" - "$REPO_DIR" <<'PY'
import pathlib
import re
import sys

try:
    import yaml
except ImportError as error:
    raise SystemExit("PyYAML is required when Docker Compose is unavailable") from error

repo = pathlib.Path(sys.argv[1])
compose_files = sorted(repo.glob("services/*/docker-compose.yml"))
if not compose_files:
    raise SystemExit("no Compose files found")

image_pattern = re.compile(r":[^/@]+@sha256:[0-9a-f]{64}$")

for path in compose_files:
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as error:
        raise SystemExit(f"{path.relative_to(repo)}: invalid YAML: {error}") from error

    if not isinstance(document, dict):
        raise SystemExit(f"{path.relative_to(repo)}: top level must be a mapping")

    services = document.get("services")
    if not isinstance(services, dict) or not services:
        raise SystemExit(f"{path.relative_to(repo)}: services must be a non-empty mapping")

    for name, service in services.items():
        location = f"{path.relative_to(repo)}: service {name}"
        if not isinstance(service, dict):
            raise SystemExit(f"{location} must be a mapping")

        image = service.get("image")
        build = service.get("build")
        if image is None and build is None:
            raise SystemExit(f"{location} must declare image or build")
        if image is not None:
            if not isinstance(image, str) or not image_pattern.search(image):
                raise SystemExit(
                    f"{location} image must include a tag and sha256 digest: {image!r}"
                )

        env_file = service.get("env_file", [])
        if isinstance(env_file, str):
            env_files = [env_file]
        elif isinstance(env_file, list):
            env_files = env_file
        else:
            raise SystemExit(f"{location} env_file must be a string or list")
        if any(value == ".env" for value in env_files):
            raise SystemExit(f"{location} must not depend on a source-tree .env file")

        for volume in service.get("volumes", []):
            if isinstance(volume, str):
                fields = volume.rsplit(":", 2)
                source = fields[0]
                if source == "${CONFIG_DIR}" or source.startswith("${CONFIG_DIR}/"):
                    if len(fields) != 3 or "ro" not in fields[2].split(","):
                        raise SystemExit(
                            f"{location} must mount external configuration read-only: {source}"
                        )
            elif isinstance(volume, dict):
                source = volume.get("source")
                if isinstance(source, str) and (
                    source == "${CONFIG_DIR}" or source.startswith("${CONFIG_DIR}/")
                ):
                    if volume.get("read_only") is not True:
                        raise SystemExit(
                            f"{location} must mount external configuration read-only: {source}"
                        )

print(f"YAML and repository invariants passed for {len(compose_files)} Compose files")
PY

if command -v docker >/dev/null 2>&1 \
    && docker compose version >/dev/null 2>&1; then
    while IFS= read -r compose_file; do
        docker compose --file "$compose_file" config --no-interpolate --quiet
    done < <(find "$REPO_DIR/services" -mindepth 2 -maxdepth 2 \
        -name docker-compose.yml -print | sort)
    echo "Docker Compose semantic validation passed"
else
    echo "Docker Compose unavailable; semantic validation skipped (PyYAML fallback used)"
fi
