#!/usr/bin/env python3
"""
KerneLUA backend — Linux port of kernelua_backend.exe.

The Windows backend is a console PE that (per import table + embedded JS):
  - holds a single-instance mutex (OpenMutexW in the proxy DLL gates it),
  - injects a Steam-UI script into the CEF client (steamclientwebhelper),
  - exposes an in-page RPC (__KERNELUA_RPC__) used by that script,
  - downloads per-app config packages from kernelos.org with token auth
    (WINHTTP + bcrypt token hashing),
  - applies / removes them.

This port keeps stdlib-only Python:
  - single instance via the abstract unix socket @kernelua_backend
    (the loader probes the same socket before spawning us),
  - CEF attach over the Chrome DevTools Protocol — port discovered at runtime
    (our forced 9222 via the loader rewrite, or Steam's own hard-coded 8080),
  - injection via Page.addScriptToEvaluateOnNewDocument + Runtime.addBinding
    (the binding replaces the in-process hook the DLL used for RPC),
  - the same RPC surface: GetStatus / hasLuaForApp / addViaKernelua /
    RemoveViaKernelua / saveToken / getToken.

Endpoint discovery / peer auth / UI-ready gating ported from
swwayps/luatools-moon (Lumen: cefport.lua, peerauth.lua, injector.lua).

NOTE on upstream endpoints: the exact kernelos.org API paths are not
published in the client strings (the JS only talks to the local backend).
The two upstream URLs below are inferred from the site's described flow
("enter the AppID -> .lua or .zip is served") and are isolated in CFG so
they can be corrected in one place after checking against the live API.
"""

import base64
import hashlib
import json
import os
import secrets
import socket
import struct
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

# ----------------------------------------------------------------- config

CFG = {
    "cdp_host": "127.0.0.1",
    # CEF remote-debugging port candidates, probed in order (luatools-moon /
    # Lumen cefport pattern): env override, our forced 9222 (loader rewrite),
    # then Steam's own hard-coded 8080 (vanilla steamwebhelper / Decky-style).
    "cdp_ports": tuple(
        p for p in (
            int(os.environ["KERNELUA_CDP_PORT"]) if os.environ.get("KERNELUA_CDP_PORT", "").isdigit() else None,
            9222,
            8080,
        ) if p is not None
    ),
    "api_base": os.environ.get("KERNELUA_API_BASE", "https://kernelos.org/games"),
    # inferred — verify against the live site API and fix here
    "api_haslua": "/api/haslua?appid={appid}",
    "api_getlua": "/api/getlua?appid={appid}",
    "state_dir": os.environ.get("KERNELUA_STATE_DIR", os.path.expanduser("~/.kernelua")),
    "sock_name": "\0kernelua_backend",
    "binding": "__kernelua_call",
    "poll_interval": 2.0,
    "cdp_ready_timeout": 120.0,
}

# token header is inferred as well; send both common shapes
TOKEN_HEADERS = ("X-Kernelua-Token", "Authorization")

# expected version of inject.js — bumped whenever the UI script changes;
# pages carrying an older version are reloaded so the new one takes over
INJECT_VERSION = 3

LOG_PATH = os.path.join(CFG["state_dir"], "backend.log")


