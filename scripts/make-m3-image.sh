#!/usr/bin/env bash
# =============================================================================
# M3 引导镜像打包（unicorn）—— 本地与 CI 通用
#
# 两种输入：
#   --kernel <mach.development.*>  先用 unixnu payload 生成 payload.img，再打包
#   --payload <payload.img>        直接用现成的 payload（FAT，含 EFI/UniXNU/Payloads/*）
#
# 产物：<out>/unicorn-uefi-M3-<name>.img
#       Android boot v4 = BootShim + FD + 追加 DTB + payload 作 ramdisk
#
# 为什么 ramdisk 必须是 payload：UniXNU 菜单的启动项来自 ramdisk 里的
# EFI/UniXNU/Payloads/kernel.macho（FAT/PONGFAT1）。ramdisk 为空 → 菜单没有可启动项。
#
# 为什么不用 `unixnu bootimg`：框架那个只支持 v0–v2 头（verify() 按 v0 偏移解析），
# 本机 ABL 需要 v4；固件仓的 scripts/build-bootimg.py 才是 v4。
# =============================================================================
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEVICE=$(dirname "$HERE")                       # UniXNU-unicorn
R=$(dirname "$DEVICE")                          # 工作根（CI 里是 workspace）
U="$R/UniXNU"
UEFI="${UNIXNU_UEFI:-$R/uefi-unicorn}"
OS_PROFILE="${OS_PROFILE:-$(sed -n 's/^os *= *"\(.*\)"/\1/p' "$DEVICE/board.toml" | head -1)}"
OUT="$U/out/unicorn/${OS_PROFILE}/unicorn_ipados18"
WIN=/mnt/d/iOS/unicorn-port/out

KERNEL=""
PAYLOAD=""
TARGET="${TARGET:-RELEASE}"
DEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kernel)  KERNEL=$2; shift 2 ;;
    --payload) PAYLOAD=$2; shift 2 ;;
    --target)  TARGET=$2; shift 2 ;;
    --out)     DEST=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$DEST" ] || DEST="$OUT/boot-m3"

FD="$UEFI/Build/unicornPkg/${TARGET}_CLANGPDB/FV/SILICIUM_UEFI.fd"
DTB="$UEFI/Platforms/Xiaomi/unicornPkg/FdtBlob/sm8475-xiaomi-unicorn.dtb"

echo "== 输入检查 =="
[ -f "$FD" ]  || { echo "缺固件: ${FD}（先跑 unixnu build firmware --target ${TARGET}）" >&2; exit 1; }
[ -f "$DTB" ] || { echo "缺 DTB: $DTB" >&2; exit 1; }
echo "  OS profile: $OS_PROFILE"
echo "  固件: $FD  ($(wc -c < "$FD" | tr -d ' ') B, sha256 $(shasum -a 256 "$FD" | cut -c1-16))"
echo "  DTB : $DTB ($(wc -c < "$DTB" | tr -d ' ') B, sha256 $(shasum -a 256 "$DTB" | cut -c1-16))"

if [ -z "$PAYLOAD" ]; then
  [ -n "$KERNEL" ] || { echo "需要 --kernel 或 --payload" >&2; exit 2; }
  echo "== 用 unixnu payload 生成 payload.img =="
  cd "$U"
  python3.12 ./unixnu payload -D "$DEVICE" --kernel "$KERNEL"
  PAYLOAD="$OUT/payload/payload.img"
fi
[ -f "$PAYLOAD" ] || { echo "payload 不存在: $PAYLOAD" >&2; exit 1; }
echo "  payload: $PAYLOAD ($(wc -c < "$PAYLOAD" | tr -d ' ') B)"

echo
echo "== 打包 v4 镜像（ramdisk = payload）=="
mkdir -p "$DEST"
python3 "$UEFI/scripts/build-bootimg.py" \
  --unixnu-root "$U" \
  --fd "$FD" \
  --config Resources/Configs/unicorn.toml \
  --dtb "$DTB" \
  --ramdisk "$PAYLOAD" \
  --output-dir "$DEST" >/dev/null

IMG="$DEST/pong-unixnu-uefi.img"
NAME="unicorn-uefi-M3.img"
cp "$IMG" "$DEST/$NAME"

echo
echo "== 结构校验 =="
python3 - "$DEST/$NAME" <<'PY'
import sys, pathlib, struct, zlib, hashlib
b = pathlib.Path(sys.argv[1]).read_bytes()
ksz, rsz, osver, hsz = struct.unpack_from('<IIII', b, 8)
ver = struct.unpack_from('<I', b, 40)[0]
page = 4096
kernel = b[page:page+ksz]
d = zlib.decompressobj(16 + zlib.MAX_WBITS); raw = d.decompress(kernel); tree = d.unused_data
print(f"  大小      : {len(b)} B")
print(f"  容器      : boot v{ver}, header_size={hsz}")
print(f"  kernel    : {ksz} B（解压后 shim+FD = {len(raw)}，FD sha {hashlib.sha256(raw[112:]).hexdigest()[:12]}）")
print(f"  追加 DTB  : {len(tree)} B（魔数 {tree[:4].hex()}）")
print(f"  ramdisk   : {rsz} B（payload）")
assert b[:8] == b'ANDROID!' and ver == 4 and tree[:4] == b'\xd0\x0d\xfe\xed', '结构不对'
start = page * (1 + -(-ksz // page))
ram = b[start:start+rsz]
for marker in (b'kernel.macho', b'Payloads'):
    print(f"  ramdisk 含 {marker.decode():<12}: {marker in ram}")
print("  结构校验通过")
PY

echo
echo "== 交付 =="
ls -l "$DEST/$NAME"
shasum -a 256 "$DEST/$NAME"
if [ -d "$(dirname "$WIN")" ]; then
  cp "$DEST/$NAME" "$WIN/$(basename "$DEST")-$(basename "$NAME")" 2>/dev/null && echo "  已复制到 D:\\iOS\\unicorn-port\\out\\" || true
fi
echo "上机：  fastboot boot <镜像>"
