#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON=$(command -v python3 || command -v python || command -v python.exe || true)
if [ -z "$PYTHON" ]; then
    echo "Python is required for model preparation tests" >&2
    exit 1
fi

PYTHONDONTWRITEBYTECODE=1 "$PYTHON" - "$REPO_DIR" <<'PY'
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

repo = Path(sys.argv[1])
service = repo / "services/frigate"
spec = importlib.util.spec_from_file_location("prepare_model", service / "prepare-model.py")
preparer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparer)


class ModelPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="frigate-model-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "cache" / "detector"
        self.checkpoint = b"fixture checkpoint"
        self.digest = hashlib.sha256(self.checkpoint).hexdigest()
        self.url = "https://weights.example.invalid/checkpoint.pt"
        self.input_size = 320
        self.opset = 15
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.dict(os.environ))
        self.stack.enter_context(mock.patch.object(
            preparer.importlib.metadata, "version",
            side_effect=lambda name: preparer.pinned_requirements()[name],
        ))
        self.download = self.stack.enter_context(mock.patch.object(
            preparer.urllib.request, "urlopen",
            side_effect=lambda url, *args, **kwargs: io.BytesIO(
                {self.url: self.checkpoint}[url]
            ),
        ))
        self.model = mock.Mock()
        self.model.names = {1: "Vehicle", 0: "Blue Heron"}

        def export(**kwargs):
            path = self.root / "export.onnx"
            path.write_bytes(b"fixture onnx")
            return path

        self.model.export.side_effect = export
        self.yolo = mock.Mock(return_value=self.model)
        self.session = mock.Mock()
        self.session.get_inputs.return_value = [
            SimpleNamespace(shape=[1, 3, self.input_size, self.input_size], name="images")
        ]
        self.session.run.return_value = [SimpleNamespace(ndim=3, shape=[1, 6, 42])]
        self.finite = mock.Mock(return_value=SimpleNamespace(all=lambda: True))
        self.stack.enter_context(mock.patch.dict(sys.modules, {
            "numpy": SimpleNamespace(
                zeros=mock.Mock(), float32=object(), isfinite=self.finite
            ),
            "onnx": SimpleNamespace(checker=SimpleNamespace(check_model=mock.Mock())),
            "onnxruntime": SimpleNamespace(InferenceSession=mock.Mock(return_value=self.session)),
            "torch": SimpleNamespace(set_num_threads=mock.Mock()),
            "ultralytics": SimpleNamespace(YOLO=self.yolo),
        }))

    def run_preparer(self, **overrides):
        settings = {
            "checkpoint-url": self.url,
            "checkpoint-sha256": self.digest,
            "input-size": self.input_size,
            "opset": self.opset,
        }
        settings.update(overrides)
        args = [str(service / "prepare-model.py"), str(self.output)]
        for key, value in settings.items():
            args.extend([f"--{key}", str(value)])
        with mock.patch.object(sys, "argv", args), \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            preparer.main()

    def test_configured_export_and_labels(self):
        self.run_preparer()
        self.download.assert_called_once()
        self.model.export.assert_called_once()
        for option, expected in {
            "format": "onnx", "imgsz": self.input_size, "opset": self.opset,
            "dynamic": False, "nms": None, "batch": 1, "device": "cpu",
        }.items():
            self.assertEqual(self.model.export.call_args.kwargs[option], expected, option)
        self.assertEqual(
            (self.output / "labelmap.txt").read_text(),
            "0 blue_heron\n1 vehicle\n",
        )
        metadata = json.loads((self.output / "metadata.json").read_text())
        self.assertEqual(metadata["checkpoint_sha256"], self.digest)
        self.assertEqual(metadata["input_shape"], [1, 3, self.input_size, self.input_size])
        self.assertEqual(metadata["opset"], self.opset)
        preparer.verify_existing(self.output, self.digest, self.input_size, self.opset)
        self.assertEqual(list(self.output.parent.iterdir()), [self.output])

    def test_cached_model_needs_no_download_or_installed_packages(self):
        self.run_preparer()
        before = {path.name: path.stat().st_mtime_ns for path in self.output.iterdir()}
        self.download.reset_mock()
        with mock.patch.object(
            preparer.importlib.metadata, "version",
            side_effect=AssertionError("cached model must not need installed packages"),
        ), mock.patch.object(
            preparer, "pinned_requirements",
            side_effect=AssertionError("tooling updates must not invalidate cached artifacts"),
        ):
            self.run_preparer()
        self.download.assert_not_called()
        self.assertEqual(before, {
            path.name: path.stat().st_mtime_ns for path in self.output.iterdir()
        })

    def test_corrupt_cache_is_preserved_and_rejected(self):
        self.run_preparer()
        model = self.output / "model.onnx"
        model.write_bytes(b"corrupt fixture")
        self.download.reset_mock()
        with self.assertRaisesRegex(SystemExit, "model verification failed"):
            self.run_preparer()
        self.assertEqual(model.read_bytes(), b"corrupt fixture")
        self.download.assert_not_called()

    def test_changed_model_or_export_settings_do_not_replace_cache(self):
        self.run_preparer()
        before = {path.name: path.read_bytes() for path in self.output.iterdir()}
        for settings in [
            {"checkpoint-sha256": "0" * 64},
            {"input-size": self.input_size * 2},
            {"opset": self.opset + 1},
        ]:
            with self.subTest(settings=settings), self.assertRaises(SystemExit):
                self.run_preparer(**settings)
        self.assertEqual(before, {
            path.name: path.read_bytes() for path in self.output.iterdir()
        })

    def test_bad_checkpoint_is_never_loaded_or_published(self):
        with self.assertRaisesRegex(SystemExit, "checkpoint checksum mismatch"):
            self.run_preparer(**{"checkpoint-sha256": "0" * 64})
        self.yolo.assert_not_called()
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.output.parent.iterdir()), [])

    def test_export_failure_does_not_publish_partial_artifacts(self):
        self.model.export.side_effect = RuntimeError("fixture export failure")
        with self.assertRaisesRegex(RuntimeError, "fixture export failure"):
            self.run_preparer()
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.output.parent.iterdir()), [])

    def test_empty_destination_can_be_populated_atomically(self):
        self.output.mkdir(parents=True)
        self.run_preparer()
        preparer.verify_existing(self.output, self.digest, self.input_size, self.opset)

    def test_incompatible_shapes_are_not_published(self):
        for shape in ([1, 5, 42], [1, 42, 6], [1, 300, 6]):
            with self.subTest(shape=shape):
                self.session.run.return_value = [SimpleNamespace(ndim=3, shape=shape)]
                with self.assertRaisesRegex(SystemExit, "YOLO output shape"):
                    self.run_preparer()
                self.assertFalse(self.output.exists())

    def test_non_finite_model_output_is_not_published(self):
        self.finite.return_value = SimpleNamespace(all=lambda: False)
        with self.assertRaisesRegex(SystemExit, "non-finite output"):
            self.run_preparer()
        self.assertFalse(self.output.exists())

    def test_invalid_parameters_fail_before_download(self):
        for settings in [
            {"checkpoint-url": "http://weights.example.invalid/checkpoint.pt"},
            {"checkpoint-sha256": "not-a-checksum"},
            {"input-size": 0},
            {"opset": -1},
        ]:
            with self.subTest(settings=settings), self.assertRaises(SystemExit):
                self.run_preparer(**settings)
        self.download.assert_not_called()

    def hook_fixture(self):
        config = self.root / "config with spaces"
        config.mkdir()
        self.output = self.root / "appdata with spaces" / "frigate/model_cache/sample"
        self.run_preparer()
        (config / "common.env").write_text(
            f'FRIGATE_MODEL_URL="https://common.example.invalid/wrong.pt"\n'
            f'DOCKER_APPDATA_ROOT="{self.root / "appdata with spaces"}"\n'
            f'FRIGATE_MODEL_SHA256={self.digest}\n'
            f'FRIGATE_MODEL_NAME=sample\n'
            f'FRIGATE_MODEL_INPUT_SIZE={self.input_size}\n'
            f'FRIGATE_MODEL_OPSET={self.opset}\n'
        )
        (config / "machine.env").write_text(f'FRIGATE_MODEL_URL="{self.url}"\n')
        env = os.environ.copy()
        env.update(CONFIG_DIR=str(config), ENV_FILE=str(config / "machine.env"))
        return config, env

    def test_hook_uses_repo_verifier_and_machine_env_without_installation(self):
        config, env = self.hook_fixture()
        before = (self.output / "model.onnx").stat().st_mtime_ns
        for _ in range(2):
            result = subprocess.run(
                ["bash", str(service / "pre-up.sh")],
                env=env, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / "model.onnx").stat().st_mtime_ns, before)
        self.assertFalse((self.output.parents[1] / "model-build-env").exists())
        self.assertEqual(
            (config / "machine.env").read_text(), f'FRIGATE_MODEL_URL="{self.url}"\n'
        )

    def test_hook_can_disable_preparation_with_machine_env(self):
        config, env = self.hook_fixture()
        (config / "machine.env").write_text(
            "FRIGATE_MODEL_URL=\nFRIGATE_MODEL_SHA256=\nDOCKER_APPDATA_ROOT=\n"
        )
        result = subprocess.run(
            ["bash", str(service / "pre-up.sh")], env=env,
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.output.parents[1] / "model-build-env").exists())

    def test_hook_rejects_path_escape_and_partial_configuration(self):
        config, env = self.hook_fixture()
        for setting in [
            "FRIGATE_MODEL_NAME=../escape",
            "FRIGATE_MODEL_SHA256=",
            "FRIGATE_MODEL_INPUT_SIZE=0",
        ]:
            with self.subTest(setting=setting):
                (config / "machine.env").write_text(setting + "\n")
                result = subprocess.run(
                    ["bash", str(service / "pre-up.sh")], env=env,
                    capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ERROR:", result.stderr)
        self.assertFalse((self.root / "escape").exists())
        self.assertFalse((self.output.parents[1] / "model-build-env").exists())

    def bootstrap_fixture(self):
        config, env = self.hook_fixture()
        shutil.rmtree(self.output)
        fixture_repo = self.root / "repo"
        (fixture_repo / "scripts").mkdir(parents=True)
        shutil.copy(repo / "scripts/lib.sh", fixture_repo / "scripts")
        with (fixture_repo / "scripts/lib.sh").open("a") as stream:
            stream.write(
                '\napt_get() {\n'
                '    { printf apt; printf " %q" "$@"; printf "\\n"; } >> "$BOOTSTRAP_LOG"\n'
                '}\n'
            )
        shutil.copytree(service, fixture_repo / "services/frigate")
        requirements = fixture_repo / "services/frigate/requirements-model.txt"
        requirements.write_bytes(
            requirements.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        )
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        python3 = bin_dir / "python3"
        python3.write_text(
            '#!/bin/bash\nset -euo pipefail\n'
            'if [ "$1" = -c ]; then\n'
            '    exec "$REAL_PYTHON" -c \\\n'
            '        \'import sys; sys.version_info = tuple(map(int, sys.argv[1].split("."))); exec(sys.argv[2])\' \\\n'
            '        "$FIXTURE_PYTHON_VERSION" "$2"\n'
            'elif [ "$1" = -m ] && [ "$2" = venv ]; then\n'
            '    printf "venv\\n" >> "$BOOTSTRAP_LOG"\n'
            '    mkdir -p "$3/bin"\n'
            '    cp "$FAKE_VENV_PYTHON" "$3/bin/python"\n'
            '    chmod +x "$3/bin/python"\n'
            'else\n    exit 1\nfi\n'
        )
        python3.chmod(0o755)
        venv_python = self.root / "venv-python"
        venv_python.write_text(
            '#!/bin/bash\nset -euo pipefail\n'
            'if [ "$1" = -m ] && [ "$2" = pip ]; then\n'
            '    { printf pip; printf " %q" "${@:3}"; printf "\\n"; } >> "$BOOTSTRAP_LOG"\n'
            'else\n'
            '    printf "%s\\n" "$@" > "$EXPORT_ARGS"\n'
            '    printf "prepare\\n" >> "$BOOTSTRAP_LOG"\n'
            'fi\n'
        )
        log = self.root / "bootstrap.log"
        export_args = self.root / "export.args"
        env.update(
            BOOTSTRAP_LOG=str(log), FAKE_VENV_PYTHON=str(venv_python),
            EXPORT_ARGS=str(export_args),
            REAL_PYTHON=sys.executable, FIXTURE_PYTHON_VERSION="3.13",
            PATH=f'{bin_dir}{os.pathsep}{env["PATH"]}',
        )
        return fixture_repo, env, log, export_args

    def test_hook_checks_supported_python_before_installation(self):
        fixture_repo, env, log, _ = self.bootstrap_fixture()
        for version, supported in [
            ("3.10", False), ("3.11", True), ("3.12", True),
            ("3.13", True), ("3.14", False),
        ]:
            with self.subTest(version=version):
                log.write_text("")
                env["FIXTURE_PYTHON_VERSION"] = version
                result = subprocess.run(
                    ["bash", str(fixture_repo / "services/frigate/pre-up.sh")],
                    env=env, capture_output=True, text=True,
                )
                if supported:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("prepare\n", log.read_text())
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("requires Python 3.11 through 3.13", result.stderr)
                    self.assertEqual(log.read_text(), "")

    def test_hook_bootstraps_cpu_tooling_then_passes_export_settings(self):
        fixture_repo, env, log, export_args = self.bootstrap_fixture()
        requirements = fixture_repo / "services/frigate/requirements-model.txt"
        result = subprocess.run(
            ["bash", str(fixture_repo / "services/frigate/pre-up.sh")],
            env=env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [shlex.split(line) for line in log.read_text().splitlines()]
        prepare_index = next(index for index, call in enumerate(calls) if call == ["prepare"])
        venv_index = next(index for index, call in enumerate(calls) if call == ["venv"])
        installs = [
            (index, call[call.index("install") + 1:])
            for index, call in enumerate(calls)
            if call[0] == "apt" and "install" in call
        ]
        self.assertTrue(
            {"python3-venv", "libgl1", "libglib2.0-0"} <= {
                package for index, packages in installs if index < prepare_index
                for package in packages
            }
        )
        self.assertTrue(any(
            index < venv_index and "python3-venv" in packages
            for index, packages in installs
        ))
        pip_parser = argparse.ArgumentParser(add_help=False)
        pip_parser.add_argument("-i", "--index-url")
        pip_parser.add_argument("-r", "--requirement", action="append", default=[])
        pip_parser.add_argument("-U", "--upgrade", action="store_true")
        pip_calls = [
            (index, *pip_parser.parse_known_args(call[1:]))
            for index, call in enumerate(calls) if call[0] == "pip"
        ]
        pip_upgrades = [
            index for index, options, packages in pip_calls
            if "install" in packages and options.upgrade and "pip" in packages
        ]
        self.assertTrue(pip_upgrades)
        requirements_calls = [
            index for index, options, packages in pip_calls
            if "install" in packages and str(requirements) in options.requirement
        ]
        self.assertTrue(requirements_calls)
        self.assertTrue(all(index < prepare_index for index, _, _ in pip_calls))
        pins = preparer.pinned_requirements()
        for package in ("torch", "torchvision"):
            cpu_installs = [
                index for index, options, packages in pip_calls
                if "install" in packages
                and options.index_url == "https://download.pytorch.org/whl/cpu"
                and f"{package}=={pins[package]}" in packages
            ]
            self.assertTrue(cpu_installs, package)
            self.assertLess(min(pip_upgrades), min(cpu_installs))
            self.assertLess(min(cpu_installs), min(requirements_calls))
        with mock.patch.object(sys, "argv", export_args.read_text().splitlines()), \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            preparer.main()
        metadata = json.loads((self.output / "metadata.json").read_text())
        self.assertEqual(metadata["checkpoint_sha256"], self.digest)
        self.assertEqual(metadata["input_shape"], [1, 3, self.input_size, self.input_size])
        self.assertEqual(metadata["opset"], self.opset)

    def test_runner_does_not_call_compose_after_model_failure(self):
        config, env = self.hook_fixture()
        (self.output / "model.onnx").write_bytes(b"corrupt fixture")
        fixture_repo = self.root / "repo"
        (fixture_repo / "scripts").mkdir(parents=True)
        shutil.copy(repo / "scripts/run-service.sh", fixture_repo / "scripts")
        shutil.copy(repo / "scripts/lib.sh", fixture_repo / "scripts")
        with (fixture_repo / "scripts/lib.sh").open("a") as stream:
            stream.write(
                '\nsource_env() {\n'
                '    source "$CONFIG_DIR/common.env"\n'
                '    source "$ENV_FILE"\n'
                '}\n'
            )
        shutil.copytree(service, fixture_repo / "services/frigate")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        docker = bin_dir / "docker"
        docker.write_text('#!/bin/bash\nprintf called >> "$DOCKER_LOG"\n')
        docker.chmod(0o755)
        log = self.root / "docker.log"
        env.update(
            HOMELAB_SETUP_LOCK_HELD="1", DOCKER_LOG=str(log),
            PATH=f'{bin_dir}{os.pathsep}{env["PATH"]}',
        )
        result = subprocess.run(
            ["bash", str(fixture_repo / "scripts/run-service.sh"), "frigate"],
            env=env, capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("model verification failed", result.stderr)
        self.assertFalse(log.exists())


unittest.main(argv=["frigate-model"], verbosity=2)
PY
