#!/bin/sh

echo "Running backup on start..."
/backup.sh
echo "Backup on start done"

echo "Starting cron backups"
crond -f -d 8
