"""Check that the Ray image ships every file of the patched Ray sources unchanged.

Runs inside a Ray image with `python -m unittest`; RAY_PATCHED_SOURCES points at the
patched `python/ray` tree, and each file there must match the installed `ray` package.
"""

import os
import pathlib
import unittest

import ray


class PatchedFilesTest(unittest.TestCase):
    def test_installed_ray_matches_patched_sources(self):
        patched = pathlib.Path(os.environ["RAY_PATCHED_SOURCES"])
        installed = pathlib.Path(ray.__file__).parent
        sources = sorted(p for p in patched.rglob("*") if p.is_file())
        self.assertTrue(sources, f"no patched sources under {patched}")
        for source in sources:
            relative = source.relative_to(patched)
            with self.subTest(file=str(relative)):
                self.assertEqual(
                    (installed / relative).read_bytes(), source.read_bytes()
                )


if __name__ == "__main__":
    unittest.main()
