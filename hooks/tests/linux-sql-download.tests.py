import os
import pathlib
import shlex
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "Requires Linux and Bash")
class UbuntuSqlDownloadTests(unittest.TestCase):
    def setUp(self):
        self.source_path = pathlib.Path(__file__).resolve().parents[2] / "artifacts" / "InstallNestedSqlServerUbuntu.sh"
        self.assertNotIn(b"\r", self.source_path.read_bytes(), "Linux installer must retain LF line endings")
        self.source = self.source_path.read_text()
        self.helper = self.source.split("\nmode=", 1)[0]
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.environment = {
            **os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
            "TEST_ROOT": str(self.root), "TMPDIR": str(self.root),
            "FAILURES": "1", "CURL_EXIT": "6", "CURL_DELAY": "0",
        }
        self.command("curl", """
printf '%s\\n' "$*" >> "$TEST_ROOT/curl-arguments"
count=$(cat "$TEST_ROOT/count" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$TEST_ROOT/count"
while [ "$1" != -o ]; do shift; done
if [ "$count" -le "$FAILURES" ]; then
    printf 'incomplete' > "$2"
    /bin/sleep "$CURL_DELAY"
    exit "$CURL_EXIT"
fi
printf 'complete' > "$2"
""")
        self.command("sleep", 'printf "%s\\n" "$1" >> "$TEST_ROOT/sleeps"\n')
        self.destination = self.root / "destination"

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\nset -eu\n" + body)
        path.chmod(0o700)

    def download(self, budget=30):
        return subprocess.run(
            ["bash", "-c", self.helper + '\ndownload_sql_file https://example.test/file "$TEST_ROOT/destination" "$1"\n', "test", str(budget)],
            env=self.environment, capture_output=True, text=True, timeout=10,
        )

    def test_retries_only_transient_network_errors_and_publishes_complete_content(self):
        for code in (5, 6, 7, 18, 28, 52, 56):
            with self.subTest(curl_exit=code):
                (self.root / "count").unlink(missing_ok=True)
                self.environment["CURL_EXIT"] = str(code)
                result = self.download()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Transient download failure (curl exit {code})", result.stderr)
                self.assertEqual((self.root / "count").read_text().strip(), "2")
                self.assertEqual(self.destination.read_text(), "complete")
                self.assertFalse(pathlib.Path(str(self.destination) + ".download").exists())

    def test_unrelated_errors_fail_immediately_without_replacing_existing_file(self):
        for code in (22, 23, 60):
            with self.subTest(curl_exit=code):
                (self.root / "count").unlink(missing_ok=True)
                self.destination.write_text("original")
                self.environment["CURL_EXIT"] = str(code)
                result = self.download()
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual((self.root / "count").read_text().strip(), "1")
                self.assertEqual(self.destination.read_text(), "original")
                self.assertFalse((self.root / "sleeps").exists())
                self.assertFalse(pathlib.Path(str(self.destination) + ".download").exists())

    def test_persistent_dns_failure_uses_original_deadline_and_removes_partial_file(self):
        self.environment.update(FAILURES="99", CURL_DELAY="1")
        result = self.download(budget=1)
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertIn("timed out after 1s", result.stderr)
        self.assertEqual((self.root / "count").read_text().strip(), "1")
        self.assertFalse(self.destination.exists())
        self.assertFalse(pathlib.Path(str(self.destination) + ".download").exists())
        self.assertIn("--connect-timeout 30 --max-time 1", (self.root / "curl-arguments").read_text())

    def test_retry_cannot_reset_the_download_deadline(self):
        self.environment.update(FAILURES="99", CURL_DELAY="1")
        result = self.download(budget=2)
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertIn("timed out after 2s", result.stderr)
        self.assertEqual((self.root / "count").read_text().strip(), "2")
        arguments = (self.root / "curl-arguments").read_text().splitlines()
        self.assertIn("--max-time 2", arguments[0])
        self.assertIn("--max-time 1", arguments[1])

    def test_actual_installer_downloads_key_before_gpg_and_stops_before_package_operations_on_failure(self):
        self.command("id", "echo 0\n")
        self.command("gpg", """
for argument; do input=$argument; done
test "$(cat "$input")" = complete
echo verified-input > "$TEST_ROOT/gpg"
""")
        self.command("timeout", 'echo invoked > "$TEST_ROOT/package-operation"\nexit 75\n')
        (self.root / "os-release").write_text("ID=ubuntu\nVERSION_ID=24.04\n")
        (self.root / "sources").mkdir()
        source = self.source.replace(". /etc/os-release", '. "$TEST_ROOT/os-release"')
        source = source.replace("/usr/share/keyrings/microsoft-prod.gpg", str(self.root / "keyring.gpg"))
        source = source.replace("/etc/apt/sources.list.d", str(self.root / "sources"))
        script = self.root / "installer.sh"
        script.write_text(source)
        result = subprocess.run(
            ["bash", str(script), "Evaluation"], input="SyntheticPassword1!\n",
            env=self.environment, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertTrue((self.root / "gpg").exists())
        self.assertTrue((self.root / "package-operation").exists())
        self.assertEqual((self.root / "count").read_text().strip(), "4")
        for arguments in (self.root / "curl-arguments").read_text().splitlines():
            arguments = shlex.split(arguments)
            self.assertGreater(int(arguments[arguments.index("--max-time") + 1]), 0)
            self.assertLessEqual(int(arguments[arguments.index("--max-time") + 1]), 300)
        self.assertFalse(list(self.root.glob("tmp.*")), "Signing key staging file was not cleaned")
        self.assertNotIn("SyntheticPassword", result.stdout + result.stderr + (self.root / "curl-arguments").read_text())

        for path in ("gpg", "package-operation", "count", "curl-arguments"):
            (self.root / path).unlink()
        self.environment["CURL_EXIT"] = "60"
        result = subprocess.run(
            ["bash", str(script), "Developer"], input="SyntheticPassword1!\n",
            env=self.environment, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 60, result.stderr)
        self.assertFalse((self.root / "gpg").exists(), "gpg ran against a failed download")
        self.assertFalse((self.root / "package-operation").exists())
        self.assertFalse(list(self.root.glob("tmp.*")))


if __name__ == "__main__":
    unittest.main()
