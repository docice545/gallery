"""The offline E2E must reject chrome, a grey grid and a blurred placeholder."""

import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('offline_pixels', Path(__file__).resolve().parents[3] / 'tools/original-noodle-gallery/assert_offline_pixels.py')
pixels = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pixels)


class OfflinePhotoPixelsTests(unittest.TestCase):
    def screenshot(self, positions, colors=None):
        width, height = 240, 480
        data = bytearray([140, 140, 140] * width * height)
        for (left, top), color in zip(positions, colors or pixels.MARKS):
            for y in range(top, top + 20):
                for x in range(left, left + 20):
                    at = (y * width + x) * 3
                    data[at:at + 3] = bytes(color)
        return width, height, bytes(data)

    def test_grey_grid_with_colored_top_and_bottom_bars_fails(self):
        with self.assertRaisesRegex(ValueError, 'markers missing'):
            pixels.check_pixels(*self.screenshot([(50, 20), (50, 440)]))

    def test_blurred_placeholder_and_single_mark_do_not_count_as_decoded_photo(self):
        for args in (self.screenshot([(50, 150), (50, 200)], [(160, 90, 140), (70, 145, 120)]),
                     self.screenshot([(50, 150)])):
            with self.assertRaisesRegex(ValueError, 'markers missing'):
                pixels.check_pixels(*args)

    def test_both_decoded_markers_in_photo_area_pass(self):
        self.assertEqual(pixels.check_pixels(*self.screenshot([(50, 150), (50, 200)])), [324, 324])

    def test_invalid_capture_fails_closed(self):
        with self.assertRaises(ValueError):
            pixels.check_pixels(240, 480, b'')
        with self.assertRaises(ValueError):
            pixels.check_pixels(4000, 4000, b'')


if __name__ == '__main__':
    unittest.main()
