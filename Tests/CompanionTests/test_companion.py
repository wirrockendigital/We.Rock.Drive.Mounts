"""Unit tests for the Raspberry Pi companion's bounded pure helpers."""

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[2] / "Companion" / "wrdm_companion.py"
SPEC = importlib.util.spec_from_file_location("wrdm_companion", MODULE_PATH)
assert SPEC and SPEC.loader
COMPANION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMPANION)


class CompanionTests(unittest.TestCase):
    """Verify packet construction and capture retention without network access."""

    def test_magic_packet_shape(self) -> None:
        """A valid packet contains six marker bytes and sixteen target copies."""
        packet = COMPANION.magic_packet("9c:76:0e:39:59:12")
        self.assertEqual(len(packet), 102)
        self.assertEqual(packet[:6], b"\xff" * 6)
        self.assertEqual(packet[6:12], bytes.fromhex("9c760e395912"))

    def test_magic_packet_rejects_broadcast(self) -> None:
        """The broadcast address cannot be used as a wake target."""
        with self.assertRaises(ValueError):
            COMPANION.magic_packet("ff:ff:ff:ff:ff:ff")

    def test_capture_retention_removes_oldest_files(self) -> None:
        """Retention satisfies both file-count and byte limits."""
        with tempfile.TemporaryDirectory() as directory:
            previous = COMPANION.CAPTURE_ROOT
            COMPANION.CAPTURE_ROOT = pathlib.Path(directory)
            try:
                for index in range(4):
                    path = COMPANION.CAPTURE_ROOT / f"{index}.pcapng"
                    path.write_bytes(b"x" * 10)
                    path.touch()
                COMPANION.prune_captures(maximum_files=2, maximum_bytes=25)
                self.assertEqual(len(list(COMPANION.CAPTURE_ROOT.glob("*.pcapng"))), 2)
            finally:
                COMPANION.CAPTURE_ROOT = previous

    def test_capture_directory_must_stay_inside_managed_state(self) -> None:
        """Arbitrary remote paths cannot redirect packet evidence outside managed storage."""
        with self.assertRaises(ValueError):
            COMPANION.managed_capture_root("/tmp/unmanaged-captures")

    def test_packet_summary_aggregates_without_endpoint_addresses(self) -> None:
        """Packet summaries expose useful failure metrics while excluding endpoint values."""
        rows = [
            "100.0\teth:ip:tcp:smb2\t1\t0\t\t192.0.2.1\t192.0.2.2",
            "101.5\teth:ip:tcp\t\t1\t\t192.0.2.2\t192.0.2.1",
            "102.0\teth:ip:icmp\t\t\t3\t192.0.2.1\t192.0.2.2",
        ]
        summary = COMPANION.summarize_packet_rows(rows)
        self.assertEqual(summary["packetCount"], 3)
        self.assertEqual(summary["durationSeconds"], 2.0)
        self.assertEqual(summary["protocolCounts"]["tcp"], 2)
        self.assertEqual(summary["tcpRetransmissions"], 1)
        self.assertEqual(summary["tcpResetPackets"], 1)
        self.assertEqual(summary["icmpErrors"], 1)
        self.assertEqual(summary["conversationCount"], 1)
        self.assertFalse(summary["mirrorDuplicationPossible"])
        self.assertNotIn("192.0.2.1", str(summary))

    def test_packet_summary_marks_mixed_vlan_mirror_evidence(self) -> None:
        """Mixed VLAN tagging is marked as a possible mirror duplication source."""
        rows = [
            "100.0\teth:vlan:ip:tcp\t1\t0\t\t192.0.2.1\t192.0.2.2",
            "100.0\teth:ip:tcp\t1\t0\t\t192.0.2.1\t192.0.2.2",
        ]
        summary = COMPANION.summarize_packet_rows(rows)
        self.assertTrue(summary["mirrorDuplicationPossible"])


if __name__ == "__main__":
    unittest.main()
