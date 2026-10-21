import ast
import errno
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock


@unittest.skipUnless(importlib.util.find_spec("fcntl"), "Requires Linux POSIX record locks")
class ArcAgentPackageLockTests(unittest.TestCase):
    def setUp(self):
        self.source_path = pathlib.Path(__file__).resolve().parents[2] / "artifacts" / "installArcAgentUbuntu.sh"
        source = self.source_path.read_text()
        python_source = source.split("<<'PY'\n", 1)[1].split("\nPY", 1)[0]
        tree = ast.parse(python_source)
        self.assertEqual(ast.unparse(tree.body[-1]), "install_agent(sys.argv[1])")
        self.agent = types.ModuleType("arc_agent")
        exec(compile(ast.Module(body=tree.body[:-1], type_ignores=[]), "<actual onboarding script>", "exec"), self.agent.__dict__)
        self.agent.time = types.SimpleNamespace(monotonic=time.monotonic, sleep=time.sleep)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.original_locks = self.agent.APT_LOCKS
        self.agent.APT_LOCKS = tuple(str(self.root / f"lock-{index}") for index in range(4))
        self.attempts = self.root / "attempts"
        self.installer = self.root / "installer.sh"
        self.installer.write_text(f'printf "attempt\\n" >> "{self.attempts}"\n')

    def hold_lock(self, index):
        path = self.agent.APT_LOCKS[index]
        process = subprocess.Popen(
            [sys.executable, "-c", (
                "import fcntl, sys; "
                "lock = open(sys.argv[1], 'w'); "
                "fcntl.lockf(lock, fcntl.LOCK_EX); "
                "print('locked', flush=True); "
                "sys.stdin.read()"
            ), path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.release_lock, process)
        self.assertEqual(process.stdout.readline().strip(), "locked")
        return process

    @staticmethod
    def release_lock(process):
        if not process.stdin.closed:
            process.stdin.close()
        process.wait(timeout=5)
        process.stdout.close()

    def test_waits_for_each_real_posix_lock_before_running_installer(self):
        self.assertEqual(self.original_locks, (
            "/var/lib/dpkg/lock-frontend", "/var/lib/dpkg/lock",
            "/var/lib/apt/lists/lock", "/var/cache/apt/archives/lock",
        ))
        for index in range(4):
            with self.subTest(lock=self.original_locks[index]):
                if self.attempts.exists():
                    self.attempts.unlink()
                process = self.hold_lock(index)

                def release_after_wait(seconds):
                    self.assertFalse(self.attempts.exists(), "Installer ran while the package lock was held")
                    self.assertGreater(seconds, 0)
                    self.release_lock(process)

                with mock.patch.object(self.agent.time, "sleep", side_effect=release_after_wait) as sleep:
                    self.agent.install_agent(str(self.installer))
                sleep.assert_called_once()
                self.assertEqual(self.attempts.read_text().splitlines(), ["attempt"])
                self.assertTrue(pathlib.Path(self.agent.APT_LOCKS[index]).exists(), "Must not remove apt locks")

    def test_existing_unlocked_files_do_not_block_and_missing_files_are_not_created(self):
        pathlib.Path(self.agent.APT_LOCKS[0]).touch()
        with mock.patch.object(self.agent.time, "sleep") as sleep:
            self.agent.install_agent(str(self.installer))
        sleep.assert_not_called()
        self.assertTrue(self.attempts.exists())
        self.assertFalse(pathlib.Path(self.agent.APT_LOCKS[1]).exists())

    def test_persistent_lock_times_out_without_running_installer(self):
        self.hold_lock(0)
        with mock.patch.object(self.agent.time, "monotonic", side_effect=[0, 1799, 1800]), \
                mock.patch.object(self.agent.time, "sleep") as sleep:
            with self.assertRaisesRegex(SystemExit, "still busy.*30-minute"):
                self.agent.install_agent(str(self.installer))
        sleep.assert_called_once_with(1)
        self.assertFalse(self.attempts.exists())

    def test_permission_errors_are_not_treated_as_available_locks(self):
        with mock.patch("builtins.open", side_effect=PermissionError(errno.EACCES, "Permission denied")):
            with self.assertRaises(PermissionError):
                self.agent.install_agent(str(self.installer))
        self.assertFalse(self.attempts.exists())

    def test_retries_vendor_lock_race_but_not_an_unrelated_installation_error(self):
        with self.installer.open("a") as script:
            script.write(f'if [ "$(wc -l < "{self.attempts}")" -eq 1 ]; then\n')
            script.write(f'    echo "{self.agent.LOCK_ERROR} after 5 minutes." >&2\n    exit 1\nfi\n')
        self.agent.install_agent(str(self.installer))
        self.assertEqual(len(self.attempts.read_text().splitlines()), 2)
        self.attempts.unlink()
        self.installer.write_text(f'printf "attempt\\n" >> "{self.attempts}"\necho "Download failed" >&2\nexit 7\n')
        with self.assertRaises(SystemExit) as error:
            self.agent.install_agent(str(self.installer))
        self.assertEqual(error.exception.code, 7)
        self.assertEqual(len(self.attempts.read_text().splitlines()), 1)

    def test_repeated_vendor_contention_uses_original_deadline(self):
        with self.installer.open("a") as script:
            script.write(f'echo "{self.agent.LOCK_ERROR}"\nexit 1\n')
        with mock.patch.object(self.agent.time, "monotonic", side_effect=[0, 1, 1801]):
            with self.assertRaises(SystemExit) as error:
                self.agent.install_agent(str(self.installer))
        self.assertEqual(error.exception.code, 1)
        self.assertEqual(len(self.attempts.read_text().splitlines()), 2)

    def test_actual_shell_entrypoint_retries_lock_failure_and_never_connects_after_other_errors(self):
        bin_directory = self.root / "bin"
        bin_directory.mkdir()

        def command(name, body):
            path = bin_directory / name
            path.write_text("#!/bin/sh\nset -eu\n" + body)
            path.chmod(0o700)

        command("sudo", 'exec "$@"\n')
        command("ufw", "exit 0\n")
        command("wget", 'cp "$TEST_INSTALLER" "$5"\n')
        python_wrapper = self.root / "python-wrapper.py"
        python_wrapper.write_text(
            "import os, sys\n"
            "source = sys.stdin.read().replace('\"/var/', '\"' + os.environ['TEST_ROOT'] + '/var/')\n"
            "sys.argv = sys.argv[1:]\n"
            "exec(compile(source, '<actual onboarding heredoc with isolated lock paths>', 'exec'))\n"
        )
        command("python3", f'exec "{sys.executable}" "{python_wrapper}" "$@"\n')
        environment = {
            **os.environ, "HOME": str(self.root), "PATH": f"{bin_directory}:{os.environ['PATH']}",
            "TEST_INSTALLER": str(self.installer), "TEST_ROOT": str(self.root),
            "resourceGroup": "test-rg", "subscriptionId": "test-subscription",
            "tenantId": "test-tenant", "Azurelocation": "test-region", "accessToken": "synthetic-token",
        }
        self.installer.write_text(f"""
printf 'attempt\\n' >> "$TEST_ROOT/attempts"
if [ "$(wc -l < "$TEST_ROOT/attempts")" -eq 1 ]; then
    echo "{self.agent.LOCK_ERROR}" >&2
    exit 1
fi
cat > "$TEST_ROOT/bin/azcmagent" <<'AGENT'
#!/bin/sh
printf 'connected\\n' > "$TEST_ROOT/connected"
AGENT
chmod +x "$TEST_ROOT/bin/azcmagent"
""")
        result = subprocess.run(["sh", str(self.source_path)], env=environment, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.attempts.read_text().splitlines()), 2)
        self.assertTrue((self.root / "connected").exists())
        (bin_directory / "azcmagent").unlink()
        (self.root / "connected").unlink()
        self.installer.write_text("echo 'Download failed' >&2\nexit 7\n")
        result = subprocess.run(["sh", str(self.source_path)], env=environment, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertFalse((self.root / "connected").exists())


if __name__ == "__main__":
    unittest.main()
