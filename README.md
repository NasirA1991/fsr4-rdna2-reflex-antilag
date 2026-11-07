# FSR 4.1.2 on RDNA2 — with NVIDIA Reflex **or** AMD Anti-Lag 2

Notes from getting **AMD FSR 4.1.2 running on an RX 6800 XT (Navi 21, RDNA2)**
under **Proton-CachyOS**, together with a latency feature — either
**NVIDIA Reflex** (Squad) or **AMD Anti-Lag 2** (The Finals).

The short version: on RDNA2 the FSR 4.1.2 driver DLL works fine when the GPU is
visible as AMD, and Anti-Lag 2 coexists with it. Reflex is the hard one — the
game has to believe it is on NVIDIA, which changes what the FSR DLL sees, so
you need the model-selection patch and a decision about *where* the DLL lives.

Everything below was verified on the machine described in
[Tested environment](#tested-environment), using Proton logs, `vulkaninfo`, and
the games' own settings files.

---

## TL;DR

| Game | FSR 4.1.2 | Latency feature | DLL used | Where the DLL lives |
|---|---|---|---|---|
| **The Finals** | ✅ `FSR4-i8-2` (Navi2) | **Anti-Lag 2** via Korthos layer | AMD **signed** 4.1.2 | game's `Binaries/Win64` |
| **Squad** | ✅ `FSR4-i8-2` (forced) | **Reflex** via NVAPI + Korthos layer | **patched** 4.1.2 | Wine prefix `system32` (not the game folder) |

Two recipes, two different spoof levels, one shared mechanism: the `amdxc64`
shim that vkd3d-proton loads for AMD GPUs.

---

## Tested environment

| | |
|---|---|
| GPU | AMD Radeon RX 6800 XT (Navi 21, family `0x8f`, device `0x3F`) |
| Driver | Mesa 26.2.6 (RADV), kernel 7.3 CachyOS |
| Proton | **Proton-CachyOS 11.0-20261015** (`cachyos-11.0-20261015-slr`) |
| FSR DLL | `amdxcffx64.dll` from **AMD Adrenalin 26.10.1 WHQL**, timestamp `0x6ac90bb5` |
| Patch | [skare-sandbox/fsr4-free-model-selection-patch](https://github.com/skare-sandbox/fsr4-free-model-selection-patch) |
| Latency layer | [Korthos-Software/low_latency_layer](https://github.com/Korthos-Software/low_latency_layer) (bundled with Proton-CachyOS) |
| Reflex backend | [dxvk-nvapi](https://github.com/jp7677/dxvk-nvapi) (bundled) |

---

## 1. How FSR 4.1.2 reaches an FSR 3.1 game

`vkd3d-proton` has a vendor hack: when the Vulkan device vendor is AMD
(`0x1002`) it loads `amdxc64.dll` (Wine's shim). The CachyOS build of that shim
then does, in effect:

```c
h = LoadLibraryA("amdxcffx64.dll");          /* name only, no path */
p = GetProcAddress(h, "UpdateFfxApiProviderEx");
```

`LoadLibraryA` with a bare name searches **the application directory first**,
then `system32`. So the DLL that ends up in the game's process is:

1. `<game binary dir>\amdxcffx64.dll` if present, else
2. `<prefix>\drive_c\windows\system32\amdxcffx64.dll`.

That is the whole trick. No OptiScaler, no DLL injection — the shim registers
the driver's FSR4 provider through the normal `ffx_api` dispatcher.

### Providers inside the 4.1.2 DLL

| Provider string | RTTI class | Native gate |
|---|---|---|
| `FSR4` | `Fsr4UpscalerModel` | RDNA4, gfx12xx |
| `FSR4-i8` | `Fsr4Int8UpscalerModel` | RDNA3, family `0x91` |
| `FSR4L-i8` | `Fsr4LiteInt8UpscalerModel` | RDNA3.5, family `0x96` |
| `FSR4-i8-2` | `Fsr4Int8navi2UpscalerModel` | **RDNA2, family `0x8f`, devices `0x28–0x4F`** |

With no override, the DLL reads the adapter and picks the matching gate — on a
6800 XT that is `FSR4-i8-2` automatically. The in-game watermark confirms it:

```
FSR4-I8 UPSCALE 4.1.2
```

### What the patch adds

The patch rewrites the eight `IsSupported` gates so `FSR4_MODEL` can force one
provider regardless of the detected GPU:

```
FSR4_MODEL=FP8 | INT8 | INT8_LITE | INT8_NAVI2 | FSR3 | NONE
```

When the variable is unset, each gate re-executes its original bytes — i.e.
stock behaviour. The patch does not add hardware capability; forcing a
wrong-generation model can fail shader compilation.

---

## 2. The four "spoofs" and what each breaks

This is the part that decides everything. There are four ways to make a game
believe it is on NVIDIA, and they sit at different layers:

| Mechanism | Game sees | vkd3d sees | FSR DLL sees | FSR 4.1.2? |
|---|---|---|---|---|
| *(none)* | AMD | AMD | AMD | ✅ auto Navi2 |
| `DXVK_CONFIG="dxgi.customDeviceDesc=…"` | NVIDIA name | AMD | AMD (vendor) | ✅ |
| `DXVK_CONFIG="dxgi.hideAmdGpu=True"` | NVIDIA | AMD | NVIDIA | ⚠️ needs patched DLL |
| `PROTON_FORCE_NVAPI=1` (`WINE_HIDE_AMD_GPU`) | NVIDIA | **NVIDIA** | NVIDIA | ❌ shim never loads |
| `LOW_LATENCY_LAYER_SPOOF_NVIDIA=1` | NVIDIA | **NVIDIA** | NVIDIA | ❌ shim never loads |

Two rules fall out of this:

1. **Any spoof that reaches the Vulkan layer kills FSR4 completely** — vkd3d's
   vendor check fails, `amdxc64` is never loaded, so `amdxcffx64` never enters
   the process. The patched DLL cannot help there; it is never loaded.
2. **A DXGI-only spoof keeps the shim alive**, but the DLL reads the same DXGI
   adapter description the game does. So the stock DLL now sees NVIDIA, its
   gates fail, and it serves **FSR 3.1.6** instead. Only the patched DLL
   (`FSR4_MODEL=INT8_NAVI2`) survives that combination.

There is no configuration where the game sees NVIDIA and the *stock* DLL still
detects RDNA2 — they read the same structure.

---

## 3. Anti-Lag 2 (The Finals)

The Finals supports Anti-Lag 2 natively (`bAntiLag2Enabled=True`). Under Wine it
is implemented on the Vulkan side:

```c
/* vkd3d-proton, ID3D12Device::QueryInterface */
if (IsEqualGUID(riid, &IID_IAmdExtAntiLagApi)) {
    if (device->device_info.anti_lag_amd.antiLag && !device->vk_info.NV_low_latency2)
        ...;
    else return E_NOINTERFACE;
}
```

So the game only gets `IAmdExtAntiLagApi` if the Vulkan device exposes
**`VK_AMD_anti_lag`** and **not** `VK_NV_low_latency2`. RADV does not expose it
by itself; a layer has to provide it:

| Layer | Enable | Notes |
|---|---|---|
| `VK_LAYER_KORTHOS_low_latency` | `LOW_LATENCY_LAYER=1` | bundled with Proton-CachyOS |
| `VK_LAYER_MESA_anti_lag` | `ENABLE_LAYER_MESA_ANTI_LAG=1` | Mesa 26.2 reworked the wait-time calculation ([MR !41727](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/41727)) |

Use **one**, never both — two implementations of the same device extension.
`DISABLE_LAYER_MESA_ANTI_LAG=1` only affects Mesa's layer.

With `LOW_LATENCY_LAYER=1` the device extension list gains `VK_AMD_anti_lag`
(verifiable with `vulkaninfo`), and the game's Anti-Lag 2 toggle actually drives
the swapchain. No spoof, no NVAPI, so **FSR 4.1.2 keeps working**.

---

## 4. Reflex (Squad)

Reflex is `NVAPI → dxvk-nvapi → VK_NV_low_latency2`. The Korthos layer can
provide that extension instead of Anti-Lag:

```
LOW_LATENCY_LAYER=1 LOW_LATENCY_LAYER_REFLEX=1
```

But Squad uses **NVIDIA Streamline**, and `sl.reflex` performs its own check.
Even with the extension exposed and dxvk-nvapi reporting support, the game logs:

```
FStreamlineMaxTickRateHandler::SetEnabled
  Tried to set SL Reflex Low Latency state but SL Reflex is not available
```

The fix is a **DXGI-only** spoof (`dxgi.hideAmdGpu=True`): the game/Streamline
sees NVIDIA, while vkd3d still sees AMD and loads the shim. The cost is that the
stock FSR DLL now sees NVIDIA too — hence the patched DLL and
`FSR4_MODEL=INT8_NAVI2`.

### vkd3d-low-latency is *not* the answer here

That fork adds a frame pacer with two triggers: NVAPI Reflex or a **waitable
DXGI swapchain**. Measured in both games:

```
waitable dxgi swapchain present percentage: 0.0%, total frames 4096
```

So without Reflex the pacer is idle, and with Reflex the layer/dxvk-nvapi path
already handles pacing. It does nothing for the Anti-Lag 2 config.

---

## 5. Recipe A — The Finals: FSR 4.1.2 + Anti-Lag 2, signed DLL

**Proton build:** near-stock Proton-CachyOS 11.0-20261015, plus

* a launch hook that copies AMD's **signed** 4.1.2 into the folder that holds
  the real game binary (see [§9](#9-the-ue-launcher-path-pitfall)),
* `2073850` removed from Proton's "disable NVAPI on non-NVIDIA" list (only
  matters for Reflex experiments; harmless otherwise),
* defaults: `PROTON_FSR4_UPGRADE=1`, `PROTON_FORCE_NVAPI=0`,
  `DXVK_NVAPI_ALLOW_OTHER_DRIVERS=1`. No latency option is baked in.

**Launch options:**

```
LOW_LATENCY_LAYER=1 PROTON_FSR4_INDICATOR=1 PROTON_USE_NTSYNC=1 PROTON_ENABLE_WAYLAND=1 mangohud game-performance %command%
```

| Option | What it does |
|---|---|
| `LOW_LATENCY_LAYER=1` | Korthos layer → `VK_AMD_anti_lag` → vkd3d exposes `IAmdExtAntiLagApi` → the game's **Anti-Lag 2** works |
| `PROTON_FSR4_INDICATOR=1` | sets the FSR watermark, i.e. your proof the driver DLL is upscaling (`FSR4-I8 UPSCALE 4.1.2`) |
| `PROTON_USE_NTSYNC=1` | Wine NTSYNC (unrelated, preference) |
| `PROTON_ENABLE_WAYLAND=1` | Wine Wayland driver (unrelated, preference) |
| `mangohud`, `game-performance` | overlay / CachyOS performance profile |

**Expected:** watermark 4.1.2, in-game Anti-Lag 2 toggle on, `NvReflexMode=Off`.
No vendor spoof, no modified DLL in the game folder.

---

## 6. Recipe B — Squad: FSR 4.1.2 + Reflex, patched DLL in the prefix

**Proton build:** same base, but without the game-folder hook. Instead
`protonfixes` is extended so `PROTON_FSR4_UPGRADE=4.1.2*` installs the patched
DLL into the **prefix** and derives `FSR4_MODEL` from the version suffix.

**Launch options:**

```
PROTON_FSR4_UPGRADE=4.1.2 DXVK_CONFIG="dxgi.hideAmdGpu=True" LOW_LATENCY_LAYER=1 LOW_LATENCY_LAYER_REFLEX=1 PROTON_USE_NTSYNC=1 PROTON_ENABLE_WAYLAND=1 mangohud game-performance %command%
```

| Option | What it does |
|---|---|
| `PROTON_FSR4_UPGRADE=4.1.2` | installs patched 4.1.2 into the prefix `system32` and sets `FSR4_MODEL=INT8_NAVI2` (suffixes: `-lite`, `-int8`, `-fp8`, `-auto`) |
| `DXVK_CONFIG="dxgi.hideAmdGpu=True"` | DXGI reports NVIDIA → Streamline's `sl.reflex` check passes, Reflex becomes available |
| `LOW_LATENCY_LAYER=1` | enables the Korthos layer |
| `LOW_LATENCY_LAYER_REFLEX=1` | layer exposes `VK_NV_low_latency2` instead of `VK_AMD_anti_lag` → dxvk-nvapi → Reflex backend |
| `PROTON_USE_NTSYNC`, `PROTON_ENABLE_WAYLAND`, `mangohud`, `game-performance` | as above |

Why it gives both:

```
game (DXGI)      → NVIDIA  → sl.reflex check passes
vkd3d (Vulkan)   → AMD     → amdxc64 shim loads
shim             → LoadLibraryA("amdxcffx64") → app dir empty → system32
prefix system32  → patched 4.1.2 → FSR4_MODEL=INT8_NAVI2 forced
```

Verified from the Proton log:

```
Loaded L"C:\windows\system32\amdxcffx64.dll"      (prefix, not the game folder)
NvAPI_D3D_SetSleepMode (Enabled/4166us): OK       ×97
```

---

## 7. Trade-off matrix

| Spoof | DLL | FSR 4.1.2 | Reflex | Anti-Lag 2 |
|---|---|---|---|---|
| none | signed | ✅ auto Navi2 | ❌ | ✅ (layer) |
| `dxgi.customDeviceDesc` (name only) | signed | ✅ | ❌ (vendor check) | ✅ |
| `dxgi.hideAmdGpu` | signed | ❌ FSR 3.1.6 | ✅ | ❌ |
| `dxgi.hideAmdGpu` | patched | ✅ forced Navi2 | ✅ | ❌ |
| `PROTON_FORCE_NVAPI=1` / layer spoof | any | ❌ shim never loads | ✅ | ❌ |

---

## 8. Anti-cheat: where the DLL lives

| Placement | Visible to install-integrity scans | Notes |
|---|---|---|
| `<game>/Binaries/Win64/amdxcffx64.dll` | **yes** | simplest, but a modified file inside the game |
| `<prefix>/drive_c/windows/system32/amdxcffx64.dll` | no (Wine prefix) | still loaded into the process; module is unsigned |

The signed AMD DLL is preferable where possible — it is byte-identical to the
driver's copy, so only its location is unusual. The patched DLL invalidates
AMD's Authenticode signature.

This is a mitigation, not a guarantee: an anti-cheat that inspects loaded
modules/signatures can still see it. Both games ship anti-cheat (Denuvo
Anti-Cheat in The Finals, EasyAntiCheat in Squad). Use at your own risk.

---

## 9. The UE launcher path pitfall

Steam often passes the *launcher* exe, while the real image is nested:

```
<game>/Squad.exe                              ← what Steam passes
<game>/SquadGame/Binaries/Win64/SquadGame-Win64-Shipping.exe   ← real image
```

The app directory for DLL search is the directory of the **real image**, so a
DLL dropped next to the launcher is never loaded. `scripts/apply-fsr4-dll.sh`
resolves it:

1. a `<Project>/Binaries/Win64` that contains an exe with the same basename, else
2. a `<Project>/Binaries/Win64` that contains a `*Shipping*.exe`, else
3. the launcher's own folder.

---

## 10. Building the Proton tools

Both tools are copies of Proton-CachyOS with small, readable patches:

| Script | Builds | Changes |
|---|---|---|
| `scripts/make-stock-tool.sh` | the "stock only" tool | launch hook that copies the **signed** DLL; preset; optional NVAPI-list tweak |
| `scripts/make-patched-tool.sh` | the "patched" tool | `protonfixes/upscalers.py` understands local `4.1.2*` versions and installs the patched DLL into the prefix; model from the version suffix; no hook |

Prerequisites:

```bash
mkdir -p ~/.local/share/fsr4
# 1. extract amdxcffx64.dll from your own Adrenalin package:
#    Packages/Drivers/Display/<INF>/<build>/amdxcffx64.dll
cp /path/to/amdxcffx64.dll          ~/.local/share/fsr4/amdxcffx64_412_stock.dll
# 2. build the patched variant with the community patcher, then:
cp amdxcffx64_patched.dll           ~/.local/share/fsr4/amdxcffx64_412_patched.dll
cp /path/to/older/amdxcffx64.dll    ~/.local/share/fsr4/amdxcffx64_411_stock.dll   # optional
```

Then edit `PROTON_SRC` at the top of each script to point at your
`compatibilitytools.d/Proton-CachyOS …` folder and run it. Restart Steam
afterwards to pick up the new entries.

`scripts/apply-fsr4-dll.sh` is the installer used by the hook:

```bash
apply-fsr4-dll.sh 412s "/path/to/<game>/<Project>/Binaries/Win64/<Game>.exe"   # signed
apply-fsr4-dll.sh 412p "/path/to/<game>/<Project>/Binaries/Win64/<Game>.exe"   # patched
apply-fsr4-dll.sh 411  "/path/to/<game>/<Project>/Binaries/Win64/<Game>.exe"   # 4.1.1
```

---

## 11. Credits

* [skare-sandbox/fsr4-free-model-selection-patch](https://github.com/skare-sandbox/fsr4-free-model-selection-patch) — the `FSR4_MODEL` gate patch and its RVA documentation.
* [netborg-afps/vkd3d-low-latency](https://github.com/netborg-afps/vkd3d-low-latency) — the low-latency vkd3d fork and the AMD Reflex discussion (#3).
* [Korthos-Software/low_latency_layer](https://github.com/Korthos-Software/low_latency_layer) — `VK_AMD_anti_lag` / `VK_NV_low_latency2` implementations.
* [jp7677/dxvk-nvapi](https://github.com/jp7677/dxvk-nvapi) — the NVAPI bridge.
* Mesa [MR !41727](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/41727) — Anti-Lag wait-time rework.
* CachyOS Proton for shipping the shim and the layer.

## 12. Legal / disclaimer

No AMD binaries are distributed here. `amdxcffx64.dll` is AMD proprietary
software: extract it from a driver you are licensed to use, and do not
redistribute it. Patching it invalidates its signature and may violate AMD's
terms; anti-cheat systems may object. Everything here is provided as-is for
experimentation on your own hardware, with no warranty.