def log(msg):
    line = f"kernelua_backend: {msg}"
    print(line, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


# ----------------------------------------------------------------- state

class State:
    def __init__(self, root):
        self.root = root
        self.games_dir = os.path.join(root, "games")
        os.makedirs(self.games_dir, exist_ok=True)
        self.token_path = os.path.join(root, "token")
        self.run = {"inProgress": False, "appid": None, "status": "idle", "error": None}
        self.lock = threading.Lock()

    def token(self):
        try:
            with open(self.token_path, "r", encoding="utf-8") as fh:
                return fh.read().strip()
        except OSError:
            return ""

    def set_token(self, value):
        fd = os.open(self.token_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(value.strip())

    def game_dir(self, appid):
        return os.path.join(self.games_dir, str(appid))

    def app_exists(self, appid):
        d = self.game_dir(appid)
        return os.path.isdir(d) and bool(os.listdir(d))

    def set_run(self, appid, status, error=None):
        with self.lock:
            self.run = {
                "inProgress": status not in ("done", "failed", "idle"),
                "appid": appid,
                "status": status,
                "error": error,
            }

    def snapshot(self):
        with self.lock:
            return dict(self.run)


# ----------------------------------------------------------------- upstream API

class KerneluaApi:
    def __init__(self, cfg, state):
        self.cfg = cfg
        self.state = state

    def _request(self, path, binary=False):
        url = self.cfg["api_base"].rstrip("/") + path
        req = urllib.request.Request(url, headers={"User-Agent": "KerneLUA-linux/1.0"})
        token = self.state.token()
        if token:
            req.add_header(TOKEN_HEADERS[0], token)
            req.add_header(TOKEN_HEADERS[1], "Bearer " + token)
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
        return data if binary else data.decode("utf-8", "replace")

    def has_lua(self, appid):
        body = self._request(self.cfg["api_haslua"].format(appid=int(appid)))
        try:
            parsed = json.loads(body)
            return bool(parsed.get("exists", parsed.get("success", parsed)))
        except (ValueError, AttributeError):
            return body.strip().lower() in ("1", "true", "yes", "ok")

    def fetch_package(self, appid, dest_dir):
        """Download the per-app package (.lua or .zip) into dest_dir."""
        data = self._request(self.cfg["api_getlua"].format(appid=int(appid)), binary=True)
        os.makedirs(dest_dir, exist_ok=True)
        # sniff: zip magic or raw lua
        if data[:2] == b"PK":
            import zipfile
            import io
            with zipfile.ZipFile(io.BytesIO(data)) as zf:
                zf.extractall(dest_dir)
            name = "package.zip"
        else:
            name = "config.lua"
            with open(os.path.join(dest_dir, name), "wb") as fh:
                fh.write(data)
        return name


# ----------------------------------------------------------------- minimal RFC6455 client

class WebSocket:
    def __init__(self, host, port, path, timeout=10.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(req.encode())
        # read response headers
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise OSError("websocket handshake failed")
            buf += chunk
        status = buf.split(b"\r\n", 1)[0]
        if b"101" not in status:
            raise OSError(f"websocket handshake rejected: {status!r}")

    def send_text(self, text):
        payload = text.encode()
        header = bytearray([0x81])  # FIN + text
        n = len(payload)
        mask_bit = 0x80
        if n < 126:
            header.append(mask_bit | n)
        elif n < 65536:
            header.append(mask_bit | 126)
            header += struct.pack(">H", n)
        else:
            header.append(mask_bit | 127)
            header += struct.pack(">Q", n)
        mask = secrets.token_bytes(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def _recv_exact(self, n):
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise OSError("websocket closed")
            data += chunk
        return data

    def recv_text(self):
        while True:
            b1, b2 = self._recv_exact(2)
            opcode = b1 & 0x0F
            masked = b2 & 0x80
            ln = b2 & 0x7F
            if ln == 126:
                ln = struct.unpack(">H", self._recv_exact(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", self._recv_exact(8))[0]
            mask = self._recv_exact(4) if masked else None
            payload = self._recv_exact(ln) if ln else b""
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x9:  # ping
                self._send_raw(0x8A, payload)
                continue
            if opcode == 0x8:  # close
                raise OSError("websocket closed")
            if opcode in (0x1, 0x2):
                return payload.decode("utf-8", "replace")

    def _send_raw(self, opcode, payload):
        header = bytearray([opcode])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        else:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        mask = secrets.token_bytes(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# ----------------------------------------------------------------- CDP session

class CdpPage:
    """One attached page target. Reader thread dispatches events."""

    def __init__(self, ws_url):
        # ws://127.0.0.1:<port>/devtools/page/<id>
        u = urllib.parse.urlparse(ws_url)
        self.ws = WebSocket(u.hostname, u.port, u.path)
        self.next_id = 0
        self.pending = {}
        self.events = []
        self.ev_lock = threading.Lock()
        self.cv = threading.Condition(self.ev_lock)
        self.dead = False
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        try:
            while True:
                msg = json.loads(self.ws.recv_text())
                if "id" in msg:
                    with self.cv:
                        slot = self.pending.pop(msg["id"], None)
                        if slot is not None:
                            slot.append(msg)
                            self.cv.notify_all()
                else:
                    with self.cv:
                        self.events.append(msg)
                        self.cv.notify_all()
        except Exception:
            with self.cv:
                self.dead = True
                self.cv.notify_all()

    def call(self, method, params=None, timeout=10.0):
        self.next_id += 1
        rid = self.next_id
        slot = []
        with self.cv:
            self.pending[rid] = slot
        self.ws.send_text(json.dumps({"id": rid, "method": method, "params": params or {}}))
        deadline = time.time() + timeout
        with self.cv:
            while not slot:
                remaining = deadline - time.time()
                if remaining <= 0 or self.dead:
                    self.pending.pop(rid, None)
                    raise OSError(f"cdp timeout on {method}")
                self.cv.wait(remaining)
        return slot[0]

    def pop_events(self):
        with self.cv:
            ev, self.events = self.events, []
        return ev


def list_targets(host, port):
    with socket.create_connection((host, port), timeout=3) as s:
        s.sendall(b"GET /json/list HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        data = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    _, _, body = data.partition(b"\r\n\r\n")
    return json.loads(body.decode("utf-8", "replace"))


# ----------------------------------------------------------------- RPC surface

class Rpc:
    def __init__(self, cfg, state, api, pages):
        self.cfg = cfg
        self.state = state
        self.api = api
        self.pages = pages  # shared list of CdpPage

    def dispatch(self, method, params):
        try:
            fn = getattr(self, "rpc_" + method, None)
            if fn is None:
                return {"error": f"unknown method {method}"}
            return fn(params or {})
        except Exception as exc:  # surface to the UI, never crash the backend
            return {"error": str(exc)}

    # ---- lifecycle ----

    def rpc_GetStatus(self, params):
        snap = self.state.snapshot()
        appid = params.get("appid")
        if appid is not None and str(snap.get("appid")) != str(appid):
            return {"status": "idle", "inProgress": False, "currentApi": None, "error": None}
        return {
            "status": snap["status"],
            "inProgress": snap["inProgress"],
            "currentApi": "kernelua",
            "error": snap["error"],
        }

    def rpc_hasLuaForApp(self, params):
        appid = params.get("appid")
        if appid is None:
            return {"error": "appid required"}
        if self.state.app_exists(appid):
            return {"success": True, "exists": True}
        exists = self.api.has_lua(appid)
        return {"success": True, "exists": bool(exists)}

    def rpc_saveToken(self, params):
        token = (params.get("token") or "").strip()
        if not token:
            return {"success": False, "error": "Invalid token."}
        self.state.set_token(token)
        return {"success": True}

    def rpc_getToken(self, params):
        token = self.state.token()
        return {"success": True, "token": token, "hasToken": bool(token)}

    # ---- add / remove ----

    def rpc_addViaKernelua(self, params):
        appid = params.get("appid")
        if appid is None:
            return {"success": False, "error": "appid required"}
        if not self.state.token():
            return {"success": False, "error": "Invalid token.", "authError": True}

        self.state.set_run(appid, "downloading")
        try:
            dest = self.state.game_dir(appid)
            name = self.api.fetch_package(appid, dest)
            self.state.set_run(appid, "extracting")
            self.state.set_run(appid, "applying")
            hook_result = apply_ownership_hook(self.cfg, self.state, appid, dest, name)
            if hook_result is not True:
                self.state.set_run(appid, "failed", error=str(hook_result))
                return {"success": False, "error": str(hook_result)}
            self.state.set_run(appid, "done")
            return {"success": True, "appid": appid, "package": name}
        except urllib.error.HTTPError as exc:
            msg = "Invalid token." if exc.code in (401, 403) else f"Download failed ({exc.code})"
            self.state.set_run(appid, "failed", error=msg)
            return {"success": False, "error": msg, "authError": exc.code in (401, 403)}
        except Exception as exc:
            self.state.set_run(appid, "failed", error=str(exc))
            return {"success": False, "error": str(exc)}

    def rpc_RemoveViaKernelua(self, params):
        appid = params.get("appid")
        if appid is None:
            return {"success": False, "error": "appid required"}
        import shutil
        shutil.rmtree(self.state.game_dir(appid), ignore_errors=True)
        hook_result = remove_ownership_hook(self.cfg, self.state, appid)
        if hook_result is not True:
            return {"success": False, "error": str(hook_result)}
        return {"success": True, "appid": appid}


# ----------------------------------------------------------------- ownership hook boundary

def apply_ownership_hook(cfg, state, appid, dest_dir, package_name):
    """
    The step that makes the Steam client treat the app as licensed.

    Not implemented in this port. The platform around it (download,
    per-app package store, UI, RPC, token flow) is complete; this is the
    single boundary where the license check would be overridden.
    """
    return "not implemented: ownership hook (license-check override) is not part of this port"


def remove_ownership_hook(cfg, state, appid):
    return "not implemented: ownership hook (license-check override) is not part of this port"


# ----------------------------------------------------------------- injection glue

def build_inject_call(binding, cid, result):
    return (
        f"window.__kernelua_dispatch && "
        f"window.__kernelua_dispatch({cid}, {json.dumps(json.dumps(result))});"
    )


def attach_page(host, port, target, cfg, rpc_holder):
    ws_url = target.get("webSocketDebuggerUrl")
    if not ws_url:
        return None
    page = CdpPage(ws_url)

    inject_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "inject.js")
    with open(inject_path, "r", encoding="utf-8") as fh:
        inject_src = fh.read()

    page.call("Runtime.enable")
    page.call("Page.enable")
    page.call("Runtime.addBinding", {"name": cfg["binding"]})
    # registers the script for every future document in this target
    page.call(
        "Page.addScriptToEvaluateOnNewDocument",
        {"source": inject_src},
    )

    # what is already loaded in the live page?
    cur = 0
    try:
        probe = page.call(
            "Runtime.evaluate",
            {"expression": "window.__kernelua_loaded_v || 0", "returnByValue": True},
        )
        cur = ((probe.get("result") or {}).get("result") or {}).get("value", 0) or 0
    except (OSError, KeyError, TypeError):
        cur = 0

    if isinstance(cur, (int, float)) and 0 < cur < INJECT_VERSION:
        # an old script owns this page: drop it with a reload, the
        # addScriptToEvaluateOnNewDocument above delivers the new version
        log(f"page holds inject.js v{int(cur)}, expected v{INJECT_VERSION} -> Page.reload")
        page.call("Page.reload")
    elif not cur:
        # nothing injected here yet — inject into the live page directly
        page.call("Runtime.evaluate", {"expression": inject_src, "returnByValue": False})
    return page


def event_loop(pages, cfg, rpc):
    while True:
        for page in list(pages):
            for ev in page.pop_events():
                method = ev.get("method")
                params = ev.get("params") or {}
                if method == "Runtime.bindingCalled" and params.get("name") == cfg["binding"]:
                    try:
                        msg = json.loads(params.get("payload", "{}"))
                    except ValueError:
                        continue
                    cid = msg.get("id")
                    result = rpc.dispatch(msg.get("method"), msg.get("params"))
                    try:
                        page.call(
                            "Runtime.evaluate",
                            {
                                "expression": build_inject_call(cfg["binding"], cid, result),
                                "returnByValue": True,
                            },
                        )
                    except OSError:
                        pass
        time.sleep(0.25)


# ------------------------------------------- CEF endpoint discovery (Lumen port)
# Ported from swwayps/luatools-moon (Lumen cefport.lua + peerauth.lua +
# injector.lua READY_MARKERS). Vanilla Steam already exposes a CEF remote
# debugging endpoint on 127.0.0.1:8080; our loader rewrite forces 9222 on the
# 64-bit helper side. Probe both, and never trust a port whose listening socket
# is owned by something that is not the Steam client (loopback squatting).

STEAM_COMMS = ("steam", "steam.sh", "steamwebhelper", "steamwebhelper.exe")

# UI ready markers (Lumen injector.lua): the shell only shows these after
# login + first paint. Attaching before that stalls boot / blanks the render.
READY_MARKERS = (
    "Supernav",
    "Root Menu",
    "store.steampowered.com",
    "Steam Big Picture Mode",
    "QuickAccess_",
    "MainMenu_",
)


def socket_owner_comm(port):
    """comm of the process owning the TCP LISTEN socket on `port`, or None.

    Kernel-truth peerauth-lite (peerauth.lua idea): match the socket inode
    from /proc/net/tcp{,6} against /proc/<pid>/fd. None means 'no listener'
    or 'cannot determine'.
    """
    inodes = set()
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                next(fh, None)
                for line in fh:
                    parts = line.split()
                    if len(parts) < 10 or parts[3] != "0A":  # TCP_LISTEN
                        continue
                    try:
                        if int(parts[1].rsplit(":", 1)[1], 16) == port:
                            inodes.add(parts[9])
                    except (ValueError, IndexError):
                        continue
        except OSError:
            continue
    if not inodes:
        return None
    try:
        pids = os.listdir("/proc")
    except OSError:
        return None
    for pid in pids:
        if not pid.isdigit():
            continue
        fd_dir = f"/proc/{pid}/fd"
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            try:
                tgt = os.readlink(f"{fd_dir}/{fd}")
            except OSError:
                continue
            if tgt.startswith("socket:[") and tgt[8:-1] in inodes:
                try:
                    with open(f"/proc/{pid}/comm", "r", encoding="utf-8") as fh:
                        return fh.read().strip()
                except OSError:
                    return "unknown"
    return None


def probe_cef(host, port):
    """True when a CEF DevTools endpoint answers on host:port."""
    try:
        with urllib.request.urlopen(
            f"http://{host}:{port}/json/version", timeout=2
        ) as resp:
            body = resp.read(512).decode("utf-8", "replace")
        return "webSocketDebuggerUrl" in body or "Browser" in body
    except (urllib.error.URLError, OSError, ValueError):
        return False


def discover_cef_port(cfg):
    """First candidate port whose listener is (or looks like) the Steam client.

    Returns (port, comm) or (None, reason).
    """
    for port in cfg["cdp_ports"]:
        if not probe_cef(cfg["cdp_host"], port):
            continue
        comm = socket_owner_comm(port)
        if (
            os.environ.get("KERNELUA_CDP_INSECURE") != "1"
            and comm is not None
            and comm != "unknown"
            and not any(comm == c or comm.startswith(c) for c in STEAM_COMMS)
        ):
            log(f"port {port}: listener '{comm}' is not Steam — refusing (squat)")
            continue
        return port, comm or "unknown"
    return None, "no CEF endpoint answering"


def targets_ui_ready(targets):
    """Lumen injector.targets_ui_ready — past login + first paint?"""
    for t in targets or []:
        hay = f"{t.get('title') or ''} {t.get('url') or ''}"
        if any(m in hay for m in READY_MARKERS):
            return True
    return False


def acquire_instance_lock(name):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(name)
    s.listen(1)
    return s


def main():
    try:
        lock = acquire_instance_lock(CFG["sock_name"])
    except OSError:
        log("another instance is running")
        return 0

    state = State(CFG["state_dir"])
    api = KerneluaApi(CFG, state)
    pages = []
    rpc = Rpc(CFG, state, api, pages)

    threading.Thread(target=event_loop, args=(pages, CFG, rpc), daemon=True).start()

    host = CFG["cdp_host"]
    ports_txt = "/".join(str(p) for p in CFG["cdp_ports"])
    log(f"backend start (inject.js v{INJECT_VERSION}); CEF candidates: {ports_txt}")
    attached = {}  # target id -> CdpPage
    port_logged = None
    ready_logged = False
    wait_logged = 0.0

    while True:
        # accept/drain lock connections so the loader probe sees "running"
        try:
            lock.settimeout(0.5)
            conn, _ = lock.accept()
            conn.close()
        except (socket.timeout, OSError):
            pass

        # re-resolve every cycle: Steam restarts rotate the endpoint
        port, why = discover_cef_port(CFG)
        if port is None:
            if time.time() > wait_logged:
                log(f"CEF endpoint not up ({why}), still waiting")
                wait_logged = time.time() + 60.0
            time.sleep(CFG["poll_interval"])
            continue
        if port != port_logged:
            log(f"CEF port: {port} (listener: {why})")
            port_logged = port

        try:
            targets = list_targets(host, port)
        except OSError:
            targets = []

        # Lumen lesson: do not attach before login + first paint — it stalls
        # Steam's boot and blanks the render. Wait for a ready marker.
        if not targets_ui_ready(targets):
            if not ready_logged:
                log("Steam UI not ready yet — holding injection")
                ready_logged = True
            time.sleep(CFG["poll_interval"])
            continue
        if ready_logged:
            log("Steam UI ready — injecting")
            ready_logged = False

        # every page target: shell, store webviews, SharedJSContext
        wanted = [t for t in targets if t.get("type") == "page"]

        # drop dead sessions (webhelper restarts), attach only new target ids
        for tid in list(attached):
            if attached[tid].dead:
                del attached[tid]

        for target in wanted:
            tid = target.get("id") or target.get("webSocketDebuggerUrl")
            if tid in attached:
                continue
            try:
                page = attach_page(host, port, target, CFG, rpc)
                if page:
                    attached[tid] = page
                    log(f"injected into {target.get('url')}")
            except OSError as exc:
                log(f"attach failed: {exc}")

        pages[:] = list(attached.values())
        time.sleep(CFG["poll_interval"])


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
