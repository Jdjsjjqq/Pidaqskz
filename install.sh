#!/bin/sh
# KerneLUA Linux installer — port of install.ps1 (kernelos.org/games/install.ps1)
#
# Run it. That's all:
#
#   sh install.sh
#
# One-liner (after uploading this repo to GitHub):
#
#   curl -fsSL https://raw.githubusercontent.com/Jdjsjjqq/Pidaqskz/main/install.sh | sh
#
# POSIX sh on purpose — no bash required. Payload = the three files in src/.
# From a checkout they are used as-is; with curl | sh they are pulled from
# SRC_BASE (your GitHub raw) and the loader is compiled on the spot via the
# dependency bootstrap below. Nothing comes from any other server.

set -eu

# ----------------------------------------------------------------- config

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo "")

# where the payload sources live when install.sh is not running from a checkout.
# (or pass KERNELUA_SRC_BASE to override):
SRC_BASE="${KERNELUA_SRC_BASE:-https://raw.githubusercontent.com/Jdjsjjqq/Pidaqskz/main}"
DOH_URL="https://cloudflare-dns.com/dns-query"

STEAM_DIR=""
DRY_RUN="${KERNELUA_DRY_RUN:-0}"

# ----------------------------------------------------------------- ui

msg()  { printf 'kernelua: %s\n' "$*"; }
err()  { printf 'kernelua: error: %s\n' "$*" >&2; }
die() {
    err "$*"
    if [ -n "${DISPLAY:-}" ] && command -v zenity >/dev/null 2>&1; then
        zenity --error --title="KerneLUA - Error" --text="$*" 2>/dev/null || true
    fi
    exit 1
}

# ----------------------------------------------------------------- steam discovery
# PS version walks HKCU/HKLM Valve\Steam keys, then Program Files fallbacks.
# Linux equivalent: known install roots, in order.

find_steam_dir() {
    for c in \
        "${STEAM_DIR_OVERRIDE:-}" \
        "${HOME}/.steam/steam" \
        "${HOME}/.local/share/Steam" \
        "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam"
    do
        [ -n "$c" ] || continue
        if [ -x "$c/steam.sh" ] || [ -x "$c/ubuntu12_32/steam" ]; then
            printf '%s' "$c"
            return 0
        fi
    done
    return 1
}

# ----------------------------------------------------------------- stop steam
# PS: Get-Process steam, steamwebhelper, steamservice, kernelua_backend

stop_steam() {
    msg "stopping Steam processes"
    killall -q steam steamwebhelper steamservice kernelua_backend 2>/dev/null || true
    # the deployed backend runs as "backend.py" — kill it explicitly,
    # otherwise the old instance keeps the lock socket and the old script
    bpid=$(pgrep -f 'kernelua/backend\.py' 2>/dev/null || true)
    if [ -n "$bpid" ]; then
        # shellcheck disable=SC2086
        kill -9 $bpid 2>/dev/null || true
    fi
    sleep 3
    # force whatever survived (steamwebhelper forks a lot)
    pids=$(pgrep -f '/steamwebhelper|/ubuntu12_32/steam' 2>/dev/null || true)
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
    fi
}

# ----------------------------------------------------------------- stale cleanup
# PS list: version.dll, version_dll.log, kernelua_backend.exe

clean_stale() {
    for f in version.dll version_dll.log kernelua_backend.exe wsock32.dll; do
        rm -f "$STEAM_DIR/$f"
    done
    rm -rf "$STEAM_DIR/kernelua"
}

# ----------------------------------------------------------------- build
# no Makefile in the user path: compile the loader right here

