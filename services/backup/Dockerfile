FROM rclone/rclone:1.73.5@sha256:1619a625f845e169c34b952cf40c483c0392965b821c5155cde8cbfd35254a96

COPY --chmod=755 backup.sh /
COPY --chmod=755 start.sh /
COPY cronjobs /etc/crontabs/root

ENTRYPOINT /bin/sh /start.sh
