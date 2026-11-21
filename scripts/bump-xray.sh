#!/bin/sh
# bump-xray.sh — поднять версию Xray в проекте.
#
#   ./scripts/bump-xray.sh 26.10.21
#
# Что делает:
#   1) проверяет, что тег v<version> существует в XTLS/Xray-core;
#   2) скачивает sha256 всех linux-архивов этого релиза;
#   3) пишет installer/xray-checksums.txt;
#   4) обновляет version.mk (XRAY_VERSION / XRAY_TAG)
#      и константы в installer/shoulderx-install.sh (версия, тег, хеши).
#
# Нужен curl (или wget) и sha256sum.

set -eu

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version, например 26.10.21>" >&2; exit 2; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAG="v$VERSION"
API="https://api.github.com/repos/XTLS/Xray-core/releases/tags/$TAG"
ARCHES="arm64-v8a arm32-v7a arm32-v6 mips32 mips32le 64 32"

have() { command -v "$1" >/dev/null 2>&1; }

fetch() {
	if have curl; then curl -fsSL --connect-timeout 10 -m 60 "$1"
	else wget -q -T 60 -O - "$1"
	fi
}

echo "== проверяю $TAG"
fetch "$API" > /tmp/xray-release.json || { echo "нет релиза $TAG"; exit 1; }

echo "== собираю контрольные суммы"
TMP=$(mktemp)
: > "$TMP"
for a in $ARCHES; do
	name="Xray-linux-$a.zip"
	# digest есть в API (sha256:...), но на старых релизах может отсутствовать
	sum=$(tr ',' '\n' < /tmp/xray-release.json \
		| tr -d ' "' \
		| awk -v n="$name" 'BEGIN{RS="}"} $0 ~ "name:"n {for (i=1;i<=NF;i++) if ($i ~ /^sha256:/) print $i}' \
		| sed 's/^sha256://' | head -n 1)
	if [ -z "$sum" ]; then
		echo "  $name: нет digest в API, качаю архив для расчёта"
		fetch "https://github.com/XTLS/Xray-core/releases/download/$TAG/$name" > /tmp/xray-asset.zip
		sum=$(sha256sum /tmp/xray-asset.zip | awk '{print $1}')
		rm -f /tmp/xray-asset.zip
	fi
	printf '%s  %s\n' "$sum" "$name" >> "$TMP"
	echo "  $name  $sum"
done

mv "$TMP" "$ROOT/installer/xray-checksums.txt"

echo "== обновляю version.mk"
sed -i.bak \
	-e "s/^XRAY_VERSION:=.*/XRAY_VERSION:=$VERSION/" \
	-e "s/^XRAY_TAG:=.*/XRAY_TAG:=$TAG/" \
	"$ROOT/version.mk"
rm -f "$ROOT/version.mk.bak"

echo "== обновляю установщик"
INS="$ROOT/installer/shoulderx-install.sh"
sed -i.bak \
	-e "s/^XRAY_VERSION=\"[0-9.]*\"/XRAY_VERSION=\"$VERSION\"/" \
	-e "s|^XRAY_TAG=\"v[0-9.]*\"|XRAY_TAG=\"$TAG\"|" \
	"$INS"
rm -f "$INS.bak"

# хеши в установщике (функция xray_hash) — переписываем блок
python3 - "$INS" "$ROOT/installer/xray-checksums.txt" <<'PY'
import sys, re, pathlib
ins, sums = sys.argv[1], sys.argv[2]
data = {}
for line in pathlib.Path(sums).read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    sha, name = line.split()
    arch = name[len("Xray-linux-"):-len(".zip")]
    data[arch] = sha

src = pathlib.Path(ins).read_text(encoding="utf-8")
block = ["xray_hash() {   # sha256 архива Xray для архитектуры",
         "\tcase \"$1\" in"]
width = max(len(a) for a in data)
for arch, sha in data.items():
    block.append("\t\t%-*s echo \"%s\" ;;" % (width + 1, arch + ")", sha))
block.append("\tesac")
block.append("}")
new = "\n".join(block)
src = re.sub(r"xray_hash\(\) \{.*?\n\}\n", new + "\n", src, flags=re.S)
pathlib.Path(ins).write_text(src, encoding="utf-8")
print("блок xray_hash обновлён")
PY

echo "== готово: $VERSION ($TAG)"
echo "   не забудьте поднять PKG_VERSION в version.mk и Makefile при выпуске"
