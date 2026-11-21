"""CleanCut: remove scenes from a movie and keep the original as a .orig backup.

One file, Python standard library only. Needs ffmpeg + ffprobe on PATH.
Flow for a movie "X.mkv":
  1. ffmpeg cuts from the backup "X.mkv.orig" if it exists, else from "X.mkv",
     and writes "X.mkv.part" (media apps ignore .part / .orig files).
  2. On success: "X.mkv" -> "X.mkv.orig" (only if no backup exists yet),
     then "X.mkv.part" -> "X.mkv". On failure the .part file is deleted.
  3. Cut times are saved in "X.mkv.cuts.txt" and always refer to the original.
  4. Restore: "X.mkv.orig" -> "X.mkv" (replaces the clean copy).
"""
import html
import json
import os
import re
import subprocess
import threading
import time
import urllib.parse
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MOVIES_DIR = os.path.realpath(os.environ.get("MOVIES_DIR", "/data/Video/Movies"))
PORT = int(os.environ.get("PORT", "8080"))
VIDEO_EXT = (".mkv", ".mp4")

job = {"state": "idle", "movie": "", "percent": 0, "message": "", "started": 0}
job_lock = threading.Lock()


# ---------- helpers ----------

def safe_path(rel):
    """Resolve a path relative to MOVIES_DIR, refusing anything outside it."""
    p = os.path.realpath(os.path.join(MOVIES_DIR, rel))
    if not p.startswith(MOVIES_DIR + os.sep) or not p.lower().endswith(VIDEO_EXT):
        raise ValueError("bad path")
    return p


def list_movies():
    """Video files up to two folders deep, plus movies that only have a backup left."""
    found = set()
    base_depth = MOVIES_DIR.rstrip(os.sep).count(os.sep)
    for root, dirs, files in os.walk(MOVIES_DIR):
        if root.count(os.sep) - base_depth >= 2:
            dirs[:] = []
        for f in files:
            name = f[:-5] if f.endswith(".orig") else f
            if name.lower().endswith(VIDEO_EXT):
                found.add(os.path.relpath(os.path.join(root, name), MOVIES_DIR))
    return sorted(found, key=str.lower)


def to_seconds(t):
    t = t.strip()
    if not re.fullmatch(r"\d+(:\d{1,2}){0,2}(\.\d+)?", t):
        raise ValueError(f"'{t}' is not a time (use 1:23:45, 3:20 or 200)")
    secs = 0.0
    for part in t.split(":"):
        secs = secs * 60 + float(part)
    return secs


def parse_cuts(text, duration):
    """'3:20-5:38' per line (or comma separated) -> sorted, merged [(start, end)]."""
    cuts = []
    for item in re.split(r"[\n,;]+", text):
        item = item.split("#")[0].strip()
        if not item:
            continue
        if "-" not in item:
            raise ValueError(f"'{item}' needs a start and an end, like 3:20-5:38")
        a, b = item.split("-", 1)
        s, e = to_seconds(a), to_seconds(b)
        if e <= s:
            raise ValueError(f"'{item}': end must be after start")
        if s >= duration:
            raise ValueError(f"'{item}' starts after the movie ends ({fmt(duration)})")
        cuts.append((s, min(e, duration)))
    if not cuts:
        raise ValueError("add at least one scene to cut")
    cuts.sort()
    merged = [list(cuts[0])]
    for s, e in cuts[1:]:
        if s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    return [tuple(c) for c in merged]


def fmt(sec):
    sec = int(round(sec))
    return f"{sec // 3600}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def probe_duration(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
        capture_output=True, text=True, timeout=120)
    return float(out.stdout.strip())


def read_cuts_file(movie):
    try:
        with open(movie + ".cuts.txt") as f:
            return f.read()
    except OSError:
        return ""


# ---------- the cut job ----------

