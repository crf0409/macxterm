"""Filesystem tests for the updater's active-process and rollback boundaries."""
import importlib.util
import pathlib
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('macxterm_installer', pathlib.Path(__file__).resolve().parent.parent / 'Scripts/install-app.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallAppTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.work.name)
        self.source, self.destination = root / 'source.app', root / 'installed.app'
        for app, marker in [(self.source, 'new'), (self.destination, 'old')]:
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/marker').write_text(marker)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'app.macxterm.MacXTerm', 'CFBundleExecutable': 'MacXTerm',
                'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '6'}))

    def tearDown(self): self.work.cleanup()

    def command(self, args, **kwargs):
        if args[0] == 'ditto': shutil.copytree(args[1], args[2])

    def test_running_app_is_preserved_without_copying_or_replacing(self):
        with patch.object(installer, 'running_pids', return_value=[123]), patch.object(installer.subprocess, 'run') as command:
            with self.assertRaisesRegex(RuntimeError, '仍在运行'): installer.install(self.source, self.destination)
            command.assert_not_called()
        self.assertEqual((self.destination / 'Contents/marker').read_text(), 'old')

    def test_launch_during_staging_leaves_original_bundle_in_place(self):
        with patch.object(installer, 'running_pids', side_effect=[[], [123]]), patch.object(installer.subprocess, 'run', side_effect=self.command):
            with self.assertRaisesRegex(RuntimeError, '仍在运行'): installer.install(self.source, self.destination)
        self.assertEqual((self.destination / 'Contents/marker').read_text(), 'old')
        self.assertFalse(list(self.destination.parent.glob('.MacXTerm-install-*')))

    def test_stopped_app_is_replaced_and_no_old_version_remains(self):
        with patch.object(installer, 'running_pids', return_value=[]), patch.object(installer.subprocess, 'run', side_effect=self.command):
            result = installer.install(self.source, self.destination)
        self.assertTrue(result['installed'])
        self.assertEqual((self.destination / 'Contents/marker').read_text(), 'new')
        self.assertFalse(list(self.destination.parent.glob('.MacXTerm-install-*')))

    def test_failed_final_verification_restores_previous_bundle(self):
        def failing_command(args, **kwargs):
            self.command(args, **kwargs)
            if args[0] == 'codesign' and args[-1] == str(self.destination): raise RuntimeError('verification failed')
        with patch.object(installer, 'running_pids', return_value=[]), patch.object(installer.subprocess, 'run', side_effect=failing_command):
            with self.assertRaisesRegex(RuntimeError, 'verification failed'): installer.install(self.source, self.destination)
        self.assertEqual((self.destination / 'Contents/marker').read_text(), 'old')


if __name__ == '__main__': unittest.main(verbosity=2)
