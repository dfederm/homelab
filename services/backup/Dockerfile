FROM rclone/rclone:1.74.3@sha256:623378ad0ff3ebd5cebf77720843c0e02edfe46e2d5b5ac6bed54c6371780dfb

COPY --chmod=755 backup.sh /
COPY --chmod=755 start.sh /
COPY cronjobs /etc/crontabs/root

ENTRYPOINT /bin/sh /start.sh
