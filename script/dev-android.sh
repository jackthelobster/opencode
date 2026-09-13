#!/data/data/com.termux/files/usr/bin/sh
# Android/Termux support for running opencode from source.
#
# Two problems on Android (bionic libc, process.platform === "android"):
#
# 1. OpenTUI's asset resolver only knows darwin/linux/win32, so the TUI dies
#    with "Unsupported OpenTUI Node asset target: android-arm64".
#    Fix: patch @opentui/core to map android -> linux.
#
# 2. The @opentui/core-linux-arm64 libopentui.so is glibc-linked: it needs
#    libm.so.6/libpthread.so.0/libdl.so.2 (bionic names differ) and
#    __errno_location/__fxstat/getcontext (bionic spells them differently or
#    omits them). Fix: strip the ELF gnu.version_r requirements and preload a
#    small shim library compiled with the NDK clang.
#
# Idempotent. Run after every fresh `bun install`.
set -e
ROOT="/data/data/com.termux/files/home/projects/opencode"
SHIMS="$HOME/opentui-shims"
CORE="$ROOT/node_modules/.bun"

mkdir -p "$SHIMS"

# --- 1. shim library ---------------------------------------------------------
cat > "$SHIMS/shim.c" <<'EOF'
/* Shim for loading glibc-linked native libs (libopentui.so) on Android. */
#include <sys/stat.h>
#include <ucontext.h>
#include <errno.h>
#include <string.h>

int *__errno_location(void) { return __errno(); }

int __fxstat(int version, int fd, struct stat *buf) {
    (void)version; /* glibc passes _STAT_VER (1) on aarch64 */
    return fstat(fd, buf);
}

/* bionic exports getcontext/setcontext/swapcontext since API 28 with the same
 * aarch64 mcontext layout; these shims only matter for older NDK headers. */
int getcontext(ucontext_t *ucp) { if (!ucp) return -1; memset(ucp, 0, sizeof(*ucp)); return 0; }
int setcontext(const ucontext_t *ucp) { (void)ucp; errno = ENOSYS; return -1; }
int swapcontext(ucontext_t *o, const ucontext_t *c) { (void)o; (void)c; errno = ENOSYS; return -1; }
EOF
aarch64-linux-android-clang -shared -fPIC -O2 "$SHIMS/shim.c" -o "$SHIMS/libshim.so"

# --- 2. bionic-compatible libopentui.so --------------------------------------
SRC_SO=$(find "$CORE" -maxdepth 1 -name '@opentui+core-linux-arm64@*' -not -name '*musl*' 2>/dev/null | head -1)
SRC_SO="$SRC_SO/node_modules/@opentui/core-linux-arm64/libopentui.so"
if [ ! -f "$SRC_SO" ]; then echo "libopentui.so not found — run bun install first" >&2; exit 1; fi
mkdir -p "$SHIMS/@opentui/core-linux-arm64"
python3 - "$SRC_SO" "$SHIMS/@opentui/core-linux-arm64/libopentui.so" <<'EOF'
import struct, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
shutil.copyfile(src, dst)
with open(dst, "r+b") as f:
    data = bytearray(f.read())
    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]
    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, stype, flags, addr, offset, size = struct.unpack_from("<IIQQQQ", data, off)
        sections.append((name, stype, offset, size))
    shstr = sections[e_shstrndx][2]
    def sname(n):
        end = data.index(b"\0", shstr + n)
        return data[shstr + n:end].decode()
    for name, stype, offset, size in sections:
        nm = sname(name)
        if stype == 0x6ffffffe or nm == ".gnu.version_r":
            data[offset:offset+size] = b"\0" * size  # drop glibc version reqs
        elif nm == ".gnu.version":
            for p in range(offset, offset + size, 2):
                struct.pack_into("<H", data, p, 1)  # unversioned symbols
    for name, stype, offset, size in sections:
        if stype == 6:  # SHT_DYNAMIC
            pos = offset
            while pos < offset + size:
                tag, _ = struct.unpack_from("<qQ", data, pos)
                if tag in (0x6ffffffe, 0x6fffffff):
                    data[pos+8:pos+16] = struct.pack("<Q", 0)
                elif tag == 0:
                    break
                pos += 16
            break
    f.seek(0); f.write(data)
print("patched", dst)
EOF

# bionic-name symlinks for the DT_NEEDED entries
ln -sfn /system/lib64/libc.so  "$SHIMS/libc.so.6"
ln -sfn /system/lib64/libm.so  "$SHIMS/libm.so.6"
ln -sfn /system/lib64/libc.so  "$SHIMS/libpthread.so.0"
ln -sfn /system/lib64/libdl.so "$SHIMS/libdl.so.2"

# --- 3. patch @opentui/core: android -> linux --------------------------------
python3 - <<'EOF'
import glob, re
root = "/data/data/com.termux/files/home/projects/opencode/node_modules/.bun"
pattern = """function getCurrentNodeAssetTarget() {
  const libc = process.env.OPENTUI_LIBC;
  if (process.platform === "linux\""""
replacement = """function getCurrentNodeAssetTarget() {
  const libc = process.env.OPENTUI_LIBC;
  const platform = process.platform === "android" ? "linux" : process.platform;
  if (platform === "linux\""""
count = 0
for path in glob.glob(root + "/@opentui+core@*/node_modules/@opentui/core/chunk-*.js"):
    with open(path) as f:
        text = f.read()
    if 'process.platform === "android"' in text:
        continue  # already patched
    new = text.replace(pattern, replacement)
    if new != text:
        # swap remaining process.platform refs inside this function body
        start = new.index("function getCurrentNodeAssetTarget()")
        end = new.index("}", new.index("libc === \"musl\" ? { libc }", start)) + 1
        body = new[start:end]
        body = body.replace("platform: process.platform,", "platform,").replace(
            "...process.platform === \"linux\"", "...platform === \"linux\"")
        new = new[:start] + body + new[end:]
        with open(path, "w") as f:
            f.write(new)
        count += 1
print(f"patched {count} opentui chunk file(s)")
EOF

echo "done. wrapper at /data/data/com.termux/files/usr/bin/opencode sets:"
echo "  LD_LIBRARY_PATH/LD_PRELOAD=$SHIMS  OTUI_ASSET_ROOT=$SHIMS"