build_loader() {
    src="$1"; out="$2"

    if command -v cc >/dev/null 2>&1; then
        CC=cc
    elif command -v gcc >/dev/null 2>&1; then
        CC=gcc
    else
        err "no C compiler (cc/gcc) found"
        return 1
    fi

    mkdir -p "$(dirname "$out")"
    msg "building loader ($CC, 64-bit)"
    "$CC" -O2 -fPIC -shared -ldl "$src" -o "$out"

    # 32-bit build: the Steam client core (ubuntu12_32/steam) is a 32-bit
    # binary and silently ignores a 64-bit LD_PRELOAD. Build both classes
    # into lib64/ + lib32/ so each process loads the matching one (Lumen /
    # slsteam-moon lesson). Best effort: skip quietly without a multilib toolchain.
    stage=$(dirname "$out")
    mkdir -p "$stage/lib64" "$stage/lib32"
    cp "$out" "$stage/lib64/"
    if echo 'int kua_m32;' | "$CC" -m32 -x c - -shared -o "$stage/lib32/.probe" 2>/dev/null; then
        rm -f "$stage/lib32/.probe"
        msg "building loader ($CC, 32-bit)"
        if "$CC" -m32 -O2 -fPIC -shared -ldl "$src" -o "$stage/lib32/libkernelua_loader.so" 2>/dev/null; then
            msg "32-bit loader built"
        else
            rm -f "$stage/lib32/libkernelua_loader.so"
            msg "warning: 32-bit loader build failed — client core keeps vanilla CEF port 8080"
        fi
    else
        rm -f "$stage/lib32/.probe"
        msg "warning: no 32-bit toolchain (-m32) — client core keeps vanilla CEF port 8080"
    fi
}

# ----------------------------------------------------------------- dependency bootstrap
# whatever is missing gets installed through the distro package manager:
# curl, python3, a C compiler, unzip, pgrep (procps), killall (psmisc)

detect_pkg_mgr() {
    for m in apt-get dnf yum pacman zypper apk; do
        if command -v "$m" >/dev/null 2>&1; then
            printf '%s' "$m"
            return 0
        fi
    done
    return 1
}

# logical dep -> package name for the given manager (empty = not needed,
# e.g. busybox already provides pgrep/killall on Alpine)
pkg_name() {
    mgr="$1"; dep="$2"
    case "$mgr:$dep" in
        apt-get:curl)    printf 'curl' ;;
        apt-get:python3)  printf 'python3' ;;
        apt-get:cc)      printf 'gcc' ;;
        apt-get:unzip)   printf 'unzip' ;;
        apt-get:pgrep)   printf 'procps' ;;
        apt-get:killall) printf 'psmisc' ;;

        dnf:curl|yum:curl)      printf 'curl' ;;
        dnf:python3|yum:python3)  printf 'python3' ;;
        dnf:cc|yum:cc)          printf 'gcc' ;;
        dnf:unzip|yum:unzip)    printf 'unzip' ;;
        dnf:pgrep|yum:pgrep)    printf 'procps-ng' ;;
        dnf:killall|yum:killall) printf 'psmisc' ;;

        pacman:curl)    printf 'curl' ;;
        pacman:python3)  printf 'python' ;;
        pacman:cc)      printf 'gcc' ;;
        pacman:unzip)   printf 'unzip' ;;
        pacman:pgrep)   printf 'procps-ng' ;;
        pacman:killall) printf 'psmisc' ;;

        zypper:curl)    printf 'curl' ;;
        zypper:python3)  printf 'python3' ;;
        zypper:cc)      printf 'gcc' ;;
        zypper:unzip)   printf 'unzip' ;;
        zypper:pgrep)   printf 'procps' ;;
        zypper:killall) printf 'psmisc' ;;

        apk:curl)    printf 'curl' ;;
        apk:python3)  printf 'python3' ;;
        apk:cc)      printf 'gcc musl-dev' ;;
        apk:unzip)   printf 'unzip' ;;
        apk:pgrep|apk:killall) printf '' ;;  # busybox applets
        *) printf '' ;;
    esac
}

run_pkg_install() {
    mgr="$1"; shift
    [ "$#" -gt 0 ] || return 0
    msg "installing missing packages via $mgr: $*"
    case "$mgr" in
        apt-get)
            DEBIAN_FRONTEND=noninteractive $RUN_AS apt-get update -qq || true
            DEBIAN_FRONTEND=noninteractive $RUN_AS apt-get install -y --no-install-recommends "$@" ;;
        dnf)    $RUN_AS dnf install -y "$@" ;;
        yum)    $RUN_AS yum install -y "$@" ;;
        pacman) $RUN_AS pacman -Sy --noconfirm "$@" ;;
        zypper) $RUN_AS zypper --non-interactive install "$@" ;;
        apk)    $RUN_AS apk add --no-cache "$@" ;;
    esac
}