def run_cut(movie, cuts_text):
    orig = movie + ".orig"
    part = movie + ".part"
    try:
        source = orig if os.path.exists(orig) else movie
        duration = probe_duration(source)
        cuts = parse_cuts(cuts_text, duration)
        keep = duration - sum(e - s for s, e in cuts)
        with open(movie + ".cuts.txt", "w") as f:
            f.write("\n".join(f"{fmt(s)}-{fmt(e)}" for s, e in cuts) + "\n")

        expr = "+".join(f"between(t,{s:.3f},{e:.3f})" for s, e in cuts)
        out_fmt = "mp4" if movie.lower().endswith(".mp4") else "matroska"
        cmd = ["ffmpeg", "-hide_banner", "-nostats", "-loglevel", "error", "-y",
               "-i", source,
               "-map", "0:v:0", "-map", "0:a:0?", "-map_chapters", "-1",
               "-vf", f"select='not({expr})',setpts=N/FRAME_RATE/TB",
               "-af", f"aselect='not({expr})',asetpts=N/SR/TB",
               "-c:v", "libx264", "-crf", "18", "-preset", "veryfast",
               "-c:a", "aac", "-b:a", "192k",
               "-progress", "pipe:1", "-f", out_fmt, part]
        errors = deque(maxlen=15)
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        threading.Thread(target=lambda: errors.extend(proc.stderr), daemon=True).start()
        for line in proc.stdout:
            if line.startswith("out_time_us="):
                try:
                    done = int(line.split("=")[1]) / 1e6
                    job["percent"] = max(0, min(99, int(done / keep * 100)))
                except ValueError:
                    pass
        if proc.wait() != 0:
            raise RuntimeError("ffmpeg failed: " + " ".join(e.strip() for e in errors)[-600:])

        if not os.path.exists(orig):
            os.rename(movie, orig)
        os.replace(part, movie)
        mins = (time.time() - job["started"]) / 60
        job.update(state="done", percent=100,
                   message=f"Done in {mins:.0f} min. Removed {len(cuts)} scene(s), "
                           f"new length {fmt(keep)}. Original kept as .orig.")
    except Exception as e:  # noqa: BLE001 - show any failure on the page
        if os.path.exists(part):
            os.remove(part)
        job.update(state="failed", message=str(e))


def start_cut(movie, cuts_text):
    with job_lock:
        if job["state"] == "running":
            raise ValueError(f"Already working on {os.path.basename(job['movie'])}, please wait.")
        job.update(state="running", movie=movie, percent=0, message="Starting...", started=time.time())
    threading.Thread(target=run_cut, args=(movie, cuts_text), daemon=True).start()


def restore(movie):
    if job["state"] == "running" and job["movie"] == movie:
        raise ValueError("This movie is being cut right now.")
    orig = movie + ".orig"
    if not os.path.exists(orig):
        raise ValueError("No backup (.orig) found for this movie.")
    os.replace(orig, movie)


# ---------- web pages ----------

CSS = """
:root{--bg:#f6f7fb;--card:#fff;--text:#1c2030;--muted:#667;--accent:#5b5bd6;--bad:#c33;--ok:#178a50;--line:#dde}
@media (prefers-color-scheme:dark){:root{--bg:#14161f;--card:#1e2130;--text:#e8e9f0;--muted:#9aa;--line:#334}}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.5 system-ui,sans-serif}
main{max-width:760px;margin:0 auto;padding:16px}
a{color:var(--accent);text-decoration:none}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin:12px 0}
input,textarea{width:100%;box-sizing:border-box;padding:10px;border:1px solid var(--line);border-radius:8px;
 background:var(--bg);color:var(--text);font:inherit}
textarea{min-height:180px;font-family:ui-monospace,monospace}
button{background:var(--accent);color:#fff;border:0;border-radius:8px;padding:10px 16px;font:inherit;cursor:pointer}
button.secondary{background:transparent;color:var(--accent);border:1px solid var(--accent)}
ul{list-style:none;padding:0;margin:0} li{padding:8px 0;border-bottom:1px solid var(--line)}
.tag{font-size:12px;padding:2px 8px;border-radius:99px;background:var(--ok);color:#fff;margin-left:6px}
.muted{color:var(--muted)} .bad{color:var(--bad)} .ok{color:var(--ok)}
.bar{height:10px;background:var(--line);border-radius:99px;overflow:hidden}
.bar div{height:100%;background:var(--accent)}
"""

STATUS_JS = """
<script>
async function poll(){
  try{
    const j = await (await fetch('status')).json();
    const el = document.getElementById('status');
    if(!el) return;
    if(j.state==='idle'){ el.innerHTML=''; return; }
    const name = j.movie.split('/').pop();
    let h = '<div class="card"><b>' + name + '</b> ';
    if(j.state==='running') h += '<span class="muted">cutting, ' + j.percent + '%</span>' +
        '<div class="bar"><div style="width:' + j.percent + '%"></div></div>';
    else h += '<div class="' + (j.state==='done'?'ok':'bad') + '">' + j.message.replace(/</g,'&lt;') + '</div>';
    el.innerHTML = h + '</div>';
    if(j.state==='running') setTimeout(poll, 3000);
  }catch(e){ setTimeout(poll, 5000); }
}
poll();
</script>
"""


