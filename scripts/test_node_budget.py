import unittest
import os
import sys
import importlib.util

# Allow importing from the scripts directory
scripts_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, scripts_dir)

# node-budget.py has a hyphen, so load it explicitly
spec = importlib.util.spec_from_file_location("node_budget", os.path.join(scripts_dir, "node-budget.py"))
node_budget = importlib.util.module_from_spec(spec)
sys.modules["node_budget"] = node_budget
spec.loader.exec_module(node_budget)

disk_line = node_budget.disk_line


class TestNodeBudgetDisk(unittest.TestCase):
    def test_disk_line_no_warning_below_threshold(self):
        summary = {
            "node": {
                "fs": {
                    "capacityBytes": 216.5 * (1024 ** 3),
                    "usedBytes": 181.6 * (1024 ** 3),
                    "availableBytes": 25.1 * (1024 ** 3),
                }
            }
        }
        line = disk_line(summary)
        self.assertIsNotNone(line)
        self.assertIn("83.9 %", line)
        self.assertIn("25.1 GiB free", line)
        self.assertNotIn("WARNING", line)

    def test_disk_line_warns_at_threshold(self):
        capacity = 100 * (1024 ** 3)
        summary = {
            "node": {
                "fs": {
                    "capacityBytes": capacity,
                    "usedBytes": int(0.85 * capacity),
                    "availableBytes": int(0.15 * capacity),
                }
            }
        }
        line = disk_line(summary)
        self.assertIsNotNone(line)
        self.assertIn("WARNING", line)

    def test_disk_line_none_when_no_fs(self):
        summary = {"node": {}}
        self.assertIsNone(disk_line(summary))
        summary = {}
        self.assertIsNone(disk_line(summary))

    def test_disk_line_percent_and_values(self):
        capacity = 216.5 * (1024 ** 3)
        used = 181.6 * (1024 ** 3)
        available = 25.1 * (1024 ** 3)
        summary = {"node": {"fs": {"capacityBytes": capacity, "usedBytes": used, "availableBytes": available}}}
        line = disk_line(summary)
        self.assertIsNotNone(line)
        self.assertIn("83.9 %", line)
        self.assertIn("25.1 GiB free", line)


if __name__ == "__main__":
    unittest.main()