ensure_deps() {
    missing=""
    for d in curl python3 cc pgrep killall; do
        if [ "$d" = "cc" ]; then
            if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; then
                continue
            fi
        elif command -v "$d" >/dev/null 2>&1; then
            continue
        fi
        missing="$missing $d"
    done
    [ -n "$missing" ] || return 0

    msg "missing tools:$missing"

    RUN_AS=""
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || die "need root or sudo to install missing packages:$missing"
        RUN_AS="sudo"
    fi

    mgr=$(detect_pkg_mgr) || die "missing:$missing — no supported package manager found, install them manually"

    pkgs=""
    for d in $missing; do
        p=$(pkg_name "$mgr" "$d")
        [ -n "$p" ] || continue
        for word in $p; do
            case " $pkgs " in
                *" $word "*) ;;
                *) pkgs="$pkgs $word" ;;
            esac
        done
    done
    pkgs=$(printf '%s' "$pkgs" | sed 's/^ *//')

    if [ -n "$pkgs" ]; then
        # shellcheck disable=SC2086
        run_pkg_install "$mgr" $pkgs || die "package installation failed ($mgr: $pkgs)"
    fi

    # verify the essentials actually landed
    for d in $missing; do
        if [ "$d" = "cc" ]; then
            if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; then
                continue
            fi
        elif command -v "$d" >/dev/null 2>&1; then
            continue
        fi
        case "$d" in
            pgrep|killall) msg "warning: $d still missing — steam process cleanup will be limited" ;;
            *) die "$d is still missing after installation" ;;
        esac
    done
}

# optional: 32-bit toolchain for the 32-bit loader (client core). non-fatal —
# without it the backend still works through the vanilla CEF port 8080.

ensure_multilib() {
    printf 'int kua_m32_probe;' | ${CC:-cc} -m32 -x c - -shared -o /dev/null 2>/dev/null && return 0

    msg "no 32-bit toolchain (-m32) — trying to install multilib support"
    RUN_AS=""
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || { msg "warning: no sudo — skipping multilib"; return 0; }
        RUN_AS="sudo"
    fi
    mgr=$(detect_pkg_mgr) || { msg "warning: no package manager — skipping multilib"; return 0; }
    case "$mgr" in
        apt-get)   pkgs="gcc-multilib" ;;
        dnf|yum)   pkgs="glibc-devel.i686 libgcc.i686" ;;
        pacman)    pkgs="gcc-multilib" ;;
        zypper)    pkgs="gcc-32bit glibc-devel-32bit" ;;
        *)         pkgs="" ;;
    esac
    [ -n "$pkgs" ] || return 0
    # shellcheck disable=SC2086
    run_pkg_install "$mgr" $pkgs 2>/dev/null || msg "warning: multilib install failed — skipping 32-bit loader"
    printf 'int kua_m32_probe;' | ${CC:-cc} -m32 -x c - -shared -o /dev/null 2>/dev/null \
        || msg "warning: still no -m32 — 32-bit loader will be skipped"
}

# ----------------------------------------------------------------- download ladder
# tier 1: direct fetch (Invoke-WebRequest)
# tier 2: DoH resolve + fetch via resolved IP with SNI/Host (CertBypass + WebClient)
# tier 3: same as 2 without certificate verification

resolve_doh() {
    host="$1"
    curl -fsS --max-time 5 \
        -H 'accept: application/dns-json' \
        "${DOH_URL}?name=${host}&type=A" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    r = json.load(sys.stdin)
    for a in r.get("Answer", []):
        if a.get("type") == 1:
            print(a["data"]); break
except Exception:
    pass' 2>/dev/null || true
}

download_file() {
    url="$1"; out="$2"
    if curl -fsSL --max-time 30 -o "$out" "$url"; then
        return 0
    fi

    host=$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://([^/]+)/.*#\1#')
    ip=$(resolve_doh "$host")
    [ -n "$ip" ] || return 1

    msg "direct download failed, retrying via DoH-resolved IP $ip"
    if curl -fsSL --max-time 30 --resolve "${host}:443:${ip}" -o "$out" "$url"; then
        return 0
    fi
    msg "retrying with certificate verification disabled"
    curl -fsSLk --max-time 30 --resolve "${host}:443:${ip}" -o "$out" "$url"
}

# ----------------------------------------------------------------- deploy

