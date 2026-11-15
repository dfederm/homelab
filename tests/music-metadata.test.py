import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from mutagen.flac import FLAC, Picture
from PIL import Image


MODULE_PATH = (
    Path(__file__).resolve().parents[1] / "tools" / "music-metadata.py"
)
SPEC = importlib.util.spec_from_file_location("music_metadata", MODULE_PATH)
music = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(music)


@unittest.skipUnless(
    shutil.which("ffmpeg"), "ffmpeg is required to generate test audio"
)
class MusicMetadataTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.root = self.base / "music"
        self.album = self.root / "Artist" / "Album"
        self.album.mkdir(parents=True)
        self.track = self.album / "01.flac"
        subprocess.run(
            [
                "ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                "sine=frequency=440:duration=1", "-c:a", "flac",
                str(self.track),
            ],
            check=True,
        )
        self.cover = self.album / "folder.jpg"
        Image.new("RGB", (16, 12), "red").save(self.cover, format="JPEG")
        self.row = {
            "path": str(self.track),
            "data_source": "Deezer",
            "deezer_album_id": "123",
            "deezer_track_id": "456",
            "title": "Song",
            "artist": "Artist",
            "album": "Album",
            "albumartist": "Artist",
            "track": "1",
            "tracktotal": "1",
            "year": "2020",
            "month": "3",
            "day": "4",
        }

    def tearDown(self):
        self.temp.cleanup()

    def test_stages_missing_metadata_without_changing_source(self):
        original = FLAC(self.track)
        original["COMMENT"] = "Keep this"
        original["MUSICBRAINZ_ALBUMID"] = (
            "d7c34e51-390a-4f25-94dc-169cc736c961"
        )
        original.save()
        original_hash = music.digest(self.track)
        original_audio_hash = FLAC(self.track).info.md5_signature

        plan = music.make_plan(self.root, [self.row])
        staged_root = self.base / "staged"
        self.assertEqual(music.stage(plan, staged_root), (1, 0))
        staged = FLAC(staged_root / "Artist" / "Album" / "01.flac")

        self.assertEqual(music.digest(self.track), original_hash)
        self.assertEqual(staged.info.md5_signature, original_audio_hash)
        self.assertEqual(staged["TITLE"], ["Song"])
        self.assertEqual(staged["DATE"], ["2020-03-04"])
        self.assertEqual(staged["COMMENT"], ["Keep this"])
        self.assertEqual(
            staged["MUSICBRAINZ_ALBUMID"],
            ["d7c34e51-390a-4f25-94dc-169cc736c961"],
        )
        self.assertNotIn("MUSICBRAINZ_TRACKID", staged)
        self.assertEqual(len(staged.pictures), 1)
        self.assertEqual(staged.pictures[0].data, self.cover.read_bytes())
        self.assertEqual(
            (staged.pictures[0].width, staged.pictures[0].height), (16, 12)
        )

        row = dict(
            self.row, path=str(staged_root / "Artist" / "Album" / "01.flac")
        )
        repeated = music.make_plan(staged_root, [row])
        self.assertEqual(music.stage(repeated, self.base / "again"), (0, 1))

    def test_conflicts_skip_track_and_preserve_existing_art(self):
        original = FLAC(self.track)
        original["TITLE"] = "Different title"
        picture = Picture()
        picture.type = 3
        picture.mime = "image/jpeg"
        picture.data = self.cover.read_bytes()
        original.add_picture(picture)
        original.save()
        before = music.digest(self.track)
        plan = music.make_plan(self.root, [self.row])
        self.assertIn("title", plan["tracks"][0]["conflicts"])
        self.assertIsNone(plan["tracks"][0]["cover"])
        self.assertEqual(music.stage(plan, self.base / "staged"), (0, 1))
        self.assertEqual(music.digest(self.track), before)

    def test_existing_embedded_art_is_preserved_when_adding_fields(self):
        original = FLAC(self.track)
        picture = Picture()
        picture.type = 3
        picture.mime = "image/jpeg"
        picture.data = self.cover.read_bytes()
        original.add_picture(picture)
        original.save()
        plan = music.make_plan(self.root, [self.row])
        self.assertIsNone(plan["tracks"][0]["cover"])
        self.assertEqual(music.stage(plan, self.base / "staged"), (1, 0))
        staged = FLAC(self.base / "staged" / "Artist" / "Album" / "01.flac")
        self.assertEqual(len(staged.pictures), 1)
        self.assertEqual(staged.pictures[0].data, picture.data)

    def test_refuses_stale_source_or_cover_and_never_overwrites(self):
        plan = music.make_plan(self.root, [self.row])
        original = FLAC(self.track)
        original["COMMENT"] = "Changed after preview"
        original.save()
        with self.assertRaisesRegex(ValueError, "Source changed"):
            music.stage(plan, self.base / "staged")

        plan = music.make_plan(self.root, [self.row])
        Image.new("RGB", (8, 8), "blue").save(self.cover, format="JPEG")
        with self.assertRaisesRegex(ValueError, "Cover changed"):
            music.stage(plan, self.base / "staged")

        plan = music.make_plan(self.root, [self.row])
        target = self.base / "staged" / "Artist" / "Album" / "01.flac"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"already here")
        with self.assertRaises(FileExistsError):
            music.stage(plan, self.base / "staged")
        self.assertEqual(target.read_bytes(), b"already here")

    def test_rejects_unmatched_duplicate_and_out_of_root_tracks(self):
        with self.assertRaisesRegex(ValueError, "complete Deezer match"):
            music.make_plan(self.root, [dict(self.row, data_source="")])
        with self.assertRaisesRegex(ValueError, "Duplicate track"):
            music.make_plan(self.root, [self.row, self.row])
        with self.assertRaisesRegex(ValueError, "separate"):
            music.stage(
                music.make_plan(self.root, [self.row]), self.root / "stage"
            )
        with self.assertRaisesRegex(ValueError, "relative path"):
            music.contained(self.root.resolve(), "../elsewhere.flac")

    def test_rejects_impossible_dates_and_does_not_invent_missing_values(self):
        with self.assertRaises(ValueError):
            music.make_plan(self.root, [dict(self.row, month="2", day="31")])
        plan = music.make_plan(
            self.root, [dict(self.row, label=None, isrc=None)]
        )
        self.assertNotIn("LABEL", plan["tracks"][0]["changes"])
        self.assertNotIn("ISRC", plan["tracks"][0]["changes"])


if __name__ == "__main__":
    unittest.main()
