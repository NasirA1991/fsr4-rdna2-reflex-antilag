#!/usr/bin/env bash
# Build a near-stock Proton-CachyOS that can install FSR 4.1.2 (amdxcffx64.dll)
# through the normal PROTON_FSR4_UPGRADE mechanism, plus a per-model suffix:
#
#   PROTON_FSR4_UPGRADE=4.1.2        -> patched 4.1.2, FSR4_MODEL=INT8_NAVI2
#   PROTON_FSR4_UPGRADE=4.1.2-lite   -> patched 4.1.2, FSR4_MODEL=INT8_LITE
#   PROTON_FSR4_UPGRADE=4.1.2-int8   -> patched 4.1.2, FSR4_MODEL=INT8
#   PROTON_FSR4_UPGRADE=4.1.2-fp8    -> patched 4.1.2, FSR4_MODEL=FP8
#   PROTON_FSR4_UPGRADE=4.1.2-auto   -> patched 4.1.2, no model override
#   PROTON_FSR4_UPGRADE=4.1.1        -> stock protonfixes behaviour
#
# The DLL comes from ~/.local/share/fsr4/amdxcffx64_412_patched.dll
set -euo pipefail

SRC="${1:-${PROTON_SRC:-$HOME/.local/share/Steam/compatibilitytools.d/Proton-CachyOS Latest-x86_64_v3}}"
TOOLS="${TOOLS_DIR:-$HOME/.local/share/Steam/compatibilitytools.d}"
BASE="$TOOLS/proton-cachyos-fsr4-412"
STORE="$HOME/.local/share/fsr4"

[[ -d "$SRC" ]] || { echo "source not found: $SRC" >&2; exit 1; }
[[ "$BASE" == */compatibilitytools.d/proton-cachyos-fsr4-412 ]] || { echo "bad destination" >&2; exit 1; }
[[ -f "$STORE/amdxcffx64_412_patched.dll" ]] || { echo "missing $STORE/amdxcffx64_412_patched.dll" >&2; exit 1; }

echo "== base copy =="
rm -rf -- "$BASE"
cp -a -- "$SRC" "$BASE"

cat > "$BASE/compatibilitytool.vdf" <<'VDF'
"compatibilitytools"
{
  "compat_tools"
  {
    "proton-cachyos-fsr4-412"
    {
      "install_path" "."
      "display_name" "Proton-CachyOS 4.1.2 · patched INT8 Navi2"
      "from_oslist"  "windows"
      "to_oslist"    "linux"
    }
  }
}
VDF

python3 - "$BASE/protonfixes/upscalers.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if '__local_fsr4' in s:
    print("upscalers already patched")
    raise SystemExit(0)

if 'import filecmp' not in s:
    s = s.replace('import os\n', 'import os\nimport filecmp\nimport shutil\n', 1)

anchor = "__fsr4_section = 'fsr4_files'\n"
helpers = anchor + '''
__fsr4_local_models = (
    ('-lite', 'INT8_LITE'),
    ('-int8_lite', 'INT8_LITE'),
    ('-int8', 'INT8'),
    ('-navi2', 'INT8_NAVI2'),
    ('-fp8', 'FP8'),
    ('-auto', ''),
)


def __local_fsr4(version: str):
    """Map a local FSR4 version string to (dll_path, forced_model)."""
    name = version.strip().lower()
    model = 'INT8_NAVI2'
    for suffix, value in __fsr4_local_models:
        if name.endswith(suffix):
            name = name[: -len(suffix)]
            model = value
            break
    if name in ('4.1.2', '412'):
        return os.path.expanduser('~/.local/share/fsr4/amdxcffx64_412_patched.dll'), model
    return None


def __install_local_fsr4(src: str, compat_dir: str, prefix_dir: str, version: str) -> bool:
    dst_rel = 'drive_c/windows/system32/amdxcffx64.dll'
    dst = os.path.join(prefix_dir, dst_rel)
    try:
        if not os.path.isfile(dst) or not filecmp.cmp(dst, src, shallow=False):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
        with open(src, 'rb') as src_fd:
            md5 = hashlib.md5(src_fd.read()).hexdigest().upper()
        __set_tracked_items(compat_dir, __fsr4_section, {dst_rel: {'version': version, 'md5_hash': md5}})
        log.info(f'Local FSR4 "{version}" installed from "{src}".')
        return True
    except Exception as e:
        log.crit(f'Failed to install local FSR4 "{src}"')
        log.crit(str(e))
        return False
'''
if s.count(anchor) != 1:
    sys.exit("upscalers.py: section anchor not found")
s = s.replace(anchor, helpers, 1)

old = "    fsr4_version = get_version(env, 'PROTON_FSR4_UPGRADE', 'default')\n"
new = old + """    local_fsr4 = __local_fsr4(fsr4_version) if 'fsr4' in compat_config else None
    if local_fsr4 and local_fsr4[1]:
        env['FSR4_MODEL'] = local_fsr4[1]
"""
if s.count(old) != 1:
    sys.exit("upscalers.py: fsr4_version line not found")
s = s.replace(old, new, 1)

old = "        ('fsr4', fsr4_version, 'fsr4' in compat_config or 'optiscaler' in compat_config),\n"
new = "        ('fsr4', fsr4_version, ('fsr4' in compat_config or 'optiscaler' in compat_config) and not local_fsr4),\n"
if s.count(old) != 1:
    sys.exit("upscalers.py: fsr4 tuple not found")
s = s.replace(old, new, 1)

old = """    for upscaler in upscalers:
        name, version, enabled = upscaler
        if enabled and setup_upscaler(name, compat_dir, prefix_dir, version):
            log.info(f'Automatic {name} upgrade enabled.')
            upscaler_replace.add(name)
"""
new = old + """
    if local_fsr4 and ('fsr4' in compat_config or 'optiscaler' in compat_config):
        if __install_local_fsr4(local_fsr4[0], compat_dir, prefix_dir, fsr4_version):
            upscaler_replace.add('fsr4')
"""
if s.count(old) != 1:
    sys.exit("upscalers.py: upscaler loop not found")
s = s.replace(old, new, 1)

open(p, 'w', encoding='utf-8').write(s)
print("upscalers patched")
PY

python3 - "$BASE/proton" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'FSR4_DEFAULT_412' in s:
    print("default already present")
    raise SystemExit(0)
old = '''    if "STEAM_COMPAT_DATA_PATH" not in os.environ:
        log("No compat data path?")
        sys.exit(1)
'''
new = old + '''
    # FSR4_DEFAULT_412: this tool ships FSR 4.1.2 by default; a launch-option
    # PROTON_FSR4_UPGRADE=... still overrides it.
    os.environ.setdefault("PROTON_FSR4_UPGRADE", "4.1.2")
'''
if s.count(old) != 1:
    sys.exit("proton: main block not found")
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
print("default 4.1.2 set")
PY

python3 -m py_compile "$BASE/protonfixes/upscalers.py" "$BASE/proton"

echo "done — restart Steam."
