import json
from pathlib import Path
import tempfile
import unittest

from camera import filters
from record import Demo, HERE
from scenarios.tmux import CAMERA, CUTS


def luminance(color):
    values = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in values]
    return sum(a * b for a, b in zip(linear, (.2126, .7152, .0722)))


class PipelineTests(unittest.TestCase):
    def test_sidebar_palette_contrast(self):
        settings = dict(line.split(maxsplit=1) for line in (HERE / "kitty.conf").read_text().splitlines() if line.strip())
        bg = luminance(settings["background"])
        for role in ("foreground", "color1", "color2", "color3", "color5", "color7", "color8"):
            self.assertGreaterEqual((luminance(settings[role]) + .05) / (bg + .05), 4.5, role)
        opacity = float(settings["dim_opacity"])
        fg_rgb = [int(settings["color8"][i:i + 2], 16) for i in (1, 3, 5)]
        bg_rgb = [int(settings["background"][i:i + 2], 16) for i in (1, 3, 5)]
        faint = "#" + "".join(f"{round(f * opacity + b * (1 - opacity)):02x}" for f, b in zip(fg_rgb, bg_rgb))
        self.assertGreaterEqual((luminance(faint) + .05) / (bg + .05), 4.5)
        border = settings["active_border_color"]
        self.assertEqual(border, settings["inactive_border_color"])
        self.assertEqual(border, json.loads((HERE / "pi-theme.json").read_text())["vars"]["border"])

    def test_camera_sidebar_is_left_anchored(self):
        timeline = [{"event": e, "seconds": t} for e, t in
                    (("typing start", 2), ("running", 8), ("done", 35), ("verified", 37))]
        with tempfile.TemporaryDirectory() as tmp:
            vf = filters(timeline, 40, Path(tmp), CAMERA, CUTS)
            frames = json.loads((Path(tmp) / "camera.json").read_text())
        self.assertEqual(frames[2]["top_left"], [0, 0])
        self.assertEqual(frames[3]["top_left"], [0, 0])
        self.assertEqual(frames[-1]["zoom"], 1)
        self.assertIn("cos(PI", vf)
        self.assertNotIn("zoompan", vf)
        self.assertNotIn("*iw", vf)
        self.assertTrue(all(1 <= frame["zoom"] <= 1.5 for frame in frames))

    def test_feature_camera_keyframes(self):
        import importlib
        timeline = [{"event": e, "seconds": t} for e, t in
                    (("typing start", 2), ("running", 8), ("child", 18),
                     ("children", 23), ("first reaction", 20), ("done", 80), ("verified", 82))]
        for name in ("tmux", "subagents", "async"):
            scenario = importlib.import_module("scenarios." + name)
            for mobile in (False, True):
                with tempfile.TemporaryDirectory() as tmp:
                    camera = getattr(scenario, "MOBILE_CAMERA", scenario.CAMERA) if mobile else scenario.CAMERA
                    vf = filters(timeline, 85, Path(tmp), camera, scenario.CUTS, mobile=mobile)
                    frames = json.loads((Path(tmp) / ("camera-mobile.json" if mobile else "camera.json")).read_text())
                    self.assertEqual(frames[-1]["zoom"], 1)
                    if name != "tmux":
                        self.assertTrue(any(frame["time"] == 8 and frame["zoom"] == 1 for frame in frames))
                self.assertIn("crop=1080:1350" if mobile else "crop=1600:960", vf)
                self.assertGreaterEqual(scenario.DURATION, 60)
        source = (HERE / "record.py").read_text()
        self.assertIn("set -g extended-keys-format csi-u", source)
        self.assertIn("Mac session is locked", source)

    def test_isolation(self):
        with tempfile.TemporaryDirectory(prefix="kido-demo-", dir="/tmp") as tmp:
            demo = Demo(Path(tmp))
            demo.assert_private()
            self.assertNotIn("TMUX", demo.env)
            self.assertNotIn("TMUX_PANE", demo.env)
            self.assertNotIn("PI_SESSION_ID", demo.env)
            self.assertNotIn("KIDO_AGENT_PARENT_SESSION", demo.env)
            self.assertEqual(demo.env["KITTY_CONFIG_DIRECTORY"], str(HERE))
            demo.env["TMUX_TMPDIR"] = "/tmp"
            with self.assertRaises(AssertionError):
                demo.assert_private()


if __name__ == "__main__":
    unittest.main()