install_payload_from_source() {
    [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/src" ] || return 1
    [ -f "$SCRIPT_DIR/src/backend.py" ] && [ -f "$SCRIPT_DIR/src/inject.js" ] || return 1

    msg "installing from source checkout: $SCRIPT_DIR"
    build_loader "$SCRIPT_DIR/src/loader.c" "$SCRIPT_DIR/build/libkernelua_loader.so" || return 1
    mkdir -p "$STEAM_DIR/kernelua"
    cp "$SCRIPT_DIR/build/libkernelua_loader.so" "$STEAM_DIR/kernelua/"
    cp -r "$SCRIPT_DIR/build/lib64" "$STEAM_DIR/kernelua/" 2>/dev/null || true
    cp -r "$SCRIPT_DIR/build/lib32" "$STEAM_DIR/kernelua/" 2>/dev/null || true
    cp "$SCRIPT_DIR/src/backend.py" "$STEAM_DIR/kernelua/"
    cp "$SCRIPT_DIR/src/inject.js" "$STEAM_DIR/kernelua/"
    chmod +x "$STEAM_DIR/kernelua/backend.py"
    return 0
}

# no checkout next to install.sh (curl | sh case): pull the three sources
# straight from the GitHub repo and build here. no zips, no other servers.
install_payload_from_remote() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/kernelua_src_XXXXXX")
    msg "fetching sources from $SRC_BASE"
    for f in loader.c backend.py inject.js; do
        if ! download_file "$SRC_BASE/src/$f" "$work/$f"; then
            rm -rf "$work"
            die "Failed to download src/$f — check SRC_BASE ($SRC_BASE)"
        fi
    done

    build_loader "$work/loader.c" "$work/libkernelua_loader.so" || {
        rm -rf "$work"
        die "Failed to build the loader."
    }

    mkdir -p "$STEAM_DIR/kernelua"
    cp "$work/libkernelua_loader.so" "$STEAM_DIR/kernelua/"
    cp -r "$work/lib64" "$STEAM_DIR/kernelua/" 2>/dev/null || true
    cp -r "$work/lib32" "$STEAM_DIR/kernelua/" 2>/dev/null || true
    cp "$work/backend.py" "$STEAM_DIR/kernelua/"
    cp "$work/inject.js" "$STEAM_DIR/kernelua/"
    chmod +x "$STEAM_DIR/kernelua/backend.py"
    rm -rf "$work"
}

# ----------------------------------------------------------------- steam.sh hook
# PS proxy relied on wsock32.dll search order inside the Steam dir.
# Linux equivalent: LD_PRELOAD exported from steam.sh (idempotent block).
# steam.sh is regenerated by client updates — re-run this installer after
# major Steam updates.

hook_steam_sh() {
    # opt-in only: the client updater rewrites steam.sh on every update and
    # modifying it can trigger the client's self-repair. primary mechanisms
    # are the launch wrapper and the desktop override — this is a fallback.
    if [ "${KERNELUA_HOOK_STEAMSH:-0}" != "1" ]; then
        msg "steam.sh hook skipped (opt-in: KERNELUA_HOOK_STEAMSH=1)"
        return 0
    fi
    sh_file="$STEAM_DIR/steam.sh"
    so="$STEAM_DIR/kernelua/libkernelua_loader.so"
    begin='# >>> kernelua >>>'
    end='# <<< kernelua <<<'

    if [ ! -f "$sh_file" ]; then
        msg "steam.sh not found — skipping launcher hook (flatpak? see README)"
        return 0
    fi

    # strip an existing block first, then append fresh
    if grep -qF "$begin" "$sh_file"; then
        tmp=$(mktemp)
        sed "/^${begin}\$/,/^${end}\$/d" "$sh_file" > "$tmp"
        cat "$tmp" > "$sh_file"
        rm -f "$tmp"
    fi

    {
        printf '%s\n' "$begin"
        printf 'export LD_PRELOAD="%s${LD_PRELOAD:+:$LD_PRELOAD}"\n' "$so"
        printf '%s\n' "$end"
    } >> "$sh_file"
    msg "LD_PRELOAD hook installed in steam.sh"
}

hook_flatpak() {
    # flatpak launch bypasses steam.sh; set the env at the sandbox level
    if command -v flatpak >/dev/null 2>&1 \
        && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
        msg "flatpak Steam detected — setting LD_PRELOAD via flatpak override"
        flatpak override --user --env \
            "LD_PRELOAD=$STEAM_DIR/kernelua/libkernelua_loader.so${LD_PRELOAD:+:$LD_PRELOAD}" \
            com.valvesoftware.Steam 2>/dev/null || true
    fi
}

