# Frigate

## Configuration

Native YAML at `${CONFIG_DIR}/frigate/config/config.yml` owns camera, detector,
and retention policy; deployment does not replace it. Start from
`config.example.yml` and use the [standard deployment workflow](../../README.md#services).

The selected render node appears as `/dev/dri/renderD128` inside Frigate.
Hardware acceleration and `environment_vars.LIBVA_DRIVER_NAME`, when needed,
belong in native YAML.

## Model preparation

Optional pre-deploy preparation supports Ultralytics YOLO checkpoints compatible
with Frigate's `yolo-generic` model type and requires Python 3.11 through 3.13.
Acquisition settings are listed in [`.env.template`](../../.env.template).

Point native `model.path` and `model.labelmap_path` at `model.onnx` and
`labelmap.txt` inside `/config/model_cache/<FRIGATE_MODEL_NAME>/`;
preparation does not edit YAML or choose tracked objects.

Verified caches are reused without downloads or tooling installation; invalid or
differently configured caches fail rather than being overwritten. Ultralytics
software/models are subject to upstream license terms.

## Persistence

`/config` must remain writable for UI saves, migrations, and persistent
authentication state. Set `database.path: /data/frigate.db` to keep SQLite out of
the shared configuration directory.

Retention is not a filesystem quota or a minimum-duration guarantee: media shares
the underlying filesystem's capacity, and Frigate can delete recordings early
under space pressure. Saved exports are mounted outside ordinary recording cleanup.

## MQTT and Home Assistant

Create the env-matching MQTT account in
`${CONFIG_DIR}/frigate/mosquitto/passwords` with `mosquitto_passwd`; use `-c` only
for a new file. Broker accounts share topic access over plaintext LAN MQTT.

Only the authenticated Frigate API and MQTT are published; there is no public
Caddy route. Home Assistant's API connection needs a trusted certificate, or
authenticated HTTP with native TLS disabled on a trusted LAN. Live-camera
entities need authenticated RTSP access, which this project does not publish.
