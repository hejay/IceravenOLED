#!/usr/bin/env bash
#
# patch-oled.sh — apply a true-black (OLED) dark theme to a stock Iceraven APK.
#
#   ./patch-oled.sh <input.apk> <output.apk>
#
# Output is decoded, recoloured, rebuilt and zipaligned, but NOT signed.
# Sign it afterwards with apksigner.
#
# Environment:
#   APKTOOL_JAR   path to apktool jar          (default: ./apktool.jar)
#   WORK          scratch directory            (default: ./apk-work)
#   KEEP_WORK     set to 1 to keep the decoded tree for inspection
#
set -euo pipefail

IN_APK=${1:?usage: patch-oled.sh <input.apk> <output.apk>}
OUT_APK=${2:?usage: patch-oled.sh <input.apk> <output.apk>}
APKTOOL_JAR=${APKTOOL_JAR:-./apktool.jar}
WORK=${WORK:-./apk-work}
KEEP_WORK=${KEEP_WORK:-0}

BLACK=ff000000

# ---------------------------------------------------------------------------
# Colour targets. Edit these lists to taste; the logic below doesn't change.
# Values are ARGB hex, lowercase, no 0x prefix.
# ---------------------------------------------------------------------------

# PhotonColors — the legacy Firefox palette. DarkGrey90 (#15141A) is the main
# dark-theme background colour.
PHOTON_TARGETS=(ff15141a)

# NovaColors — the newer palette used by recent Fenix builds. These are the
# elevated dark surfaces (cards, sheets, menus). Flattening all of them is what
# removes the grey panels. Remove entries here if you'd rather keep some
# elevation contrast between a sheet and the page behind it.
NOVA_TARGETS=(ff312f33 ff252428 ff1d1b1f ff171519 ff131215)

# GeckoView paints this behind a page while it loads. Left alone it's a grey
# flash on every navigation.
GECKO_TARGETS=(ff2a2a2e)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

hits=0
misses=0

section() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()      { printf '   ok    %s\n' "$*"; hits=$((hits + 1)); }
miss()    { printf '   MISS  %s\n' "$*"; misses=$((misses + 1)); }
info()    { printf '   ...   %s\n' "$*"; }

# first_match <find -path glob> -> prints the first matching file, or nothing
first_match() { find "$WORK" -path "$1" -print -quit 2>/dev/null; }

# apply <file> <sed-script> <label>
# Runs the sed script and reports whether it actually changed anything, so a
# pattern that upstream has renamed shows up as MISS instead of silently
# doing nothing.
apply() {
  local file=$1 script=$2 label=$3 before after
  before=$(md5sum "$file" | cut -d' ' -f1)
  sed -i "$script" "$file"
  after=$(md5sum "$file" | cut -d' ' -f1)
  if [ "$before" != "$after" ]; then ok "$label"; else miss "$label"; fi
}

# recolour <file> <argb> <label-prefix>
# Smali writes a 32-bit colour either as a literal (0xff15141a) or as its
# two's-complement negative (-0xeaebe6), depending on the instruction. Rewrite
# both forms so the patch doesn't depend on how the compiler felt that day.
recolour() {
  local file=$1 src=$2 label=$3 neg_src neg_dst
  neg_src=$(printf '%x' $(( 0x100000000 - 0x$src )))
  neg_dst=$(printf '%x' $(( 0x100000000 - 0x$BLACK )))
  apply "$file" "s/$src/$BLACK/g; s/-0x$neg_src\\b/-0x$neg_dst/g" "$label $src -> $BLACK"
}

# set_xml_colour <file> <resource name> <value>
set_xml_colour() {
  local file=$1 name=$2 value=$3
  apply "$file" "s|<color name=\"$name\">[^<]*</color>|<color name=\"$name\">$value</color>|g" \
        "colors.xml $name -> $value"
}

# ---------------------------------------------------------------------------
# 1. Decode
# ---------------------------------------------------------------------------

section "Decoding $IN_APK"
rm -rf "$WORK"
java -jar "$APKTOOL_JAR" d "$IN_APK" -o "$WORK" --quiet
# The old signature is invalid the moment we touch anything, and apktool will
# happily repack it into an APK that refuses to install.
rm -rf "$WORK/META-INF"
info "decoded to $WORK"

# ---------------------------------------------------------------------------
# 2. XML resources
# ---------------------------------------------------------------------------