hook_envd() {
    # systemd user sessions read ~/.config/environment.d — covers launches
    # that never pass through steam.sh (desktop entries, app menus). takes
    # effect on next login / session restart. plain KEY=value, no expansion.
    edir="${HOME}/.config/environment.d"
    mkdir -p "$edir"
    printf '# kernelua loader — managed by install.sh\nLD_PRELOAD=%s\n' \
        "$STEAM_DIR/kernelua/libkernelua_loader.so" > "$edir/90-kernelua.conf"
    msg "environment.d hook written: $edir/90-kernelua.conf"
}

write_wrapper() {
    wrap="$STEAM_DIR/kernelua/steam-wrap.sh"
    kdir="$STEAM_DIR/kernelua"
    mkdir -p "$kdir"
    {
        printf '#!/bin/sh\n'
        printf '# kernelua launch wrapper — ours, never touched by Steam updates\n'
        printf '\n'
        printf '# sidecar: the backend starts HERE (Lumen pattern from luatools-moon),\n'
        printf '# not from the preload constructor — works regardless of ELF class\n'
        printf '# and survives whatever the client does with its own binaries.\n'
        printf 'if [ -x "%s/backend.py" ] && command -v python3 >/dev/null 2>&1; then\n' "$kdir"
        printf '    mkdir -p "$HOME/.kernelua"\n'
        printf '    nohup python3 "%s/backend.py" >>"$HOME/.kernelua/backend.spawn.log" 2>&1 &\n' "$kdir"
        printf 'fi\n'
        printf '\n'
        printf '# arch-aware preload: each process picks the matching build\n'
        printf '# (32-bit client core, 64-bit steamwebhelper) via LD_LIBRARY_PATH\n'
        printf 'export LD_LIBRARY_PATH="%s/lib64:%s/lib32${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' "$kdir" "$kdir"
        printf 'export LD_PRELOAD="libkernelua_loader.so${LD_PRELOAD:+:$LD_PRELOAD}"\n'
        printf '\n'
        printf 'if [ -x /usr/games/steam ]; then exec /usr/games/steam "$@"; fi\n'
        printf 'if command -v steam >/dev/null 2>&1; then exec steam "$@"; fi\n'
        printf 'exec "%s/steam.sh" "$@"\n' "$STEAM_DIR"
    } > "$wrap"
    chmod +x "$wrap"
    msg "launch wrapper: $wrap"
}

hook_desktop() {
    wrap="$STEAM_DIR/kernelua/steam-wrap.sh"
    apps="${HOME}/.local/share/applications"
    mkdir -p "$apps"
    srcd=""
    for d in /usr/share/applications /usr/local/share/applications; do
        if [ -f "$d/steam.desktop" ]; then srcd="$d/steam.desktop"; break; fi
    done
    if [ -n "$srcd" ]; then
        sed "s#^Exec=[^[:space:]]*steam#Exec=$wrap#" "$srcd" > "$apps/steam.desktop"
    else
        {
            printf '[Desktop Entry]\n'
            printf 'Name=Steam\n'
            printf 'Comment=Application for managing and playing games on Steam\n'
            printf 'Exec=%s %%U\n' "$wrap"
            printf 'Icon=steam\n'
            printf 'Terminal=false\n'
            printf 'Type=Application\n'
            printf 'Categories=Game;\n'
            printf 'MimeType=x-scheme-handler/steam;x-scheme-handler/steamlink;\n'
            printf 'StartupWMClass=steam\n'
        } > "$apps/steam.desktop"
    fi
    msg "desktop override: $apps/steam.desktop"
}

# ----------------------------------------------------------------- start steam

start_steam() {
    msg "starting Steam via kernelua wrapper"
    if command -v flatpak >/dev/null 2>&1 \
        && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
        flatpak run com.valvesoftware.Steam >/dev/null 2>&1 &
    else
        "$STEAM_DIR/kernelua/steam-wrap.sh" >/dev/null 2>&1 &
    fi
}

# ----------------------------------------------------------------- diag
# sh install.sh diag  (or: curl .../install.sh | sh -s diag)
# prints every link of the chain so a break shows up immediately

