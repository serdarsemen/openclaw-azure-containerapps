import datetime as dt
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "state_maintenance",
    Path(__file__).resolve().parents[1] / "scripts" / "openclaw-state-maintenance.py",
)
maintenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maintenance)


class StateBackupTests(unittest.TestCase):
    def test_two_backups_at_same_time_have_distinct_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            config = data_dir / "openclaw.json"
            config.write_text('{"version": 1}')
            fixed_time = dt.datetime(2026, 9, 6, tzinfo=dt.timezone.utc)
            with patch.object(maintenance.dt, "datetime") as clock:
                clock.now.return_value = fixed_time
                first = maintenance.backup_state(data_dir, 5)
                config.write_text('{"version": 2}')
                second = maintenance.backup_state(data_dir, 5)
            self.assertNotEqual(first, second)
            self.assertEqual((first / "openclaw.json").read_text(), '{"version": 1}')
            self.assertEqual((second / "openclaw.json").read_text(), '{"version": 2}')


if __name__ == "__main__":
    unittest.main()