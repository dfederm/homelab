#!/bin/sh

rclone sync /data $RCLONE_DEST -v --create-empty-src-dirs --metadata --modify-window 2s
