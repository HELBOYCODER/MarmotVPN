# MarmotVPN

**A native macOS menu-bar OpenVPN client for free VPN services — the Mac counterpart of the
[Free OpenVPN Connect SCRIPT for Linux](https://github.com/sbandur84/Free-OpenVPN-Connect-SCRIPT-for-Linux).**

The original project is a Linux bash script: it downloads free OpenVPN profiles
(VPNBook / VPNkeys), scrapes the shared username/password from the provider page, and connects
with `sudo openvpn`. It cannot run on macOS as-is (`apt/yum`, `dialog`, `gocr`, `tput` are
Linux-only). MarmotVPN re-implements the same idea as a proper Mac app, in the spirit of
menu-bar VPN clients like Vulpine.

## What it does

- **Self-contained OpenVPN engine** — no Homebrew, no installer. On first launch the app
  extracts OpenVPN 2.7.7 (+ OpenSSL 3, LZO, LZ4, pkcs11-helper) from bundled Homebrew *bottles*
  and relocates all Mach-O load paths into `~/Library/Application Support/MarmotVPN/runtime`.
- **Menu-bar client** — shield icon with live state colors: gray (disconnected), yellow
  (connecting), green (connected), red (failed).
- **Free profiles** — one-click download of VPNBook (PL/DE/US/CA/FR) and VPNkeys (US/UK/NL/SG)
  `.ovpn` bundles, exactly like the Linux script.
- **Automatic credentials** — fetches the shared password from the provider page; uses Apple
  **Vision OCR** for image-rendered passwords, falling back to a manual prompt.
- **Import any `.ovpn`** — works with your own servers too.
- **One-click connect / disconnect** — runs `openvpn --daemon` as root through a single admin
  authorization per action (macOS built-in privilege prompt).
- **Log viewer, engine repair, launch-at-login** (SMAppService).

## Build & run

```bash
./scripts/build_app.sh            # requires Xcode Command Line Tools
open build/MarmotVPN.app
```

Runtime bottles are expected in `research/` (or set `BOTTLES_SRC`). To refresh them
(Apple Silicon / Intel):

```bash
# resolve + download openvpn and its deps from ghcr.io (anonymous OCI token)
for f in openvpn lzo lz4 pkcs11-helper "openssl@3" ca-certificates; do
  enc=$(echo "$f" | sed 's/@/%40/;s|%403|/3|')   # openssl@3 -> openssl/3 on ghcr
  url=$(curl -s "https://formulae.brew.sh/api/formula/$f.json" | python3 -c \
    "import json,sys;d=json.load(sys.stdin)['bottle']['stable']['files'];k=next(x for x in d if x.startswith('arm64') or x=='all');print(d[k]['url'])")
  tok=$(curl -s "https://ghcr.io/token?scope=repository:homebrew/core/${enc}:pull" | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")
  curl -sL -H "Authorization: Bearer $tok" -o "$f.tar.gz" "$url"
done
```

## Status / limitations

- Free-VPN endpoints (vpnbook.com, vpnkeys.com) come and go and may be DNS-filtered on some
  networks — the app shows a clear error and you can still import any `.ovpn` manually.
- One admin prompt per connect/disconnect (a persistent privileged helper via `SMJobBless`
  is a planned v1.1 upgrade).
- Traffic stats and auto-reconnect: planned.

## Architecture

```
Sources/MarmotVPN/main.swift   AppKit menu-bar app (single file, ~550 lines)
scripts/setup_runtime.sh       bottle extract + Mach-O relocation (idempotent, verified)
scripts/build_app.sh           swiftc build + .app assembly + ad-hoc signing
assets/AppIcon.icns            marmot-over-shield brand icon
```

State machine: `disconnected → startingRuntime → launching → connecting → connected`
with `failed(msg)` branches; status is polled every 2 s from the openvpn pid file + log tail
(`Initialization Sequence Completed` / `TLS Error` / `AUTH_FAILED`).

## License

MIT (original Swift implementation). Conceptually derived from the GPLv2 Linux script by
Sebastijan Bandur — ideas, not code, were ported. Free services (VPNBook, VPNkeys) are
donation-supported; please donate if you use them.

---

## نسخه فارسی

MarmotVPN یک کلاینت OpenVPN منوبار برای مک است — معادل مکِ اسکریپت لینوکسی
«Free OpenVPN Connect». اسکریپت اصلی روی مک اجرا نمی‌شود (apt/dialog/gocr مخصوص لینوکس است)؛
این اپ همان ایده را بومی‌سازی کرده: دانلود خودکار پروفایل‌های رایگان VPNBook/VPNkeys،
استخراج نام‌کاربری/رمز از صفحه سرویس (با OCR بومی Apple Vision)، و اتصال با موتور
OpenVPN که خودش داخل اپ است — **بدون نیاز به Homebrew یا هیچ نصب اضافه**.

اجرا: `./scripts/build_app.sh && open build/MarmotVPN.app` — سپس از آیکون سپر در منوبار
پروفایل را انتخاب و Connect بزنید (یک بار رمز ادمین می‌خواهد). اگر شبکه شما دامنه‌های
VPNBook/VPNkeys را فیلتر DNS کند، اپ خطای روشن نشان می‌دهد و می‌توانید هر فایل `.ovpn`
دیگری را Import کنید.
