#!/usr/bin/env python3
"""Preview and stage missing FLAC tags from a reviewed beets export."""

import argparse
import datetime
import hashlib
import io
import json
import shutil
import sys
from pathlib import Path

from mutagen import MutagenError
from mutagen.flac import FLAC, Picture
from PIL import Image


FIELDS = {
    "title": ("TITLE",),
    "artist": ("ARTIST",),
    "album": ("ALBUM",),
    "albumartist": ("ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"),
    "track": ("TRACKNUMBER", "TRACK"),
    "tracktotal": ("TRACKTOTAL", "TOTALTRACKS", "TRACKC"),
    "disc": ("DISCNUMBER", "DISC"),
    "disctotal": ("DISCTOTAL", "TOTALDISCS", "DISCC"),
    "date": ("DATE", "YEAR"),
    "label": ("LABEL", "PUBLISHER"),
    "isrc": ("ISRC",),
}
REQUIRED = ("title", "artist", "album")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def jpeg_properties(data):
    with Image.open(io.BytesIO(data)) as image:
        if image.format != "JPEG":
            raise ValueError("Cover is not a JPEG image")
        width, height = image.size
        depth = len(image.getbands()) * 8
        image.verify()
    return width, height, depth


def under(path, root):
    return path == root or root in path.parents


def contained(root, relative):
    relative = Path(relative)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"Invalid relative path: {relative}")
    path = (root / relative).resolve()
    if not under(path, root):
        raise ValueError(f"Path escapes its root: {relative}")
    return path


def proposed_fields(row):
    values = {}
    for field in FIELDS:
        if field == "date":
            year = str(row.get("year") or "").strip()
            month = str(row.get("month") or "").strip()
            day = str(row.get("day") or "").strip()
            value = year if year.isdigit() and int(year) > 0 else ""
            if value and month.isdigit() and 1 <= int(month) <= 12:
                value += f"-{int(month):02d}"
                if day.isdigit() and 1 <= int(day) <= 31:
                    datetime.date(int(year), int(month), int(day))
                    value += f"-{int(day):02d}"
        else:
            value = str(row.get(field) or "").strip()
        if value and value not in ("0", "00", "0000"):
            values[field] = value
    return values


def make_plan(root, rows):
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise ValueError("The music root must be a directory")
    if not isinstance(rows, list) or not rows:
        raise ValueError("The beets export must contain at least one track")
    tracks = []
    seen = set()
    for row in rows:
        source = Path(row["path"]).resolve(strict=True)
        if not under(source, root) or source.suffix.lower() != ".flac":
            raise ValueError(f"Not a FLAC file under the music root: {source}")
        if source in seen:
            raise ValueError(f"Duplicate track: {source}")
        seen.add(source)
        values = proposed_fields(row)
        if (
            str(row.get("data_source") or "").lower() != "deezer"
            or not row.get("deezer_album_id")
            or not row.get("deezer_track_id")
            or any(not values.get(field) for field in REQUIRED)
        ):
            raise ValueError(f"Track is not a complete Deezer match: {source}")
        audio = FLAC(source)
        changes = {}
        conflicts = {}
        for field, value in values.items():
            aliases = FIELDS[field]
            existing = [
                str(v) for key in aliases for v in audio.get(key, []) if v
            ]
            if not existing:
                changes[aliases[0]] = value
            elif value not in existing:
                conflicts[field] = {"existing": existing, "proposed": value}
        cover = None
        if not audio.pictures:
            for name in ("folder.jpg", "cover.jpg"):
                image = source.parent / name
                if image.is_file():
                    image = image.resolve(strict=True)
                    if not under(image, root):
                        raise ValueError(f"Cover escapes music root: {image}")
                    jpeg_properties(image.read_bytes())
                    cover = {
                        "path": str(image.relative_to(root)),
                        "sha256": digest(image),
                    }
                    break
        tracks.append(
            {
                "path": str(source.relative_to(root)),
                "sha256": digest(source),
                "source": "Deezer",
                "release_id": str(row["deezer_album_id"]),
                "changes": changes,
                "conflicts": conflicts,
                "cover": cover,
            }
        )
    return {"root": str(root), "tracks": tracks}


