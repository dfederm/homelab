FROM rclone/rclone:1.74.1@sha256:eb8788b795f0009324e9572b0e2acb9b56885327c2746b07d67a9d3b893a6602

COPY --chmod=755 backup.sh /
COPY --chmod=755 start.sh /
COPY cronjobs /etc/crontabs/root

ENTRYPOINT /bin/sh /start.sh
