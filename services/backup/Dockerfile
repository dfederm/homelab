FROM rclone/rclone:1.73.3@sha256:66af24d7c8809af336dc16068149257cf447c80f8c60aa9f5679153f42017b85

COPY --chmod=755 backup.sh /
COPY --chmod=755 start.sh /
COPY cronjobs /etc/crontabs/root

ENTRYPOINT /bin/sh /start.sh
