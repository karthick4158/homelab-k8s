"""Photo frame for the e-paper display (apps/media/epaper-photo.yaml).

GET /photo.png  one random photo from PHOTO_DIR, ready for the 960 x 540 e-paper:
                rotated by EXIF, cropped to fill the screen, black and white,
                16 grey levels with dithering, and the month it was taken as a caption.
                Every photo is shown once before any repeats (shuffled deck).
                404 when the folder has no photos (the display then skips the page).
GET /healthz    liveness.
Supported: JPEG, PNG, WebP, HEIC/HEIF (iPhone). Sub-folders are included.
"""
import io
import os
import random
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PIL import Image, ImageDraw, ImageFont, ImageOps
from pillow_heif import register_heif_opener

register_heif_opener()

PHOTO_DIR = os.environ.get("PHOTO_DIR", "/photos")
WIDTH, HEIGHT = 960, 540
EXTENSIONS = (".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif")
FONT = ImageFont.load_default(size=26)
# 16 evenly spaced greys: what the panel can show.
PALETTE = Image.new("P", (1, 1))
PALETTE.putpalette([v for i in range(16) for v in (i * 17,) * 3] + [0] * (256 - 16) * 3)

deck = []


def list_photos():
    found = []
    for root, dirs, files in os.walk(PHOTO_DIR):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        found += [os.path.join(root, f) for f in files
                  if f.lower().endswith(EXTENSIONS) and not f.startswith(".")]
    return found


def next_photo():
    global deck
    photos = set(list_photos())
    deck = [p for p in deck if p in photos]  # forget deleted files
    if not deck:
        deck = list(photos)
        random.shuffle(deck)
    return deck.pop() if deck else None


def caption(img):
    """'March 2024' from EXIF DateTimeOriginal (or DateTime), else None."""
    exif = img.getexif()
    raw = exif.get_ifd(0x8769).get(36867) or exif.get(306)
    try:
        return datetime.strptime(str(raw)[:19], "%Y:%m:%d %H:%M:%S").strftime("%B %Y")
    except (TypeError, ValueError):
        return None


def render(path):
    with Image.open(path) as src:
        label = caption(src)
        img = ImageOps.exif_transpose(src).convert("L")
    img = ImageOps.fit(img, (WIDTH, HEIGHT), Image.LANCZOS, centering=(0.5, 0.4))
    img = ImageOps.autocontrast(img, cutoff=1)
    if label:
        draw = ImageDraw.Draw(img)
        x0, y0, x1, y1 = draw.textbbox((0, 0), label, font=FONT)
        w, h = x1 - x0, y1 - y0
        draw.rounded_rectangle([16, HEIGHT - h - 40, 16 + w + 24, HEIGHT - 16], 8, fill=255)
        draw.text((28 - x0, HEIGHT - h - 28 - y0), label, font=FONT, fill=0)
    img = img.convert("RGB").quantize(palette=PALETTE, dither=Image.Dither.FLOYDSTEINBERG).convert("L")
    out = io.BytesIO()
    img.save(out, "PNG", optimize=True)
    return out.getvalue()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, b"ok", "text/plain")
        if self.path.split("?")[0] != "/photo.png":
            return self.reply(404, b"not found", "text/plain")
        for _ in range(5):  # skip files that fail to open
            path = next_photo()
            if path is None:
                return self.reply(404, b"no photos", "text/plain")
            try:
                return self.reply(200, render(path), "image/png")
            except Exception as e:  # noqa: BLE001 - a bad file must not stop the frame
                print(f"skipping {os.path.basename(path)}: {e}", flush=True)
        self.reply(500, b"no readable photos", "text/plain")

    def reply(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
