#!/bin/bash
# MarmotVPN runtime setup — builds a self-contained OpenVPN engine from
# Homebrew bottles (no Homebrew required) and relocates all Mach-O load
# paths to the target prefix. Usage: setup_runtime.sh <bottles_dir> <target_prefix>
set -euo pipefail

BOTTLES="$1"
TARGET="$2"

if [ -x "$TARGET/sbin/openvpn" ] && "$TARGET/sbin/openvpn" --version >/dev/null 2>&1; then
  echo "RUNTIME_OK"
  exit 0
fi

mkdir -p "$TARGET/opt" "$TARGET/sbin" "$TARGET/etc/openssl"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_dep() {
  local n="$1" f="$2" verd
  mkdir -p "$TMP/$n"
  tar xzf "$f" -C "$TMP/$n"
  verd=$(find "$TMP/$n" -mindepth 2 -maxdepth 2 -type d | head -1)
  [ -n "$verd" ] || { echo "EXTRACT_FAIL $n"; exit 1; }
  rm -rf "$TARGET/opt/$n"
  mkdir -p "$(dirname "$TARGET/opt/$n")"
  mv "$verd" "$TARGET/opt/$n"
}

extract_dep lzo             "$BOTTLES/lzo.tar.gz"
extract_dep lz4             "$BOTTLES/lz4.tar.gz"
extract_dep pkcs11-helper   "$BOTTLES/pkcs11-helper.tar.gz"
extract_dep openssl@3       "$BOTTLES/openssl@3.tar.gz"
extract_dep ca-certificates "$BOTTLES/ca-certificates.tar.gz"

mkdir -p "$TMP/openvpn"
tar xzf "$BOTTLES/openvpn.tar.gz" -C "$TMP/openvpn"
ovverd=$(find "$TMP/openvpn" -mindepth 2 -maxdepth 2 -type d | head -1)
mv "$ovverd/sbin/openvpn" "$TARGET/sbin/openvpn"

ln -sf "../opt/ca-certificates/share/ca-certificates/cert.pem" "$TARGET/etc/openssl/cert.pem"
chmod -R u+w "$TARGET"

# ---- Relocate Mach-O load paths ----
TARGET="$TARGET" python3 - <<'PYEOF'
import os, re, subprocess, glob

PREFIX = os.environ["TARGET"]

def repl(s: str) -> str:
    s = s.replace("@@HOMEBREW_PREFIX@@", PREFIX)
    s = re.sub(r"@@HOMEBREW_CELLAR@@/([^/]+)/[^/]+/", lambda m: PREFIX + "/opt/" + m.group(1) + "/", s)
    s = re.sub(r"@@HOMEBREW_CELLAR@@/([^/]+)/",       lambda m: PREFIX + "/opt/" + m.group(1) + "/", s)
    s = s.replace("@@HOMEBREW_CELLAR@@", PREFIX)
    return s

targets = ["sbin/openvpn"]
targets += [p[len(PREFIX)+1:] for p in glob.glob(PREFIX + "/opt/*/lib/**/*.dylib", recursive=True)]
targets += [p[len(PREFIX)+1:] for p in glob.glob(PREFIX + "/opt/*/lib/*/*.so", recursive=True)]
seen = []
for rel in sorted(set(targets)):
    f = os.path.join(PREFIX, rel)
    if not (os.path.isfile(f) and not os.path.islink(f)):
        continue
    out = subprocess.run(["otool", "-L", f], capture_output=True, text=True).stdout
    lines = out.splitlines()
    if lines and lines[0].endswith(":"):
        lines = lines[1:]
    deps = [l.strip().split(" ")[0] for l in lines if "@@" in l]
    changed = False
    for d in deps:
        nd = repl(d)
        if not os.path.exists(nd):
            print("MISSING", nd, "for", f)
            continue
        r = subprocess.run(["install_name_tool", "-change", d, nd, f], capture_output=True, text=True)
        if r.returncode:
            print("ERR", f, d, r.stderr.strip())
        else:
            changed = True
    idl = subprocess.run(["otool", "-D", f], capture_output=True, text=True).stdout.splitlines()
    if len(idl) > 1 and "@@" in idl[1]:
        r = subprocess.run(["install_name_tool", "-id", repl(idl[1]), f], capture_output=True, text=True)
        changed = changed and not r.returncode
    if changed:
        subprocess.run(["codesign", "--force", "-s", "-", f], capture_output=True, text=True)

# residue check
res = 0
for rel in sorted(set(targets)):
    f = os.path.join(PREFIX, rel)
    if not (os.path.isfile(f) and not os.path.islink(f)):
        continue
    out = subprocess.run(["otool", "-L", f], capture_output=True, text=True).stdout
    if "@@" in out:
        print("RESIDUE:", f)
        res += 1
print("RELOCATE_DONE residue=%d" % res)
PYEOF

"$TARGET/sbin/openvpn" --version >/dev/null && echo "RUNTIME_OK" || { echo "RUNTIME_FAIL"; exit 1; }
