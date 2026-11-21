# Сборка и релиз

Два пакета: `shoulderx` (бэкенд + CLI) и `luci-app-shoulderx` (страница в LuCI).
Оба помечены `PKGARCH:=all` — ucode и JS от архитектуры не зависят, поэтому
собираются один раз под формат пакетов, а не под каждую плату.

## Версии

Единый источник — [`version.mk`](../version.mk):

```make
PKG_VERSION:=0.3.0
PKG_RELEASE:=1
XRAY_VERSION:=26.10.21
XRAY_TAG:=v26.10.21
XRAY_PKG_VERSION:=26.10.21-r1
```

Версия продублирована в `shoulderx/Makefile` и `luci-app-shoulderx/Makefile`
(OpenWrt собирает пакет из своей копии каталога, `include ../version.mk` там
ненадёжен). CI сверяет все три значения и, для тега, — с именем тега:

```
тег v0.3.0  ==  PKG_VERSION 0.3.0
```

Версия Xray дублируется в установщике (`XRAY_VERSION`, `XRAY_TAG`, хеши в
`xray_hash()`) — это тоже проверяет CI. Обновление пина — одной командой:

```sh
./scripts/bump-xray.sh 26.11.1
```

Скрипт проверяет, что тег существует, скачивает контрольные суммы всех
linux-архивов, обновляет `installer/xray-checksums.txt`, `version.mk` и
константы в установщике.

## Локальная сборка (OpenWrt SDK)

SDK под Windows не работает — нужен Linux (WSL или контейнер). Пример для
25.12.6 (apk); для 24.10.x (ipk) отличается только версия SDK:

```sh
wget https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/\
openwrt-sdk-25.12.6-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
mkdir -p sdk && tar --zstd -xf openwrt-sdk-25.12.6-*.tar.zst -C sdk --strip-components=1
cd sdk

./scripts/feeds update -a
./scripts/feeds install -a

ln -s /path/to/repo/shoulderx          package/shoulderx
ln -s /path/to/repo/luci-app-shoulderx package/luci-app-shoulderx

make defconfig
make package/shoulderx/compile V=s -j$(nproc)
make package/luci-app-shoulderx/compile V=s -j$(nproc)
```

Готовые файлы — в `bin/packages/<arch>/base/`:
`shoulderx_0.3.0-r1_all.ipk`, `luci-app-shoulderx_0.3.0-r1_all.ipk`
(или `*.apk` в сборке 25.12+).

## CI

[`.github/workflows/build.yml`](../.github/workflows/build.yml):

| job | что делает |
|---|---|
| `lint` | `sh -n` всех скриптов, `node --check` JS, JSON меню/ACL, `ucode -c`, сверка версий |
| `build` (matrix) | `apk` на SDK 25.12.6 и `ipk` на SDK 24.10.8 → 4 пакета в артефактах |
| `release` (тег `v*`) | проверяет пакеты, кладёт `SHA256SUMS` и установщик, зеркалит архивы Xray и публикует релиз |

## Что попадает в релиз

```
shoulderx-0.3.0-r1.apk                   luci-app-shoulderx-0.3.0-r1.apk
shoulderx_0.3.0-r1_all.ipk               luci-app-shoulderx_0.3.0-r1_all.ipk
shoulderx-install.sh                     SHA256SUMS
xray-26.10.21-{arm64-v8a,arm32-v7a,arm32-v6,mips32,mips32le,64,32}.zip
xray-checksums.txt                       LICENSE-xray.txt
```

Установщик лежит в ассетах, поэтому короткая ссылка постоянна:

```
https://github.com/BranchSeeker/shoulderX/releases/latest/download/shoulderx-install.sh
```

## Как выпустить релиз

```sh
# 1. поднять версию в version.mk и в двух Makefile
# 2. (по необходимости) обновить Xray
./scripts/bump-xray.sh 26.10.21
# 3. changelog
# 4. тег и пуш
git commit -am "0.3.0"
git tag v0.3.0
git push && git push --tags
```

CI соберёт пакеты, проверит совпадение версий, скачает архивы Xray, сверит их
sha256 с `installer/xray-checksums.txt` и опубликует релиз.

## Почему Xray не в зависимостях пакета

Раньше в `DEPENDS` стоял `+xray-core` — удобно, но установка из фида
перезаписывала бы закреплённую версию (а на части архитектур пакета может не
быть вовсе). Теперь Xray ставит установщик, а пакет работает с любым
`/etc/init.d/xray` или с нашим `/etc/init.d/shoulderx-xray`
(`option xray_init` — пусто означает «авто»).

## Лицензия Xray

Xray-core распространяется под MPL-2.0. Архивы в релизе — переименованные
официальные ассеты без изменений; в релиз кладётся
[`installer/LICENSE-xray.txt`](../installer/LICENSE-xray.txt) со ссылкой на
исходники и версию.
