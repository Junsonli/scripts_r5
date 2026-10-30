"""Format and failure-mode checks; these do not substitute for game testing."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
EXPORTER = ROOT / "Export-RdfHotspots.py"
SPEC = importlib.util.spec_from_file_location("rfd_hotspot_export", EXPORTER)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
FIXTURE = Path(__file__).parent / "fixtures" / "sample_scene.rfd"


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.text = FIXTURE.read_text(encoding="utf-8")

    def test_fixture_preserves_four_centers_vertex_order_and_unmarked_props(self):
        result = MODULE.parse_snapshot(self.text, "mp_rr_arena_phase_runner", True)
        self.assertEqual(result["prop_count"], 8)
        self.assertEqual(result["hotspots"]["A"]["center"], [100.0, 200.0, 300.0])
        self.assertEqual(result["hotspots"]["B"]["center"], [-100.0, 0.0, 12.5])
        self.assertEqual(result["hotspots"]["A"]["vertices"], [[10.0, 20.0, 30.0], [40.0, 50.0, 60.0], [70.0, 80.0, 90.0]])
        self.assertEqual(result["props"][-1]["tag"], "-")
        self.assertTrue(result["complete_centers"])

    def test_model_catalog_is_not_hardcoded(self):
        result = MODULE.parse_snapshot(self.text.replace("mdl/Humans/class/medium/combat_dummie_medium.rmdl", "mdl/custom/future_marker.rmdl"))
        self.assertEqual(result["props"][-1]["model"], "mdl/custom/future_marker.rmdl")

    def test_partial_work_can_be_exported_but_require_centers_rejects_it(self):
        text = "RFD_EDITOR_V1\nMAP|mp_rr_arena_phase_runner\nEND|0\n"
        self.assertFalse(MODULE.parse_snapshot(text)["complete_centers"])
        with self.assertRaises(MODULE.SnapshotError):
            MODULE.parse_snapshot(text, require_centers=True)

    def test_rejects_truncation_bad_count_wrong_map_and_trailing_commands(self):
        cases = [
            self.text.rsplit("END|8", 1)[0],
            self.text.replace("END|8", "END|7"),
            self.text.replace("MAP|mp_rr_arena_phase_runner", "MAP|../unsafe"),
            self.text + "exec other.cfg\n",
            self.text.replace("RFD_EDITOR_V1", "[editor]legacy log"),
            self.text.replace("|A_center", "|A_center|unexpected", 1),
        ]
        for text in cases:
            with self.subTest(text=text[-80:]), self.assertRaises(MODULE.SnapshotError):
                MODULE.parse_snapshot(text)
        with self.assertRaises(MODULE.SnapshotError):
            MODULE.parse_snapshot(self.text, expected_map="mp_rr_canyonlands_64k_x_64k")

    def test_rejects_nonfinite_extreme_numbers_and_model_path_injection(self):
        for number in ("nan", "inf", "1e999", "1000000.1", "1;quit"):
            with self.subTest(number=number), self.assertRaises(MODULE.SnapshotError):
                MODULE.parse_snapshot(self.text.replace("100.000000", number, 1))
        for model in ("mdl/../bad.rmdl", "mdl//bad.rmdl", 'mdl/bad.rmdl;quit', "file://bad.rmdl"):
            with self.subTest(model=model), self.assertRaises(MODULE.SnapshotError):
                MODULE.parse_snapshot(self.text.replace("mdl/props/death_box/death_box_01.rmdl", model, 1))

    def test_rejects_duplicate_centers_vertices_and_invalid_tags(self):
        for old, new in (("B_center", "A_center"), ("A_vertex_6", "A_vertex_5"), ("A_vertex_5", "A_vertex_0"), ("B_center", "E_center")):
            with self.subTest(tag=new), self.assertRaises(MODULE.SnapshotError):
                MODULE.parse_snapshot(self.text.replace(old, new))

    def test_cli_does_not_damage_source_or_existing_output_on_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "scene.rfd"
            target = Path(directory) / "scene.json"
            source.write_text(self.text, encoding="utf-8")
            original = source.read_bytes()
            good = subprocess.run([sys.executable, str(EXPORTER), str(source), str(target), "--require-centers"], capture_output=True, text=True, timeout=10)
            self.assertEqual(good.returncode, 0, good.stderr)
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(json.loads(target.read_text(encoding="utf-8"))["prop_count"], 8)
            target.write_text("previous export", encoding="utf-8")
            bad = subprocess.run([sys.executable, str(EXPORTER), str(source), str(target)], capture_output=True, text=True, timeout=10)
            self.assertEqual(bad.returncode, 2)
            self.assertEqual(target.read_text(encoding="utf-8"), "previous export")
            source.write_text(self.text.rsplit("END|8", 1)[0], encoding="utf-8")
            truncated = subprocess.run([sys.executable, str(EXPORTER), str(source), str(target), "--force"], capture_output=True, text=True, timeout=10)
            self.assertEqual(truncated.returncode, 2)
            self.assertEqual(target.read_text(encoding="utf-8"), "previous export")

    def test_max_prop_limit(self):
        prop = "PROP|mdl/custom/marker.rmdl|1|2|3|0|0|0|-\n"
        text = "RFD_EDITOR_V1\nMAP|mp_rr_arena_phase_runner\n" + prop * 201 + "END|201\n"
        with self.assertRaises(MODULE.SnapshotError):
            MODULE.parse_snapshot(text)

    def test_exports_three_team_spawns_without_replacing_centers_or_vertices(self):
        rows = "".join(
            f"PROP|mdl/custom/marker.rmdl|{x:.6f}|{y:.6f}|{z:.6f}|0|0|0|{name}_spawn\n"
            for name, (x, y, z) in {
                "A": (1.125, -2.25, 3.5),
                "B": (40.0, 50.0, 60.0),
                "C": (-7.0, 8.0, -9.0),
            }.items()
        )
        text = self.text.replace("END|8", rows + "END|11")
        result = MODULE.parse_snapshot(text, "mp_rr_arena_phase_runner", True)
        expected = {"A": [1.125, -2.25, 3.5], "B": [40.0, 50.0, 60.0], "C": [-7.0, 8.0, -9.0]}
        self.assertEqual(result["spawns"], expected)
        for name, origin in expected.items():
            self.assertEqual(result["hotspots"][name]["spawn"], origin)
        self.assertEqual(result["hotspots"]["A"]["center"], [100.0, 200.0, 300.0])
        self.assertEqual(len(result["hotspots"]["A"]["vertices"]), 3)
        self.assertNotIn("spawn", result["hotspots"]["D"])
        self.assertEqual(result["prop_count"], 11)

    def test_rejects_duplicate_spawns_and_invalid_team_spawn_tags(self):
        row = "PROP|mdl/custom/marker.rmdl|1|2|3|0|0|0|A_spawn\n"
        for rows in (row + row, row + row.replace("A_spawn", "D_spawn"), row + row.replace("A_spawn", "A_spawn_2")):
            text = self.text.replace("END|8", rows + "END|10")
            with self.subTest(rows=rows), self.assertRaises(MODULE.SnapshotError):
                MODULE.parse_snapshot(text)

    def test_legacy_snapshots_without_spawns_remain_valid(self):
        result = MODULE.parse_snapshot(self.text, require_centers=True)
        self.assertEqual(result["spawns"], {"A": None, "B": None, "C": None})
        for group in result["hotspots"].values():
            self.assertNotIn("spawn", group)
        self.assertTrue(result["complete_centers"])


if __name__ == "__main__":
    unittest.main()
