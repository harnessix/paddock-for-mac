#!/usr/bin/env python3
"""Put the toon sprites into the asset catalog, one image set per file.

  import-room-art.py SPRITES_DIR

SPRITES_DIR is the output of the sprite export (export-sprites.mjs): the
512 x 512 PNG files, rooms.json and README.txt. The script writes
App/Assets.xcassets/Rooms/NAME.imageset for each PNG and copies rooms.json
into Rooms/rooms.dataset, unchanged.

Names: the export counts the frames of a loop from 0, the app from 1, so
character-blue-idle-0.png becomes the image set character-blue-idle-1.
Rooms keep their names. Each PNG goes in the 2x slot (256 x 256 pt).

The PNG files are compressed losslessly with oxipng (level 6, alpha
optimized: the color of a fully transparent pixel is free), so the app
bundle stays small. It needs `pip install pyoxipng`, or run it with
`uv run --with pyoxipng Scripts/import-room-art.py SPRITES_DIR`.
An image set that is no longer in SPRITES_DIR is removed.
"""

import json
import pathlib
import re
import shutil
import sys

import oxipng

ROOT = pathlib.Path(__file__).resolve().parent.parent
ROOMS = ROOT / "App" / "Assets.xcassets" / "Rooms"
FRAME = re.compile(r"^(character-[a-z]+-[a-z]+)-(\d+)$")
ROOM = re.compile(r"^room-[a-z-]+$")


def set_name(stem: str) -> str | None:
    """The image set name of a PNG file stem, or None to skip the file."""
    match = FRAME.match(stem)
    if match:
        return f"{match.group(1)}-{int(match.group(2)) + 1}"
    if ROOM.match(stem):
        return stem
    return None


def contents(filename: str) -> str:
    return json.dumps({
        "images": [
            {"idiom": "universal", "scale": "1x"},
            {"filename": filename, "idiom": "universal", "scale": "2x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }, indent=2) + "\n"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    source = pathlib.Path(sys.argv[1])
    pngs = sorted(source.glob("*.png"))
    if not pngs:
        print(f"no PNG files in {source}", file=sys.stderr)
        return 1
    wanted = set()
    before = after = 0
    for png in pngs:
        name = set_name(png.stem)
        if name is None:
            print(f"skipped: {png.name}", file=sys.stderr)
            continue
        if name in wanted:
            print(f"two files for {name}", file=sys.stderr)
            return 1
        wanted.add(name)
        folder = ROOMS / f"{name}.imageset"
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / f"{name}.png"
        oxipng.optimize(png, target, level=6, strip=oxipng.StripChunks.safe(), optimize_alpha=True)
        (folder / "Contents.json").write_text(contents(target.name))
        before += png.stat().st_size
        after += target.stat().st_size
    for folder in ROOMS.glob("*.imageset"):
        if folder.name.removesuffix(".imageset") not in wanted:
            shutil.rmtree(folder)
    manifest = source / "rooms.json"
    if manifest.exists():
        shutil.copyfile(manifest, ROOMS / "rooms.dataset" / "rooms.json")
    print(f"{len(wanted)} image sets, {before / 1e6:.2f} MB of PNG in, {after / 1e6:.2f} MB out")
    return 0


if __name__ == "__main__":
    sys.exit(main())
