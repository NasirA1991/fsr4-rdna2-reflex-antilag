#!/usr/bin/env bash
# apply.sh <411|412s|412p> <game exe passed by Steam>
# Installs the requested DLL in the directory that actually holds the game
# binary. Steam often passes a launcher exe in the game root while the real
# binary lives in <Project>/Binaries/Win64, so resolve that first.
set -euo pipefail
mode="${1:-412s}"
target="${2:-}"
[[ -n "$target" ]] || exit 0
dir="$(dirname -- "$target")"
[[ -d "$dir" ]] || exit 0
base="$(basename -- "$target")"
case "$mode" in
    411)  src="$HOME/.local/share/fsr4/amdxcffx64_411_stock.dll" ;;
    412p|412|patched) src="$HOME/.local/share/fsr4/amdxcffx64_412_patched.dll" ;;
    *)    src="$HOME/.local/share/fsr4/amdxcffx64_412_stock.dll" ;;
esac
[[ -f "$src" ]] || { echo "fsr4: missing $src" >&2; exit 1; }
dirs=()
for sub in "$dir"/*/Binaries/Win64; do
    [[ -d "$sub" && -f "$sub/$base" ]] && dirs+=("$sub")
done
if [[ ${#dirs[@]} -eq 0 ]]; then
    # launcher exe name differs from the shipping binary (e.g. Squad)
    for sub in "$dir"/*/Binaries/Win64; do
        [[ -d "$sub" ]] || continue
        compgen -G "$sub/*Shipping*.exe" >/dev/null && dirs+=("$sub")
    done
fi
[[ ${#dirs[@]} -eq 0 ]] && dirs=("$dir")
for d in "${dirs[@]}"; do
    dst="$d/amdxcffx64.dll"
    if [[ -f "$dst" ]] && cmp -s -- "$dst" "$src"; then
        continue
    fi
    tmp="$dst.tmp.$$"
    cp -- "$src" "$tmp"
    mv -f -- "$tmp" "$dst"
    echo "fsr4: installed $(basename "$src") in $d"
done
