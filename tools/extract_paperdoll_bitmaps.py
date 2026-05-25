#!/usr/bin/env python3
"""Extract embedded JPEG bitmaps from paper-doll outfit SWFs into PNG-friendly
files so an HTML5 dress-up game can composite them as <img> layers.

The 130 outfit SWFs under mirror/www.americangirl.com/agcn/paperdoll/
doll_outfits/<Character>/<piece>.swf each embed 1-2 JPEGs:
  - the piece artwork (e.g. dress, hat, shoes)
  - sometimes a thumbnail for the picker

We walk the SWF tag stream, pull DefineBitsJPEG{2,3,4} payloads, and write
them as <Character>__<piece>.jpg under build/paperdoll_assets/.
"""
from __future__ import annotations
import os
import re
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "mirror/www.americangirl.com/agcn/paperdoll/doll_outfits"
OUT = ROOT / "build/paperdoll_assets"

# SWF tag codes we care about
TAG_DEFINE_BITS         = 6
TAG_JPEG_TABLES         = 8
TAG_DEFINE_BITS_JPEG2   = 21
TAG_DEFINE_BITS_JPEG3   = 35
TAG_DEFINE_BITS_LOSSLESS = 20
TAG_DEFINE_BITS_LOSSLESS2 = 36
TAG_DEFINE_BITS_JPEG4   = 90


def parse_rect(data: bytes, pos: int) -> int:
    """Skip a RECT structure. Returns new bit offset (byte-aligned)."""
    nbits = data[pos] >> 3   # first 5 bits = nbits per field
    total_bits = 5 + nbits * 4
    return pos + (total_bits + 7) // 8


def iter_tags(body: bytes):
    """Yield (tag_code, payload_bytes) for each tag in an uncompressed SWF
    body (after the 8-byte header)."""
    pos = 0
    # Skip RECT (frame size)
    pos = parse_rect(body, pos)
    # Skip frame rate (2 bytes) + frame count (2 bytes)
    pos += 4
    while pos < len(body):
        if pos + 2 > len(body): break
        tag_header = struct.unpack("<H", body[pos:pos+2])[0]
        pos += 2
        tag_code = tag_header >> 6
        length = tag_header & 0x3F
        if length == 0x3F:   # long-form: next 4 bytes = length
            length = struct.unpack("<I", body[pos:pos+4])[0]
            pos += 4
        payload = body[pos:pos+length]
        pos += length
        yield tag_code, payload
        if tag_code == 0:   # End tag
            break


def _decompress_body(raw: bytes) -> bytes | None:
    sig = raw[:3]
    if sig == b'CWS':
        return zlib.decompress(raw[8:])
    if sig == b'FWS':
        return raw[8:]
    if sig == b'ZWS':
        import lzma
        return lzma.decompress(raw[12:17] + raw[17:], format=lzma.FORMAT_ALONE)
    return None


def extract_images_from_swf(swf_path: Path) -> list:
    """Return a list of PIL.Image (RGBA) for each bitmap tag in the SWF.

    Handles DefineBits(+JPEGTables), DefineBitsJPEG2 (opaque), and
    DefineBitsJPEG3 (JPEG + zlib alpha → real transparency)."""
    from io import BytesIO
    from PIL import Image
    raw = swf_path.read_bytes()
    body = _decompress_body(raw)
    if body is None:
        return []
    images = []
    jpeg_tables = None
    for tag_code, payload in iter_tags(body):
        if tag_code == TAG_JPEG_TABLES:
            jpeg_tables = payload
        elif tag_code == TAG_DEFINE_BITS:
            jpeg = payload[2:]
            if jpeg_tables and jpeg_tables[:2] == b'\xff\xd8':
                jpeg = jpeg_tables[:-2] + jpeg[2:]
            try:
                images.append(Image.open(BytesIO(jpeg)).convert("RGBA"))
            except Exception:
                pass
        elif tag_code == TAG_DEFINE_BITS_JPEG2:
            try:
                images.append(Image.open(BytesIO(payload[2:])).convert("RGBA"))
            except Exception:
                pass
        elif tag_code == TAG_DEFINE_BITS_JPEG3:
            char_id, alpha_off = struct.unpack("<HI", payload[:6])
            jpeg = payload[6:6+alpha_off]
            alpha_zlib = payload[6+alpha_off:]
            try:
                img = Image.open(BytesIO(jpeg)).convert("RGBA")
                if alpha_zlib:
                    alpha_bytes = zlib.decompress(alpha_zlib)
                    w, h = img.size
                    if len(alpha_bytes) >= w * h:
                        alpha = Image.frombytes("L", (w, h), alpha_bytes[:w*h])
                        img.putalpha(alpha)
                images.append(img)
            except Exception:
                pass
    return images


def main():
    if not SRC.exists():
        print(f"{SRC} not found", file=sys.stderr); sys.exit(1)
    OUT.mkdir(parents=True, exist_ok=True)
    total_swfs = total_imgs = 0
    for char_dir in sorted(SRC.iterdir()):
        if not char_dir.is_dir(): continue
        for swf in sorted(char_dir.glob("*.swf")):
            total_swfs += 1
            try:
                imgs = extract_images_from_swf(swf)
            except Exception as e:
                print(f"  {swf.name}: extract failed: {e}", file=sys.stderr)
                continue
            # Keep only the largest image per SWF (the piece artwork; any
            # 2nd image is usually a tiny picker thumbnail we don't need).
            if imgs:
                imgs.sort(key=lambda im: im.size[0] * im.size[1], reverse=True)
                out_name = f"{char_dir.name}__{swf.stem}.png"
                imgs[0].save(OUT / out_name)
                total_imgs += 1
            else:
                print(f"  {char_dir.name}/{swf.name}: no bitmap", file=sys.stderr)
    print(f"Extracted {total_imgs} PNGs from {total_swfs} SWFs into {OUT}")


if __name__ == "__main__":
    main()
