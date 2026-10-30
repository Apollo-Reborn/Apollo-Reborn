#!/usr/bin/env python3
import importlib.util
import json
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR_PATH = ROOT / "theme-gallery" / "scripts" / "generate_catalog.py"
THEMES_PATH = ROOT / "theme-gallery" / "themes"

spec = importlib.util.spec_from_file_location("theme_gallery_generator", GENERATOR_PATH)
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    check(generator.contrast_ratio("ABB2B9", "ABB2B9") == 1.0,
          "identical read and unread title colors must be detected")
    check(generator.contrast_ratio("ABB2B9", "777D83") >= 1.5,
          "GitHub Dark's repaired read title remains visibly muted")

    with tempfile.TemporaryDirectory() as directory:
        bad_path = Path(directory) / "bad-read-state.json"
        bad_theme = json.loads((THEMES_PATH / "github-dark.json").read_text())
        bad_theme["slug"] = bad_path.stem
        bad_theme["input"]["dark"]["mutedText"] = bad_theme["input"]["dark"]["text"]
        bad_path.write_text(json.dumps(bad_theme))
        try:
            generator.load_theme(bad_path)
        except SystemExit as error:
            check("visually indistinguishable" in str(error),
                  "invalid theme should fail for the read-state contrast reason")
        else:
            raise AssertionError("catalog accepted identical read and unread title colors")

    paths = sorted(THEMES_PATH.glob("*.json"))
    check(paths, "theme gallery must contain theme definitions")
    for path in paths:
        generator.load_theme(path)

    print(f"theme gallery contrast tests passed ({len(paths)} themes)")


if __name__ == "__main__":
    main()
