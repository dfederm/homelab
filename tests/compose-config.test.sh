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
writable_config_mount_exceptions = {
    ("frigate", "frigate", "${CONFIG_DIR}/frigate/config", "/config"): (
        "Frigate writes UI configuration, migration backups, authentication signing "
        "secrets, and maintenance state into its native configuration directory."
    ),
}
for mount, reason in writable_config_mount_exceptions.items():
    if not reason.strip():
        raise SystemExit(f"writable config mount exception needs an explanation: {mount}")
used_config_mount_exceptions = set()

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
                if len(fields) < 2:
                    continue
                source, target = fields[:2]
                read_only = len(fields) == 3 and "ro" in fields[2].split(",")
            elif isinstance(volume, dict):
                source = volume.get("source")
                target = volume.get("target")
                read_only = volume.get("read_only") is True
            else:
                continue

            if not isinstance(source, str) or not (
                source == "${CONFIG_DIR}" or source.startswith("${CONFIG_DIR}/")
            ):
                continue
            if read_only:
                continue

            mount = (path.parent.name, name, source, target)
            if mount not in writable_config_mount_exceptions:
                raise SystemExit(
                    f"{location} must mount external configuration read-only: "
                    f"{source} -> {target}"
                )
            used_config_mount_exceptions.add(mount)

unused_exceptions = set(writable_config_mount_exceptions) - used_config_mount_exceptions
if unused_exceptions:
    raise SystemExit(f"unused writable config mount exceptions: {sorted(unused_exceptions)}")

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