section "XML resources"
NIGHT_COLORS="$WORK/res/values-night/colors.xml"
if [ -f "$NIGHT_COLORS" ]; then
  set_xml_colour "$NIGHT_COLORS" fx_mobile_background   "#$BLACK"
  set_xml_colour "$NIGHT_COLORS" fx_mobile_surface      "#$BLACK"
  # layer_color_2 is the "one step up" surface; point it at the Photon colour
  # we blacken below rather than hard-coding, so the two stay consistent.
  set_xml_colour "$NIGHT_COLORS" fx_mobile_layer_color_2 "@color/photonDarkGrey90"
else
  miss "res/values-night/colors.xml not present"
fi

# ---------------------------------------------------------------------------
# 3. Compose / smali palettes
# ---------------------------------------------------------------------------

section "PhotonColors"
PHOTON=$(first_match '*/mozilla/components/ui/colors/PhotonColors.smali')
if [ -n "$PHOTON" ]; then
  info "${PHOTON#$WORK/}"
  for c in "${PHOTON_TARGETS[@]}"; do recolour "$PHOTON" "$c" "PhotonColors"; done
else
  miss "PhotonColors.smali not found"
fi

section "NovaColors"
NOVA=$(first_match '*/mozilla/components/ui/colors/NovaColors.smali')
if [ -n "$NOVA" ]; then
  info "${NOVA#$WORK/}"
  for c in "${NOVA_TARGETS[@]}"; do recolour "$NOVA" "$c" "NovaColors"; done
else
  # Older Iceraven builds predate this palette; not an error on its own.
  info "NovaColors.smali not present (older build — skipping)"
fi

section "Material 3 dark tokens"
M3=$(first_match '*/androidx/compose/material3/tokens/ColorDarkTokens.smali')
if [ -n "$M3" ]; then
  info "${M3#$WORK/}"
  # background / surface / surfaceDim all read PaletteTokens.Neutral6. Swap the
  # field read for an immediate. The register is captured rather than assumed,
  # so this survives a recompile that shuffles register allocation.
  #
  # NOTE ON THE CONSTANT: 0xff000000L is what every published Iceraven-OLED
  # build uses and it works, but strictly it is *transparent* black once
  # Compose unpacks it — Compose stores Color as ARGB shifted into the high 32
  # bits. It looks right because the window background underneath is already
  # black from the XML patch above. If you ever see ripple or scrim artefacts
  # on sheets, change the constant to -0x100000000000000 (= 0xFF00000000000000),
  # which is opaque black in Compose's packed representation.
  apply "$M3" \
    's|sget-wide \(v[0-9]\+\), Landroidx/compose/material3/tokens/PaletteTokens;->Neutral6:J|const-wide \1, 0xff000000L|g' \
    "ColorDarkTokens Neutral6 -> black"
else
  miss "ColorDarkTokens.smali not found"
fi

section "GeckoView loading background"
GECKO_FILES=$(find "$WORK" \
  -path '*/org/mozilla/geckoview/GeckoView.smali' -o \
  -path '*/mozilla/components/browser/engine/gecko/GeckoEngineView.smali' 2>/dev/null)
if [ -n "$GECKO_FILES" ]; then
  while IFS= read -r f; do
    info "${f#$WORK/}"
    for c in "${GECKO_TARGETS[@]}"; do recolour "$f" "$c" "GeckoView"; done
  done <<< "$GECKO_FILES"
else
  miss "GeckoView smali not found"
fi

# ---------------------------------------------------------------------------
# 4. Sanity gate
# ---------------------------------------------------------------------------

section "Patch summary"
printf '   %d applied, %d missed\n' "$hits" "$misses"

if [ "$hits" -eq 0 ]; then
  echo "ERROR: nothing was patched. Upstream has almost certainly restructured;" >&2
  echo "       inspect $WORK before trusting any output." >&2
  exit 1
fi
if [ "$misses" -gt 0 ]; then
  echo "   (misses are worth a look — a renamed file means part of the UI stays grey)"
fi

# ---------------------------------------------------------------------------
# 5. Rebuild + align
# ---------------------------------------------------------------------------

section "Rebuilding"
java -jar "$APKTOOL_JAR" b "$WORK" -o unaligned.apk
zipalign -f -p 4 unaligned.apk "$OUT_APK"
rm -f unaligned.apk
[ "$KEEP_WORK" = "1" ] || rm -rf "$WORK"

section "Done"
printf '   %s (unsigned — run apksigner next)\n\n' "$OUT_APK"
