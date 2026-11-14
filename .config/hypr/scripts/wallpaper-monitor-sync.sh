#!/usr/bin/env bash
# Keep awww's Wayland output list in sync with Hyprland after monitor hotplug,
# monitor reconfiguration, or a compositor reload.

set -u

state="${XDG_STATE_HOME:-$HOME/.local/state}/43pr/state.json"
log_file="$HOME/.cache/43pr/wallpaper-monitor-sync.log"
lock_file="$HOME/.cache/43pr/wallpaper-monitor-sync.lock"
mkdir -p "$(dirname "$log_file")"

exec 9>"$lock_file"
flock -n 9 || exit 0

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$log_file"
}

wallpaper_path() {
    local path=""
    if [[ -f "$state" ]]; then
        path="$(jq -r '.wallpaper // empty' "$state" 2>/dev/null || true)"
    fi
    if [[ -z "$path" || ! -f "$path" ]]; then
        path="$HOME/.config/hypr/wallpaper_effects/.wallpaper_current"
    fi
    [[ -f "$path" ]] && printf '%s\n' "$path"
}

active_monitors() {
    hyprctl -j monitors 2>/dev/null \
        | jq -r '.[] | select(.disabled == false) | .name' 2>/dev/null || true
}

awww_monitors() {
    awww query -j 2>/dev/null \
        | jq -r 'to_entries[].value[]?.name' 2>/dev/null || true
}

monitor_record() {
    local name="$1"
    hyprctl -j monitors 2>/dev/null \
        | jq -r --arg name "$name" '
            .[] | select(.name == $name and .disabled == false) |
            [
                .name,
                (.width | tostring),
                (.height | tostring),
                (.refreshRate | tostring),
                (.x | tostring),
                (.y | tostring),
                (.scale | tostring),
                (.transform | tostring),
                (.mirrorOf // "none")
            ] | @tsv' 2>/dev/null
}

reinitialize_monitor() {
    local record="$1"
    local name width height refresh x y scale transform mirror
    read -r name width height refresh x y scale transform mirror <<<"$record"
    [[ -n "${name:-}" ]] || return 1

    log "reinitializing wallpaper output $name"
    hyprctl eval "hl.monitor({ output = \"$name\", disabled = true })" >/dev/null 2>&1 || true
    sleep 0.35

    local mirror_field=""
    if [[ -n "${mirror:-}" && "$mirror" != "none" ]]; then
        mirror_field=", mirror = \"$mirror\""
    fi

    hyprctl eval "hl.monitor({ output = \"$name\", mode = \"${width}x${height}@${refresh}\", position = \"${x}x${y}\", scale = ${scale}, transform = ${transform}${mirror_field}, disabled = false })" >/dev/null 2>&1
}

ensure_awww() {
    if awww query >/dev/null 2>&1; then return 0; fi

    log "awww daemon unavailable; starting it"
    awww-daemon --no-cache >>"$log_file" 2>&1 &
    for _ in {1..20}; do
        awww query >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    log "awww daemon did not become ready"
    return 1
}

restart_awww() {
    log "restarting awww after output repair"
    awww kill >/dev/null 2>&1 || true
    sleep 0.35
    awww-daemon --no-cache >>"$log_file" 2>&1 &
    for _ in {1..20}; do
        awww query >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    log "awww daemon did not become ready after restart"
    return 1
}

apply_wallpaper() {
    local image
    image="$(wallpaper_path || true)"
    [[ -n "$image" && -f "$image" ]] || return 0
    ensure_awww || return 1
    awww img "$image" --resize crop --crop-gravity center -t none >/dev/null 2>&1
}

reconcile() {
    local active output name record repaired=0
    active="$(active_monitors)"
    [[ -n "$active" ]] || return 0
    output="$(awww_monitors)"

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if ! grep -Fxq "$name" <<<"$output"; then
            record="$(monitor_record "$name")"
            if [[ -n "$record" ]] && reinitialize_monitor "$record"; then
                repaired=1
            fi
        fi
    done <<<"$active"

    if (( repaired )); then
        sleep 0.5
        restart_awww || return 1
    else
        ensure_awww || return 1
    fi
    apply_wallpaper
}

# This helper is intentionally one-shot. Hyprland 0.57 removed the old
# `hyprctl -t subscribe` interface; the native Lua event handlers in
# hyprland.lua invoke this helper whenever the monitor topology changes.
# Keeping the repair one-shot also prevents an orphaned event loop after a
# compositor reload.
reconcile