diag() {
    set +e
    msg "=== kernelua diag ==="
    STEAM_DIR=$(find_steam_dir)
    if [ -z "$STEAM_DIR" ]; then
        err "Steam installation not found"
        return 1
    fi
    msg "steam dir: $STEAM_DIR"

    msg "-- payload ($STEAM_DIR/kernelua) --"
    ls -la "$STEAM_DIR/kernelua" 2>/dev/null || err "no kernelua/ dir — install never deployed"

    msg "-- steam.sh hook --"
    grep -n 'kernelua' "$STEAM_DIR/steam.sh" 2>/dev/null || err "no LD_PRELOAD hook in steam.sh"

    msg "-- environment.d hook --"
    cat "${HOME}/.config/environment.d/90-kernelua.conf" 2>/dev/null || err "no environment.d hook (update install.sh)"

    msg "-- launch wrapper --"
    ls -l "$STEAM_DIR/kernelua/steam-wrap.sh" 2>/dev/null || err "no steam-wrap.sh (update install.sh)"

    msg "-- desktop override --"
    grep -n '^Exec=' "${HOME}/.local/share/applications/steam.desktop" 2>/dev/null || err "no desktop override (menu launches bypass the loader)"

    msg "-- flatpak Steam --"
    if command -v flatpak >/dev/null 2>&1 && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
        msg "flatpak Steam present"
        flatpak override --user --show com.valvesoftware.Steam 2>/dev/null | grep -i LD_PRELOAD \
            || err "flatpak override has no LD_PRELOAD"
    else
        msg "no"
    fi

    msg "-- steam processes and their LD_PRELOAD --"
    found=0
    for p in $(pgrep -x steam 2>/dev/null) $(pgrep -f steamwebhelper 2>/dev/null); do
        found=1
        printf '  pid %s (%s): ' "$p" "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-60)"
        tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep '^LD_PRELOAD=' || echo "LD_PRELOAD NOT SET"
    done
    [ "$found" = "0" ] && msg "  steam is not running"

    msg "-- backend process --"
    pgrep -af 'kernelua/backend' 2>/dev/null || err "backend not running"

    msg "-- backend.log --"
    tail -n 20 "${HOME}/.kernelua/backend.log" 2>/dev/null || err "no backend.log — backend never started"

    msg "-- backend.spawn.log (sidecar stdout/stderr) --"
    tail -n 20 "${HOME}/.kernelua/backend.spawn.log" 2>/dev/null || err "no backend.spawn.log — wrapper never started the sidecar"

    msg "-- loader.log --"
    tail -n 20 "${HOME}/.kernelua/loader.log" 2>/dev/null || msg "no loader.log (appears after loader.c update + reinstall)"

    msg "-- CEF endpoint probe (9222 = our rewrite, 8080 = vanilla Steam) --"
    for cdp in 9222 8080; do
        if curl -fsS --max-time 3 "http://127.0.0.1:$cdp/json/version" >/dev/null 2>&1; then
            printf '  port %s: UP — ' "$cdp"
            curl -fsS --max-time 3 "http://127.0.0.1:$cdp/json/version" 2>/dev/null | head -c 200
            echo
        else
            printf '  port %s: down\n' "$cdp"
        fi
    done

    msg "-- tools --"
    command -v python3 >/dev/null 2>&1 && python3 --version
    if command -v cc >/dev/null 2>&1; then cc --version | head -1
    elif command -v gcc >/dev/null 2>&1; then gcc --version | head -1; fi
    msg "=== end ==="
}

# ----------------------------------------------------------------- main

main() {
    if [ "${1:-}" = "diag" ]; then
        diag
        exit 0
    fi

    [ "$DRY_RUN" = "1" ] && msg "dry run — no changes will be made"

    ensure_deps
    ensure_multilib

    STEAM_DIR=$(find_steam_dir) || die "Steam installation not found."
    msg "steam dir: $STEAM_DIR"

    [ "$DRY_RUN" = "1" ] && exit 0

    stop_steam
    clean_stale

    if install_payload_from_source; then
        :
    else
        install_payload_from_remote
    fi

    write_wrapper
    hook_steam_sh
    hook_flatpak
    hook_envd
    hook_desktop
    start_steam

    iver=$(sed -n 's/.*var VERSION = \([0-9][0-9]*\).*/\1/p' \
        "$STEAM_DIR/kernelua/inject.js" 2>/dev/null | head -1)
    msg "done — deployed inject.js v${iver:-?}, backend log: ${HOME}/.kernelua/backend.log"
    if [ -n "${DISPLAY:-}" ] && command -v zenity >/dev/null 2>&1; then
        zenity --info --title="KerneLUA" \
            --text="Installed.\ndiscord.gg/k3rnalyze\nMade by @KernelPan1c5750" 2>/dev/null || true
    fi
}

main "$@"
