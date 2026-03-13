FROM rclone/rclone@sha256:8a17d9b5cd5ce71bbb42e49e92ee83575d7fb03f6233d949d328e9d029b9376d

COPY --chmod=755 backup.sh /
COPY --chmod=755 start.sh /
COPY cronjobs /etc/crontabs/root

ENTRYPOINT /bin/sh /start.sh
