#!/bin/bash

# Absolute path to this script
SCRIPT=$(readlink -f "$0")

# Absolute path this script is in, thus /home/user/bin
REPOPATH=$(dirname $(dirname "$SCRIPT"))

if [ "$1" != "" ]; then
    SERVICE=$1
else
    echo "Error: Provide a service name" 1>&2
    exit 1
fi

echo "Service: $SERVICE"

SERVICEPATH="$REPOPATH/services/$SERVICE/"
if [ ! -f "$SERVICEPATH/docker-compose.yml" ]; then
    echo "Error: Service $SERVICE does not exist" 1>&2
    exit 1
fi

echo "Creating symlink to .env"
ln -sf "$REPOPATH/.env" "$SERVICEPATH/.env"

pushd "$SERVICEPATH"

echo "Pulling containers"
docker compose pull

echo "Updating containers"
docker compose up --force-recreate --build -d

echo "Pruning unused images"
docker image prune -f

popd

exit 0
