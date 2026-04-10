FROM rclone/rclone:1.73.4@sha256:654f6517c7aaec7e377690b2caf7c272dbe5f3b8200afbc14a00df6b4a9aa6ef

COPY --chmod=755 backup.sh /
COPY --chmod=755 start.sh /
COPY cronjobs /etc/crontabs/root

ENTRYPOINT /bin/sh /start.sh
