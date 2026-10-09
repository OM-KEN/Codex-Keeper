import datetime
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "reminder", pathlib.Path(__file__).resolve().parents[1] / "Scripts/check_codex_updates.py")
reminder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reminder)


def release(text, tag="0.163.0"):
    return {"id": tag, "title": tag, "url": "https://github.com/openai/codex/releases/tag/rust-v" + tag,
            "text": text}


class UpdateReminderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = pathlib.Path(self.temp.name) / "state.json"
        self.identity = {"binary": "/Applications/Codex.app/codex", "version": "codex-cli 0.162.0-alpha.2",
                         "sha256": "previous"}
        self.local = patch.object(reminder, "local_identity", return_value=self.identity)
        self.fetch = patch.object(reminder, "fetch_releases", return_value=([release("Changed quota API")], "etag"))
        self.notify = patch.object(reminder, "notify")
        self.local_mock = self.local.start()
        self.fetch_mock = self.fetch.start()
        self.notify_mock = self.notify.start()
        self.addCleanup(self.local.stop)
        self.addCleanup(self.fetch.stop)
        self.addCleanup(self.notify.stop)

    def run_day(self, day):
        reminder.run(self.state, datetime.datetime.fromisoformat(day + "T09:00:00+08:00"))

    def test_initial_baseline_and_unchanged_version_stay_quiet(self):
        self.run_day("2026-10-09")
        self.run_day("2026-10-10")
        self.notify_mock.assert_not_called()

    def test_cli_change_alerts_once_without_running_compatibility_tests(self):
        self.run_day("2026-10-09")
        self.local_mock.return_value = dict(self.identity, version="codex-cli 0.163.0", sha256="new")
        self.run_day("2026-10-10")
        self.run_day("2026-10-11")
        self.notify_mock.assert_called_once()
        self.assertIn("0.163.0", self.notify_mock.call_args.args[0])
        self.assertTrue((self.state.parent / "last-change.md").exists())

    def test_same_version_repackaging_is_detected(self):
        self.run_day("2026-10-09")
        self.local_mock.return_value = dict(self.identity, sha256="repackaged")
        self.run_day("2026-10-10")
        self.notify_mock.assert_called_once()

    def test_desktop_update_is_detected_even_if_cli_is_unchanged(self):
        self.run_day("2026-10-09")
        self.local_mock.return_value = dict(self.identity, desktop={"version": "26.1009", "build": "new"})
        self.run_day("2026-10-10")
        self.run_day("2026-10-11")
        self.notify_mock.assert_called_once()
        self.assertIn("桌面应用", self.notify_mock.call_args.args[0])

    def test_failed_identity_check_preserves_baseline_and_alerts_once(self):
        self.run_day("2026-10-09")
        self.local_mock.side_effect = OSError("CLI missing")
        self.run_day("2026-10-10")
        self.run_day("2026-10-11")
        self.notify_mock.assert_called_once()
        self.local_mock.side_effect = None
        self.local_mock.return_value = dict(self.identity, sha256="new")
        self.run_day("2026-10-12")
        self.assertEqual(self.notify_mock.call_count, 2)

    def test_relevant_release_and_note_edit_are_detected(self):
        self.run_day("2026-10-09")
        self.fetch_mock.return_value = ([release("Changed app-server authentication", "0.164.0")], "next")
        self.run_day("2026-10-10")
        self.notify_mock.assert_called_once()
        self.fetch_mock.return_value = ([release("Changed app-server rate limits", "0.164.0")], "edited")
        self.run_day("2026-10-11")
        self.assertEqual(self.notify_mock.call_count, 2)

    def test_unrelated_release_and_empty_alpha_note_stay_quiet(self):
        self.run_day("2026-10-09")
        self.fetch_mock.return_value = ([release("Fixed keyboard colors", "0.164.0"),
                                        release("Release 0.164.0-alpha.1", "0.164.0-alpha.1")], "next")
        self.run_day("2026-10-10")
        self.notify_mock.assert_not_called()

    def test_304_and_network_failure_preserve_release_baseline(self):
        self.run_day("2026-10-09")
        self.fetch_mock.return_value = (None, "etag")
        self.run_day("2026-10-10")
        self.fetch_mock.side_effect = OSError("network unavailable")
        self.run_day("2026-10-11")
        self.fetch_mock.side_effect = None
        self.fetch_mock.return_value = ([release("Changed quota API")], "etag")
        self.run_day("2026-10-12")
        self.notify_mock.assert_not_called()

    def test_same_day_does_not_check_again(self):
        self.run_day("2026-10-09")
        self.local_mock.reset_mock()
        self.fetch_mock.reset_mock()
        self.run_day("2026-10-09")
        self.local_mock.assert_not_called()
        self.fetch_mock.assert_not_called()

    def test_installation_baseline_before_nine_does_not_skip_daily_check(self):
        self.run_day("2026-10-09")
        state = json.loads(self.state.read_text())
        state["checkedAt"] = "2026-10-09T00:49:07+08:00"
        self.state.write_text(json.dumps(state))
        self.local_mock.reset_mock()
        self.fetch_mock.reset_mock()
        self.run_day("2026-10-09")
        self.local_mock.assert_called_once()
        self.fetch_mock.assert_called_once()

    def test_early_login_waits_for_nine(self):
        self.run_day("2026-10-09")
        self.local_mock.reset_mock()
        self.fetch_mock.reset_mock()
        reminder.run(self.state, datetime.datetime.fromisoformat("2026-10-10T08:00:00+08:00"))
        self.local_mock.assert_not_called()
        self.fetch_mock.assert_not_called()
        self.run_day("2026-10-10")
        self.local_mock.assert_called_once()
        self.fetch_mock.assert_called_once()

    def test_identity_probe_uses_only_identity_mode(self):
        self.local.stop()
        with patch.object(reminder.subprocess, "run") as command:
            command.return_value.stdout = '{"identity":{"binary":"/tmp/codex","version":"codex-cli 1","sha256":"hash"}}'
            result = reminder.local_identity()
            self.assertEqual(result["version"], "codex-cli 1")
            self.assertEqual(command.call_args.args[0][-1], "--identity")
            self.assertNotIn("--check", command.call_args.args[0])

    def test_background_feed_uses_system_https_proxy(self):
        self.fetch.stop()
        proxy = "  HTTPSEnable : 1\n  HTTPSProxy : 127.0.0.1\n  HTTPSPort : 7890\n"
        with patch.dict(os.environ, {}, clear=True), patch.object(reminder.subprocess, "run") as command:
            command.side_effect = [subprocess.CompletedProcess([], 0, stdout=proxy), OSError("stop before network")]
            with self.assertRaises(OSError):
                reminder.fetch_releases(None)
            self.assertEqual(command.call_args_list[0].args[0], ["/usr/sbin/scutil", "--proxy"])
            curl = command.call_args_list[1].args[0]
            self.assertEqual(curl[curl.index("--proxy") + 1], "http://127.0.0.1:7890")

    def test_explicit_proxy_environment_is_preserved(self):
        self.fetch.stop()
        with patch.dict(os.environ, {"https_proxy": "http://proxy.example:8888"}, clear=True):
            with patch.object(reminder.subprocess, "run", side_effect=OSError("stop before network")) as command:
                with self.assertRaises(OSError):
                    reminder.fetch_releases(None)
                self.assertEqual(command.call_args.args[0][0], "/usr/bin/curl")
                self.assertNotIn("--proxy", command.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
