import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCAN_PATH = ROOT / "scripts" / "scan.py"


class SmokeTest(unittest.TestCase):
    def test_scan_script_loads(self):
        self.assertTrue(SCAN_PATH.is_file(), "scripts/scan.py missing")
        spec = importlib.util.spec_from_file_location("scan", SCAN_PATH)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        for attr in ("categories", "scan_tree", "scan_history"):
            self.assertTrue(callable(getattr(mod, attr, None)), f"missing {attr}")


if __name__ == "__main__":
    unittest.main()
