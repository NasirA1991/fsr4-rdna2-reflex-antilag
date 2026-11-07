#!/usr/bin/env bash
# Build the "The Finals" FSR4+Reflex tool:
#   near-stock Proton-CachyOS with
#     - 2073850 removed from Proton's "disable NVAPI on non-NVIDIA" list
#     - no WINE_HIDE_AMD_GPU (AMD stays visible, so the amdxc64 shim runs)
#     - FSR4_MODEL=INT8_NAVI2 by default
#     - patched FSR 4.1.2 copied next to the game exe at launch
#   Latency method (Korthos layer / Mesa layer / vkd3d fork) is left to the
#   Steam launch options on purpose.
# Re-run after a Proton-CachyOS update.
set -euo pipefail

SRC="${1:-${PROTON_SRC:-$HOME/.local/share/Steam/compatibilitytools.d/Proton-CachyOS Latest-x86_64_v3}}"
TOOLS="${TOOLS_DIR:-$HOME/.local/share/Steam/compatibilitytools.d}"
BASE="$TOOLS/proton-cachyos-fsr4reflex"
STORE="$HOME/.local/share/fsr4"

[[ -d "$SRC" ]] || { echo "source not found: $SRC" >&2; exit 1; }
[[ "$BASE" == */compatibilitytools.d/proton-cachyos-fsr4reflex ]] || { echo "bad destination" >&2; exit 1; }
[[ -f "$STORE/amdxcffx64_412_stock.dll" ]] || { echo "missing $STORE/amdxcffx64_412_stock.dll" >&2; exit 1; }
[[ -f "$STORE/amdxcffx64_412_patched.dll" ]] || { echo "missing $STORE/amdxcffx64_412_patched.dll" >&2; exit 1; }
[[ -f "$STORE/apply.sh" ]] || { echo "missing $STORE/apply.sh" >&2; exit 1; }

cat > "$STORE/apply.sh" <<'APPLY'
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
APPLY
chmod +x "$STORE/apply.sh"

rm -rf -- "$BASE"
cp -a -- "$SRC" "$BASE"

cat > "$BASE/compatibilitytool.vdf" <<'VDF'
"compatibilitytools"
{
  "compat_tools"
  {
    "proton-cachyos-fsr4reflex"
    {
      "install_path" "."
      "display_name" "Proton-CachyOS FSR4 4.1.2 (stock only)"
      "from_oslist"  "windows"
      "to_oslist"    "linux"
    }
  }
}
VDF

python3 - "$BASE/proton" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding='utf-8').read()

if "FSR4_THE_FINALS_PRESET" not in src:
    old = """    g_session = Session()

    g_session.init_wine()
"""
    new = """    g_session = Session()

    # --- FSR4_THE_FINALS_PRESET ----------------------------------------------
    # Defaults only: Steam launch options still win.
    for _fsr_key, _fsr_val in (
        ("PROTON_FSR4_UPGRADE", "1"),
        ("PROTON_FORCE_NVAPI", "0"),
        ("DXVK_NVAPI_ALLOW_OTHER_DRIVERS", "1"),
    ):
        g_session.env.setdefault(_fsr_key, _fsr_val)
    # -------------------------------------------------------------------------

    g_session.init_wine()
"""
    if src.count(old) != 1:
        sys.exit("unexpected proton layout (preset)")
    src = src.replace(old, new, 1)

if "FSR4 DLL selector" not in src:
    old = """    protonfixes.execute()

    #determine mode
"""
    new = """    protonfixes.execute()

    # --- FSR4 DLL selector ---------------------------------------------------
    if sys.argv[1] in ("run", "waitforexitandrun"):
        _fsr4_helper = os.path.expanduser("~/.local/share/fsr4/apply.sh")
        _fsr4_exe = next((a for a in sys.argv[2:] if a.lower().endswith(".exe")), None)
        if _fsr4_exe and os.path.isfile(_fsr4_helper):
            try:
                _fsr4_mode = g_session.env.get("FSR4_DLL", "412s")
                if _fsr4_mode not in ("411", "412s", "412-stock") and not g_session.env.get("FSR4_ALLOW_PATCHED"):
                    _fsr4_mode = "412s"
                subprocess.run([_fsr4_helper, _fsr4_mode, _fsr4_exe],
                               check=False, timeout=120)
            except Exception as _fsr4_err:
                log("FSR4 helper failed: %s" % _fsr4_err)
    # -------------------------------------------------------------------------

    #determine mode
"""
    if src.count(old) != 1:
        sys.exit("unexpected proton layout (hook)")
    src = src.replace(old, new, 1)

if '"2073850", #The Finals' in src:
    src = src.replace(
        '                "2073850", #The Finals\n',
        '                # "2073850", #The Finals  # FSR4 tool: NVAPI without hiding the AMD GPU\n')

open(p, 'w', encoding='utf-8').write(src)
print("proton patched")
PY

python3 -m py_compile "$BASE/proton"

echo "built: $BASE"
echo "done — restart Steam."