def write_new_json(path, data):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(data, stream, indent=2, ensure_ascii=False)
        stream.write("\n")


def stage(plan, destination):
    root = Path(plan["root"]).resolve(strict=True)
    destination = destination.resolve()
    if under(destination, root) or under(root, destination):
        raise ValueError(
            "The staging directory must be separate from the music root"
        )
    destination.mkdir(parents=True, exist_ok=True)
    seen = set()
    staged = 0
    skipped = 0
    for track in plan["tracks"]:
        source = contained(root, track["path"])
        target = contained(destination, track["path"])
        if source in seen:
            raise ValueError(f"Duplicate track: {source}")
        seen.add(source)
        if track["conflicts"]:
            skipped += 1
            continue
        changes = track["changes"]
        allowed = {aliases[0] for aliases in FIELDS.values()}
        if not set(changes) <= allowed:
            raise ValueError(f"Unexpected tag in plan: {source}")
        if not changes and not track["cover"]:
            skipped += 1
            continue
        if digest(source) != track["sha256"]:
            raise ValueError(f"Source changed since preview: {source}")
        cover = track["cover"]
        image_data = None
        if cover:
            image = contained(root, cover["path"])
            image_data = image.read_bytes()
            if hashlib.sha256(image_data).hexdigest() != cover["sha256"]:
                raise ValueError(f"Cover changed since preview: {image}")
        target.parent.mkdir(parents=True, exist_ok=True)
        target = contained(destination, track["path"])
        with (
            source.open("rb") as source_stream,
            target.open("xb") as target_stream,
        ):
            shutil.copyfileobj(source_stream, target_stream)
        if digest(target) != track["sha256"]:
            raise ValueError(f"Copy does not match preview: {target}")
        audio = FLAC(target)
        for key, value in changes.items():
            aliases = next(
                aliases for aliases in FIELDS.values() if aliases[0] == key
            )
            if any(audio.get(alias) for alias in aliases):
                raise ValueError(
                    f"Tag unexpectedly exists on copied file: {key}"
                )
            audio[key] = value
        if image_data:
            if audio.pictures:
                raise ValueError(
                    f"Artwork unexpectedly exists on copied file: {target}"
                )
            picture = Picture()
            picture.type = 3
            picture.mime = "image/jpeg"
            picture.width, picture.height, picture.depth = jpeg_properties(
                image_data
            )
            picture.data = image_data
            audio.add_picture(picture)
        audio.save()
        staged += 1
    return staged, skipped


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preview = commands.add_parser(
        "preview", help="create a reviewable JSON plan"
    )
    preview.add_argument("music_root", type=Path)
    preview.add_argument("export", type=Path)
    preview.add_argument("plan", type=Path)
    staging = commands.add_parser(
        "stage", help="write copies into a separate directory"
    )
    staging.add_argument("plan", type=Path)
    staging.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "preview":
            root = args.music_root.resolve(strict=True)
            if under(args.plan.resolve(), root):
                raise ValueError("The plan must be outside the music root")
            rows = json.loads(args.export.read_text(encoding="utf-8"))
            plan = make_plan(root, rows)
            write_new_json(args.plan, plan)
            conflicts = sum(
                bool(track["conflicts"]) for track in plan["tracks"]
            )
            print(
                f"Previewed {len(plan['tracks'])} tracks; "
                f"{conflicts} have conflicts."
            )
        else:
            plan = json.loads(args.plan.read_text(encoding="utf-8"))
            staged, skipped = stage(plan, args.destination)
            print(f"Staged {staged} tracks; skipped {skipped}.")
    except (OSError, ValueError, KeyError, TypeError, MutagenError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
