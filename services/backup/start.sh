#!/bin/sh

# Write the cron schedule (default 03:00 daily; override per target via BACKUP_CRON to
# stagger targets and avoid simultaneous writes to the shared rclone config).
cron="${BACKUP_CRON:-0 3 * * *}"
echo "$cron /bin/sh /backup.sh" > /etc/crontabs/root

echo "Running backup on start..."
/bin/sh /backup.sh
echo "Backup on start done"

echo "Starting cron backups ($cron)"
crond -f -d 8
