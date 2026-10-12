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
    msg "building loader ($CC)"
    "$CC" -O2 -fPIC -shared -ldl "$src" -o "$out"
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

# ----------------------------------------------------------------- start steam

start_steam() {
    msg "starting Steam"
    if command -v flatpak >/dev/null 2>&1 \
        && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
        flatpak run com.valvesoftware.Steam >/dev/null 2>&1 &
    elif [ -x /usr/games/steam ]; then
        /usr/games/steam >/dev/null 2>&1 &
    elif command -v steam >/dev/null 2>&1; then
        steam >/dev/null 2>&1 &
    else
        "$STEAM_DIR/steam.sh" >/dev/null 2>&1 &
    fi
}

# ----------------------------------------------------------------- main

main() {
    [ "$DRY_RUN" = "1" ] && msg "dry run — no changes will be made"

    ensure_deps

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

    hook_steam_sh
    hook_flatpak
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
