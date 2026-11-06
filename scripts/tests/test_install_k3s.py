"""The home-k3s installer's kubelet eviction floors (platform#549).

k3s writes ``evictionHard`` as a *percentage* into the generated kubelet config
(``nodefs.available: 5%``, ``imagefs.available: 5%`` on v1.37), which on the 216 GiB dev
volume reserves ~10.8 GiB. The installer replaces that with an absolute floor so the
guard scales with the platform (which runs in ~16 GiB), not with the disk.

Both signals need the absolute floor. On a single-node install imagefs and nodefs are
the same ext4 volume, so the kubelet evicts when *either* line is crossed: an
``imagefs.available<10 %`` would set the effective line at ~21.6 GiB — twice the default
it meant to remove, and pods would be evicted while tens of GiB were free (platform#549).
"""

import re
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "dev" / "home-k3s" / "install-k3s.sh"

FLAG = re.compile(r"--kubelet-arg=eviction-hard=([^'\"\s]+)")


def eviction_hard():
    """The `eviction-hard` map the installer passes, e.g. {"nodefs.available": "5Gi"}."""
    match = FLAG.search(SCRIPT.read_text())
    if match is None:
        raise AssertionError(f"{SCRIPT} passes no --kubelet-arg=eviction-hard")
    return dict(part.split("<", 1) for part in match.group(1).split(","))


class EvictionHard(unittest.TestCase):
    def test_both_filesystem_signals_are_set(self):
        floors = eviction_hard()
        self.assertEqual(
            sorted(floors), ["imagefs.available", "nodefs.available"]
        )

    def test_the_floor_is_absolute_on_every_signal(self):
        for signal, value in eviction_hard().items():
            self.assertTrue(
                value.endswith("Gi"),
                f"{signal}={value} is not an absolute floor; a percentage scales "
                "with the disk and imagefs shares nodefs's volume here",
            )
            self.assertNotIn("%", value, signal)

    def test_the_floor_is_five_gib(self):
        self.assertEqual(
            eviction_hard(),
            {"nodefs.available": "5Gi", "imagefs.available": "5Gi"},
        )


if __name__ == "__main__":
    unittest.main()
