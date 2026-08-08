# Iceraven OLED

Takes the official [Iceraven Browser](https://github.com/fork-maintainers/iceraven-browser)
arm64-v8a release, repaints its dark theme true black, re-signs it, and publishes
it here. Runs daily and only builds when upstream ships something new.

Nothing here is a fork. There is no upstream repo to sync — the workflow pulls
the stock APK from Iceraven's releases at build time.

## Layout

```
.github/workflows/build.yml   watch upstream, patch, sign, release
patch-oled.sh                 the actual recolouring (edit this to tune)
```

## Setup

### 1. Create the repo

New repository on GitHub, any name, public or private. Add the two files above.

### 2. Allow the workflow to publish

Settings → Actions → General → Workflow permissions → **Read and write
permissions** → Save.

The workflow also declares `permissions: contents: write`, but that only
narrows what the repo setting already allows — both have to be right.

### 3. Create a signing key

The stock Iceraven APK is debug-signed by its maintainers. Once you modify it,
the old signature is void and you have to sign with your own key. Generate one
**once** and keep it — losing it means you can never update your own installs
in place.

```
keytool -genkeypair -v \
  -keystore iceraven-oled.jks \
  -alias iceraven-oled \
  -keyalg RSA -keysize 4096 \
  -validity 10000
```

Android Studio can do the same through Build → Generate Signed App Bundle /
APK → Create new, if you'd rather not touch a terminal.

Then base64-encode it to a single line:

```
base64 -w0 iceraven-oled.jks            # Linux
base64 -i iceraven-oled.jks | tr -d '\n' # macOS
```

On Windows, `certutil -encode iceraven-oled.jks out.txt` then delete the
`-----BEGIN/END-----` lines and join the rest into one line.

### 4. Add three secrets

Settings → Secrets and variables → Actions → New repository secret:

| Name | Value |
|---|---|
| `KEYSTORE_B64` | the single-line base64 blob |
| `KEYSTORE_PASSWORD` | keystore password from step 3 |
| `KEY_PASSWORD` | key password (same as above unless you set them separately) |

Back up the `.jks` file somewhere outside GitHub. The base64 secret is
write-only once saved — you can't read it back out.

### 5. First run

Actions → **Build Iceraven OLED** → Run workflow. Leave *force* off, uncheck
*publish* for the first attempt — you'll get the APK as a build artifact you
can sideload and check before it becomes a public release.

Once it looks right, run again with *publish* on.

## Installing

The APK is signed with your key, so Android treats it as a different app
signature from any Iceraven you already have installed. First install requires
uninstalling the existing copy, which wipes browsing data. Export bookmarks
first if you care about them. After that, updates from this repo install over
each other normally.

## Tuning the theme

Everything adjustable lives in the arrays at the top of `patch-oled.sh`:

- `PHOTON_TARGETS` — the legacy Firefox palette. `ff15141a` is the main dark
  background.
- `NOVA_TARGETS` — the newer palette's elevated surfaces (cards, sheets,
  menus). Flattening all five is what removes every grey panel. Drop entries
  here if you want menus to stay visually distinct from the page behind them.
- `GECKO_TARGETS` — the colour painted behind a page while it loads.

Each run prints a per-patch summary. `MISS` means a pattern didn't match, which
usually means upstream renamed or restructured something — that part of the UI
will still be grey. The script hard-fails only if *nothing* matched.

To iterate locally without burning CI runs:

```
curl -sSfL -o apktool.jar https://github.com/iBotPeaches/Apktool/releases/download/v2.11.0/apktool_2.11.0.jar
# download a stock iceraven-*-arm64-v8a-forkRelease.apk from upstream releases
KEEP_WORK=1 ./patch-oled.sh iceraven.apk out.apk
```

`KEEP_WORK=1` leaves the decoded tree in `apk-work/` so you can grep for
colours you want to change next.

## When upstream breaks it

Iceraven tracks Fenix, and Mozilla reshuffles its colour code fairly often.
The failure mode is a build that succeeds with several `MISS` lines and ships
a half-black UI. If that happens:

1. Run locally with `KEEP_WORK=1`.
2. `grep -ri "ff1c1b22\|ff15141a\|Neutral6" apk-work/smali*/ | head` to find
   where the palette moved.
3. Update the arrays or the `first_match` globs in the script.

## Credit

The specific colour constants and the smali patch points were worked out by
[GoodyOG/Iceraven-OLED](https://github.com/GoodyOG/Iceraven-OLED) (MIT). This
is an independent reimplementation of the same idea with its own build
pipeline. Iceraven itself is by
[fork-maintainers](https://github.com/fork-maintainers/iceraven-browser).
