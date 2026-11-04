import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from upload_testflight import exported_ipa, upload


class TestFlightUploadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def make_ipa(self, name="Pixda.ipa", content=b"exported app"):
        path = self.directory / name
        path.write_bytes(content)
        return path

    def run_upload(self, output, returncode=0):
        result = subprocess.CompletedProcess([], returncode, stdout=output)
        with patch("upload_testflight.subprocess.run", return_value=result) as run:
            with contextlib.redirect_stdout(io.StringIO()):
                upload(self.directory, "test-key", "test-issuer")
        return run.call_args.args[0]

    def test_renamed_app_with_spaces_is_uploaded_as_one_argument(self):
        ipa = self.make_ipa("Pixda Camera.ipa")
        command = self.run_upload("UPLOAD SUCCEEDED with no errors\n")
        self.assertEqual(command[command.index("--file") + 1], str(ipa))

    def test_previous_name_still_works(self):
        ipa = self.make_ipa("LocalCamera.ipa")
        self.assertEqual(exported_ipa(self.directory), ipa)

    def test_missing_export_fails_before_upload(self):
        with patch("upload_testflight.subprocess.run") as run:
            with self.assertRaises(RuntimeError):
                upload(self.directory, "test-key", "test-issuer")
            run.assert_not_called()

    def test_empty_export_fails(self):
        self.make_ipa(content=b"")
        with self.assertRaises(RuntimeError):
            exported_ipa(self.directory)

    def test_multiple_exports_fail_instead_of_picking_old_build(self):
        self.make_ipa()
        self.make_ipa("LocalCamera.ipa")
        with self.assertRaises(RuntimeError):
            exported_ipa(self.directory)

    def test_zero_exit_with_error_does_not_count_as_success(self):
        self.make_ipa()
        with self.assertRaises(RuntimeError):
            self.run_upload("ERROR: File does not exist at path. (13)\n")

    def test_missing_receipt_does_not_count_as_success(self):
        self.make_ipa()
        with self.assertRaises(RuntimeError):
            self.run_upload("")

    def test_nonzero_exit_fails_even_with_receipt(self):
        self.make_ipa()
        with self.assertRaises(RuntimeError):
            self.run_upload("UPLOAD SUCCEEDED with no errors\n", returncode=1)

    def test_archive_receipt_is_accepted(self):
        self.make_ipa()
        self.run_upload("No errors uploading archive at 'Pixda.ipa'.\n")


if __name__ == "__main__":
    unittest.main()
