FROM rclone/rclone:1.74.0@sha256:d2e0e88359d0b2e67cfcd2c43d5405185eb8adfc207079df27c42da82c5207bc

COPY --chmod=755 backup.sh /
COPY --chmod=755 start.sh /
COPY cronjobs /etc/crontabs/root

ENTRYPOINT /bin/sh /start.sh