def page(title, body):
    return f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{html.escape(title)}</title>
<style>{CSS}</style></head><body><main><h1><a href="./">CleanCut</a></h1>
<div id="status"></div>{body}</main>{STATUS_JS}</body></html>"""


def home_page():
    items = []
    for rel in list_movies():
        full = os.path.join(MOVIES_DIR, rel)
        tag = '<span class="tag">cleaned</span>' if os.path.exists(full + ".orig") else ""
        items.append(f'<li data-name="{html.escape(rel.lower())}">'
                     f'<a href="movie?path={urllib.parse.quote(rel)}">{html.escape(os.path.basename(rel))}</a>{tag}</li>')
    body = f"""<div class="card"><input id="q" placeholder="Search movies" autofocus
 oninput="for(const li of document.querySelectorAll('li'))li.hidden=!li.dataset.name.includes(this.value.toLowerCase())">
<ul>{''.join(items) or '<li class="muted">No movies found</li>'}</ul></div>"""
    return page("CleanCut", body)


def movie_page(rel, error="", cuts_text=None):
    movie = safe_path(rel)
    has_orig = os.path.exists(movie + ".orig")
    source = movie + ".orig" if has_orig else movie
    try:
        length = fmt(probe_duration(source))
    except Exception:  # noqa: BLE001
        length = "unknown"
    cuts = html.escape(read_cuts_file(movie) if cuts_text is None else cuts_text)
    q = html.escape(rel)
    restore_btn = ("""<form method="post" action="restore" onsubmit="return confirm('Put the original back?')">
<input type="hidden" name="path" value="%s"><button class="secondary">Restore original</button></form>""" % q
                   if has_orig else "")
    note = ("This movie is already cleaned. Times below refer to the <b>original</b>, "
            "and a new run starts again from the original." if has_orig else
            "The original will be kept next to it as <code>.orig</code>.")
    err = f'<p class="bad">{html.escape(error)}</p>' if error else ""
    body = f"""<div class="card"><h2>{html.escape(os.path.basename(rel))}</h2>
<p class="muted">Original length {length}. {note}</p>{err}
<form method="post" action="cut"><input type="hidden" name="path" value="{q}">
<p>Scenes to remove, one per line, start-end (for example <code>3:20-5:38</code> or <code>1:53:03-1:53:35</code>):</p>
<textarea name="cuts" placeholder="3:20-5:38">{cuts}</textarea>
<p><button>Make clean copy</button></p></form>{restore_btn}</div>"""
    return page(os.path.basename(rel), body)


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, where):
        self.send_response(303)
        self.send_header("Location", where)
        self.end_headers()

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(url.query)
        try:
            if url.path == "/":
                self.send(200, home_page())
            elif url.path == "/movie":
                self.send(200, movie_page(qs.get("path", [""])[0]))
            elif url.path == "/status":
                self.send(200, json.dumps({k: job[k] for k in ("state", "movie", "percent", "message")}),
                          "application/json")
            elif url.path == "/healthz":
                self.send(200, "ok", "text/plain")
            else:
                self.send(404, page("Not found", "<p>Not found</p>"))
        except ValueError as e:
            self.send(400, page("Error", f'<p class="bad">{html.escape(str(e))}</p>'))

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        form = urllib.parse.parse_qs(self.rfile.read(length).decode(), keep_blank_values=True)
        rel = form.get("path", [""])[0]
        try:
            movie = safe_path(rel)
            if self.path == "/cut":
                cuts_text = form.get("cuts", [""])[0]
                parse_cuts(cuts_text, float("inf"))  # quick check before starting
                start_cut(movie, cuts_text)
            elif self.path == "/restore":
                restore(movie)
            else:
                return self.send(404, "not found", "text/plain")
            self.redirect("movie?path=" + urllib.parse.quote(rel))
        except ValueError as e:
            try:
                self.send(400, movie_page(rel, str(e), form.get("cuts", [None])[0]))
            except ValueError:
                self.send(400, page("Error", f'<p class="bad">{html.escape(str(e))}</p>'))

    def log_message(self, fmt_, *args):
        if not self.path.startswith(("/status", "/healthz")):
            super().log_message(fmt_, *args)


if __name__ == "__main__":
    print(f"CleanCut on :{PORT}, movies in {MOVIES_DIR}", flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
