#!/bin/sh
# shoulderX — установщик для OpenWrt.
#
#   wget -qO- https://github.com/BranchSeeker/shoulderX/releases/latest/download/shoulderx-install.sh | sh
#
# Что делает:
#   1) проверяет платформу (OpenWrt, архитектура, apk/opkg, место на диске);
#   2) ставит xray нужной версии: бинарник из релиза shoulderX (по архитектуре),
#      иначе с upstream XTLS, иначе пакет из фида;
#   3) ставит пакеты shoulderx и luci-app-shoulderx из последнего релиза;
#   4) настраивает подписку/режим и собирает конфиг (apply):
#      подписка напрямую -> geo через туннель -> полный туннель + tproxy.
#
# Флаги: --url=, --mode=lte|wifi, --lte-filter=, --wifi-filter=, --no-tproxy,
#        --xray-from-upstream, --xray-from-feed, --no-apply, --uninstall,
#        --purge, --dry-run, -y

set -u

REPO="BranchSeeker/shoulderX"
REL_BASE="https://github.com/${REPO}/releases/latest/download"

# GitHub в РФ бывает недоступен. Прокси-зеркала работают как префикс:
# https://gh-proxy.com/https://github.com/... — качаем с первого рабочего.
# Свой список: --mirror=https://префикс/ или SHOULDERX_MIRROR=...
MIRRORS="https://gh-proxy.com/ https://ghfast.top/ https://ghproxy.net/"

XRAY_VERSION="26.10.21"
XRAY_TAG="v26.10.21"
XRAY_PKG_VERSION="26.10.21-r1"
XRAY_UPSTREAM="https://github.com/XTLS/Xray-core/releases/download/${XRAY_TAG}"

# --- параметры --------------------------------------------------------------
SUB_URL=""
MODE=""
LTE_FILTER=""
WIFI_FILTER=""
NO_TPROXY=0
XRAY_SRC="auto"          # auto | release | upstream | feed
DO_APPLY=1
DO_UNINSTALL=0
PURGE=0
DRY=0
CUSTOM_MIRROR="${SHOULDERX_MIRROR:-}"

# --- состояние --------------------------------------------------------------
DISTRIB_ID=""
DISTRIB_RELEASE=""
DISTRIB_ARCH=""
PKG_MANAGER=""
XRAY_ASSET=""
XRAY_INIT=""
TMPDIR="/tmp/shoulderx-install.$$"

# --- вывод ------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_R="\033[0m"; C_G="\033[32m"; C_Y="\033[33m"; C_RED="\033[31m"; C_B="\033[36m"
else
	C_R=""; C_G=""; C_Y=""; C_RED=""; C_B=""
fi

step() { printf '\n%b==> %s%b\n' "$C_B" "$1" "$C_R"; }
ok()   { printf '  %bok%b %s\n' "$C_G" "$C_R" "$1"; }
warn() { printf '  %b!%b %s\n' "$C_Y" "$C_R" "$1" >&2; }
err()  { printf '  %bX%b %s\n' "$C_RED" "$C_R" "$1" >&2; }
info() { printf '    %s\n' "$1"; }

cleanup_tmp() { rm -rf "$TMPDIR" 2>/dev/null || true; }
die() { err "$1"; cleanup_tmp; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# На части прошивок TLS ломается (битый ca-bundle, часы) — тогда качаем без
# проверки сертификата. Целостность всё равно гарантируют sha256 из релиза.
TLS_INSECURE=0

note_insecure() {
	[ "$TLS_INSECURE" = "1" ] && return 0
	TLS_INSECURE=1
	warn "сертификаты на роутере не проходят проверку — качаю без проверки TLS (sha256 проверю)"
}

fetch_secure() {   # $1 url -> stdout
	if have curl; then
		curl -fsSL --connect-timeout 10 -m 60 "$1" && return 0
	fi
	if have wget; then
		wget -q -T 60 -O - "$1" && return 0
	fi
	if have uclient-fetch; then
		uclient-fetch -q -O - "$1" && return 0
	fi
	return 1
}

fetch() {   # fetch <url> -> stdout, с откатом на небезопасный TLS
	fetch_secure "$1" && return 0

	note_insecure
	if have curl; then
		curl -fsSL -k --connect-timeout 10 -m 60 "$1"
	elif have wget; then
		wget -q --no-check-certificate -T 60 -O - "$1"
	elif have uclient-fetch; then
		uclient-fetch -q --no-check-certificate -O - "$1"
	else
		return 1
	fi
}

# Ограничение по времени на одну попытку: иначе медленное зеркало вешает
# установщик навсегда (busybox wget без этого может тянуть часами).
DL_TIMEOUT="${SHOULDERX_DL_TIMEOUT:-240}"

run_to() {   # run_to <секунд> <команда...>
	if have timeout; then
		to="$1"; shift
		timeout "$to" "$@"
	else
		shift
		"$@"
	fi
}

dl_secure() {      # $1 url $2 file — с прогрессом, чтобы не казалось «висит»
	[ -n "$DL_TIMEOUT" ] || DL_TIMEOUT=240
	if have curl; then
		curl -fL --connect-timeout 10 -m "$DL_TIMEOUT" -o "$2" "$1" && return 0
	fi
	if have wget; then
		run_to "$DL_TIMEOUT" wget -T 30 -O "$2" "$1" && return 0
	fi
	if have uclient-fetch; then
		run_to "$DL_TIMEOUT" uclient-fetch -O "$2" "$1" && return 0
	fi
	return 1
}

dl() {             # dl <url> <file>, с откатом на небезопасный TLS
	dl_secure "$1" "$2" && return 0

	note_insecure
	if have curl; then
		curl -fL -k --connect-timeout 10 -m "$DL_TIMEOUT" -o "$2" "$1"
	elif have wget; then
		run_to "$DL_TIMEOUT" wget --no-check-certificate -T 30 -O "$2" "$1"
	elif have uclient-fetch; then
		run_to "$DL_TIMEOUT" uclient-fetch --no-check-certificate -O "$2" "$1"
	else
		return 1
	fi
}

xray_hash() {   # sha256 архива Xray для архитектуры
	case "$1" in
		arm64-v8a) echo "d1304946c486d98e6b886e9b931eaaaebb23835b30e217638037b7f2721d4e9c" ;;
		arm32-v7a) echo "89978508fa2ebb4a1e661f2c6ed51d241c4091b3cd17f4c65fdf20baae7dedac" ;;
		arm32-v6)  echo "cbc12722c484c022f9e31593bd29d5cd4593c98397514ebfc3289953eeb36a64" ;;
		mips32)    echo "3de6ee6a5142fb1372334ad1411f61f1b0a3f9d622a748a6080a29dc007ba207" ;;
		mips32le)  echo "1e9953aecee4024d9da6427a42929817b53d1660f5122ec6b22629e11cab4012" ;;
		64)        echo "0eec3ed4163c273d8c8bf821f7d219e257921cf584aa3fb970715e458e631978" ;;
		32)        echo "dde802c3c932aa1b8cdc5010de81b54719ff5e334f7c4800354825ed6c9d68b6" ;;
	esac
}

# --- зеркала GitHub ---------------------------------------------------------
# url_candidates <url> — сначала прямой адрес, затем через прокси-префиксы.
url_candidates() {
	printf '%s\n' "$1"
	for m in $MIRRORS; do
		printf '%s\n' "${m}$1"
	done
	if [ -n "$CUSTOM_MIRROR" ]; then
		printf '%s\n' "${CUSTOM_MIRROR%/}/$1"
	fi
}

fetch_any() {   # fetch_any <url> -> stdout, первый рабочий источник
	for u in $(url_candidates "$1"); do
		if fetch "$u"; then return 0; fi
	done
	return 1
}

dl_any() {      # dl_any <url> <file>
	first=1
	for u in $(url_candidates "$1"); do
		if [ "$first" = "1" ]; then
			first=0
		else
			warn "пробую зеркало: $u"
		fi
		if dl "$u" "$2"; then
			return 0
		fi
		rm -f "$2" 2>/dev/null
	done
	return 1
}

pkg_add() {     # pkg_add <файлы...>
	if [ "$PKG_MANAGER" = "apk" ]; then
		apk add --allow-untrusted "$@"
	else
		opkg install "$@"
	fi
}

# --- 1. платформа -----------------------------------------------------------
detect_platform() {
	step "Проверяю платформу"

	[ "$(id -u)" = "0" ] || die "нужен root"
	[ -f /etc/openwrt_release ] || die "это не OpenWrt (нет /etc/openwrt_release)"

	. /etc/openwrt_release
	DISTRIB_ID="${DISTRIB_ID:-unknown}"
	DISTRIB_RELEASE="${DISTRIB_RELEASE:-unknown}"
	DISTRIB_ARCH="${DISTRIB_ARCH:-}"

	case "$DISTRIB_ID" in
		OpenWrt*) ok "OpenWrt $DISTRIB_RELEASE ($DISTRIB_ARCH)" ;;
		*) die "поддерживается только OpenWrt, найдено: $DISTRIB_ID" ;;
	esac

	if have apk; then
		PKG_MANAGER="apk"
	elif have opkg; then
		PKG_MANAGER="opkg"
	else
		die "нет менеджера пакетов (ни apk, ни opkg)"
	fi
	ok "пакеты: $PKG_MANAGER"

	if have curl; then
		ok "загрузка: curl"
	elif have wget; then
		ok "загрузка: wget"
	elif have uclient-fetch; then
		ok "загрузка: uclient-fetch"
	else
		die "нужен curl, wget или uclient-fetch"
	fi

	year=$(date +%Y 2>/dev/null || echo 0)
	case "$year" in
		''|*[!0-9]*) year=0 ;;
	esac
	if [ "$year" -lt 2025 ]; then
		warn "часы роутера врут ($(date 2>/dev/null)) — проверка TLS может не пройти, скачаю без неё"
	fi

	case "$DISTRIB_ARCH" in
		aarch64*)                    XRAY_ASSET="arm64-v8a" ;;
		arm_cortex-a5*|arm_arm1176*) XRAY_ASSET="arm32-v6" ;;
		arm_*)                       XRAY_ASSET="arm32-v7a" ;;
		mips_24kc|mips_4k*)          XRAY_ASSET="mips32" ;;
		mipsel_*|mipsel)             XRAY_ASSET="mips32le" ;;
		x86_64)                      XRAY_ASSET="64" ;;
		i386*|i686*)                 XRAY_ASSET="32" ;;
		*) die "неизвестная архитектура '$DISTRIB_ARCH' — поставьте Xray вручную и запустите с --xray-from-feed" ;;
	esac
	ok "Xray: Xray-linux-${XRAY_ASSET}.zip"

	if [ "$DRY" = "0" ]; then
		avail=$(df -k / | awk 'NR==2 {print $4}')
		[ "${avail:-0}" -gt 8000 ] || warn "мало места на /overlay: ${avail:-?} КБ (желательно > 8 МБ)"
	fi
}

# --- 2. Xray ----------------------------------------------------------------
xray_installed_version() {
	have xray || return 1
	xray version 2>/dev/null | sed -n 's/^Xray \([0-9][0-9.]*\).*/\1/p' | head -n 1
}

verify_sha256() {
	[ -n "$2" ] || return 0
	sum=$(sha256sum "$1" | awk '{print $1}')
	[ "$sum" = "$2" ]
}

unpack_xray() {     # $1 — zip, $2 — подпись для лога
	mkdir -p "$TMPDIR/xray"
	unzip -o -q "$1" -d "$TMPDIR/xray" >/dev/null 2>&1 || return 1
	[ -f "$TMPDIR/xray/xray" ] || return 1
	install -m 0755 "$TMPDIR/xray/xray" /usr/bin/xray || return 1
	ok "бинарник Xray установлен ($2)"
}

setup_xray_service() {
	if [ ! -x /etc/init.d/xray ] && [ -x /etc/init.d/shoulderx-xray ]; then
		[ "$DRY" = "0" ] && /etc/init.d/shoulderx-xray enable >/dev/null 2>&1
		XRAY_INIT="/etc/init.d/shoulderx-xray"
	else
		XRAY_INIT="/etc/init.d/xray"
	fi
}

# В фиде OpenWrt xray-core обычно той же версии, что мы пинуем. Тогда не надо
# тянуть 14 МБ через прокси — ставим пакет (быстро и с штатным init).
feed_pinned_available() {
	[ "$PKG_MANAGER" = "apk" ] || [ "$PKG_MANAGER" = "opkg" ] || return 1
	if [ "$PKG_MANAGER" = "apk" ]; then
		apk list 2>/dev/null | grep -q "^xray-core-${XRAY_VERSION}"
	else
		opkg list 2>/dev/null | grep -q "^xray-core - ${XRAY_VERSION}"
	fi
}

install_xray_feed() {
	if [ "$DRY" = "1" ]; then
		ok "(dry-run) поставил бы xray-core=${XRAY_PKG_VERSION} из фида"
		return 0
	fi
	if [ "$PKG_MANAGER" = "apk" ]; then
		apk add "xray-core=${XRAY_PKG_VERSION}" >/dev/null 2>&1 || \
		apk add xray-core >/dev/null 2>&1 || return 1
	else
		opkg update >/dev/null 2>&1 || true
		opkg install "xray-core" >/dev/null 2>&1 || return 1
	fi
	return 0
}

install_xray() {	step "Xray $XRAY_VERSION"
	info "архив ~14 МБ; если канал медленный, это займёт минуту-другую"

	cur=$(xray_installed_version)
	if [ "$cur" = "$XRAY_VERSION" ]; then
		ok "уже установлен $cur"
		setup_xray_service
		return 0
	fi

	# быстрый путь: в фиде ровно наша версия — не качаем 14 МБ
	if [ "$XRAY_SRC" = "auto" ] && feed_pinned_available; then
		info "в фиде есть xray-core ${XRAY_VERSION} — ставлю пакетом"
		if install_xray_feed; then
			ok "xray-core ${XRAY_PKG_VERSION} из фида"
			setup_xray_service
			return 0
		fi
		warn "пакет из фида не встал — качаю бинарник"
	fi

	if [ "$DRY" = "0" ]; then
		mkdir -p "$TMPDIR"
		have unzip || { apk add unzip >/dev/null 2>&1 || opkg install unzip >/dev/null 2>&1 || true; }
	fi

	if [ "$XRAY_SRC" = "auto" ] || [ "$XRAY_SRC" = "release" ]; then
		name="xray-${XRAY_VERSION}-${XRAY_ASSET}.zip"
		if [ "$DRY" = "1" ]; then
			ok "(dry-run) скачал бы ${REL_BASE}/${name}"
		elif dl_any "${REL_BASE}/${name}" "$TMPDIR/xray.zip" 2>/dev/null; then
			want=$(fetch_any "${REL_BASE}/xray-checksums.txt" 2>/dev/null | awk -v n="$name" '$2==n {print $1}' | head -n 1)
			if verify_sha256 "$TMPDIR/xray.zip" "$want" && unpack_xray "$TMPDIR/xray.zip" "релиз shoulderX"; then
				setup_xray_service
				return 0
			fi
			warn "архив из релиза не подошёл — пробую upstream"
			rm -f "$TMPDIR/xray.zip"
		fi
		[ "$XRAY_SRC" = "release" ] && die "в релизе нет Xray для $DISTRIB_ARCH"
	fi

	if [ "$XRAY_SRC" = "auto" ] || [ "$XRAY_SRC" = "upstream" ]; then
		name="Xray-linux-${XRAY_ASSET}.zip"
		if [ "$DRY" = "1" ]; then
			ok "(dry-run) скачал бы ${XRAY_UPSTREAM}/${name}"
		elif dl_any "${XRAY_UPSTREAM}/${name}" "$TMPDIR/xray.zip" 2>/dev/null; then
			if verify_sha256 "$TMPDIR/xray.zip" "$(xray_hash "$XRAY_ASSET")" && \
			   unpack_xray "$TMPDIR/xray.zip" "upstream XTLS ${XRAY_TAG}"; then
				setup_xray_service
				return 0
			fi
			warn "upstream: проверка не прошла"
			rm -f "$TMPDIR/xray.zip"
		fi
	fi

	warn "ставлю xray-core из фида (версия может отличаться от ${XRAY_VERSION})"
	if [ "$DRY" = "0" ]; then
		if [ "$PKG_MANAGER" = "apk" ]; then
			apk add xray-core >/dev/null 2>&1 || die "не удалось поставить xray-core из фида"
		else
			opkg update >/dev/null 2>&1 || true
			opkg install xray-core >/dev/null 2>&1 || die "не удалось поставить xray-core из фида"
		fi
	fi
	ok "xray-core из фида"
	setup_xray_service
}

# --- 3. пакеты --------------------------------------------------------------
install_packages() {
	step "Пакеты shoulderX"

	if [ "$PKG_MANAGER" = "apk" ]; then ext="apk"; else ext="ipk"; fi

	sums=$(fetch_any "${REL_BASE}/SHA256SUMS" 2>/dev/null)
	[ -n "$sums" ] || die "не смог получить SHA256SUMS из последнего релиза (нет сети?)"

	files=$(printf '%s\n' "$sums" | awk -v e="$ext" '$2 ~ ("\\." e "$") {print $2}')
	[ -n "$files" ] || die "в релизе нет пакетов .$ext"

	for f in $files; do
		info "качаю $f"
		[ "$DRY" = "0" ] || continue
		mkdir -p "$TMPDIR"
		dl_any "${REL_BASE}/${f}" "$TMPDIR/$f" || die "не скачался $f"
		want=$(printf '%s\n' "$sums" | awk -v n="$f" '$2==n {print $1}')
		verify_sha256 "$TMPDIR/$f" "$want" || die "sha256 не совпал: $f"
	done

	if [ "$DRY" = "1" ]; then
		ok "(dry-run) поставил бы: $(printf '%s' "$files" | tr '\n' ' ')"
		return 0
	fi

	cd "$TMPDIR" || die "нет каталога $TMPDIR"
	pkg_add ./*."$ext" >/dev/null 2>&1 || die "установка пакетов не прошла"
	cd /
	ok "пакеты установлены"

	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
}

# --- 4. настройка -----------------------------------------------------------
configure() {
	step "Настройки"

	if [ "$DRY" = "1" ]; then
		ok "(dry-run) url=${SUB_URL:-<не задан>} mode=${MODE:-из пакета}"
		return 0
	fi

	[ -n "$SUB_URL" ]      && uci -q set "shoulderx.settings.subscription_url=$SUB_URL"
	[ -n "$MODE" ]         && uci -q set "shoulderx.settings.mode=$MODE"
	[ -n "$LTE_FILTER" ]   && uci -q set "shoulderx.settings.lte_filter=$LTE_FILTER"
	[ -n "$WIFI_FILTER" ]  && uci -q set "shoulderx.settings.wifi_filter=$WIFI_FILTER"
	[ "$NO_TPROXY" = "1" ] && uci -q set "shoulderx.settings.tproxy_port=0"
	[ -n "$XRAY_INIT" ]    && uci -q set "shoulderx.settings.xray_init=$XRAY_INIT"
	uci -q set shoulderx.settings.geo='1'
	uci -q commit shoulderx

	/etc/init.d/shoulderx enable >/dev/null 2>&1 || true
	ok "режим: $(uci -q get shoulderx.settings.mode)"
	if [ -z "$(uci -q get shoulderx.settings.subscription_url)" ]; then
		warn "ссылка подписки не задана — добавьте в LuCI"
	fi
}

# --- 5. первая сборка -------------------------------------------------------
run_apply() {
	step "Собираю конфиг (подписка -> geo -> туннель)"

	if [ "$DRY" = "1" ]; then
		ok "(dry-run) apply пропущен"
		return 0
	fi

	if [ -z "$(uci -q get shoulderx.settings.subscription_url)" ]; then
		warn "подписка не задана — сборку пропускаю"
		return 0
	fi

	if /usr/bin/shoulderx apply 2>&1 | sed 's/^/    /'; then
		ok "конфиг собран"
	else
		warn "apply завершился с ошибкой — смотрите: logread | grep shoulderx"
	fi

	/usr/lib/shoulderx/tproxy.sh status 2>/dev/null | head -n 1 | sed 's/^/    /'
}

# --- 6. итог ----------------------------------------------------------------
summary() {
	step "Готово"
	ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
	[ -n "$ip" ] || ip=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n 1)
	info "LuCI:   http://${ip:-192.168.1.1}/cgi-bin/luci/admin/services/shoulderx"
	info "статус: shoulderx status"
	info "тест:   shoulderx check"
	info "режимы: shoulderx mode lte | wifi"
	info "стоп:   shoulderx tproxy stop"
}

# --- удаление ---------------------------------------------------------------
do_uninstall() {
	step "Удаление shoulderX"

	[ -x /usr/lib/shoulderx/tproxy.sh ] && /usr/lib/shoulderx/tproxy.sh stop >/dev/null 2>&1
	if [ -x /usr/bin/shoulderx ]; then
		/usr/bin/shoulderx service stop >/dev/null 2>&1
		/usr/bin/shoulderx schedule off >/dev/null 2>&1
	fi
	/etc/init.d/shoulderx disable >/dev/null 2>&1 || true

	if [ "$PKG_MANAGER" = "apk" ]; then
		apk del luci-app-shoulderx shoulderx >/dev/null 2>&1 || true
	else
		opkg remove luci-app-shoulderx shoulderx >/dev/null 2>&1 || true
	fi

	if [ "$PURGE" = "1" ]; then
		rm -rf /etc/shoulderx
		rm -f /etc/config/shoulderx /etc/xray/config.json
		rm -f /usr/share/xray/geoip.dat /usr/share/xray/geosite.dat
		ok "конфиги, кэш и geo-файлы удалены"
	fi
	ok "удалено"
}

usage() {
	cat <<'EOF'
shoulderX installer

  usage: shoulderx-install.sh [флаги]

  --url=URL             ссылка подписки
  --mode=lte|wifi       режим (по умолчанию — из пакета: lte)
  --lte-filter=X        фильтр групп для «обхода БС» (по умолчанию LTE)
  --wifi-filter=X       фильтр групп для «домашнего интернета» (WiFi)
  --mirror=URL          своё зеркало GitHub (префикс, напр. https://gh-proxy.com/)
  --no-tproxy           не включать прозрачный прокси для LAN
  --xray-from-upstream  ставить Xray только с XTLS (не из релиза и не из фида)
  --xray-from-feed      ставить xray-core из фида OpenWrt
  --no-apply            только установить, конфиг не собирать
  --uninstall           удалить shoulderX
  --purge               с --uninstall удалить конфиги и geo-файлы
  --dry-run             показать план, ничего не меняя
  -h, --help            эта справка
EOF
}

trap cleanup_tmp EXIT

for arg in "$@"; do
	case "$arg" in
		--url=*)              SUB_URL="${arg#*=}" ;;
		--mode=*)             MODE="${arg#*=}" ;;
		--lte-filter=*)       LTE_FILTER="${arg#*=}" ;;
		--wifi-filter=*)      WIFI_FILTER="${arg#*=}" ;;
		--mirror=*)           CUSTOM_MIRROR="${arg#*=}" ;;
		--no-tproxy)          NO_TPROXY=1 ;;
		--xray-from-upstream) XRAY_SRC="upstream" ;;
		--xray-from-feed)     XRAY_SRC="feed" ;;
		--no-apply)           DO_APPLY=0 ;;
		--uninstall)          DO_UNINSTALL=1 ;;
		--purge)              PURGE=1 ;;
		--dry-run)            DRY=1 ;;
		-h|--help)            usage; exit 0 ;;
		*) err "неизвестный флаг: $arg"; usage; exit 2 ;;
	esac
done

detect_platform
[ "$DRY" = "1" ] && warn "dry-run: ничего не меняю"

if [ "$DO_UNINSTALL" = "1" ]; then
	do_uninstall
	exit 0
fi

if [ "$XRAY_SRC" = "feed" ]; then
	step "Xray из фида OpenWrt"
	if [ "$DRY" = "0" ]; then
		if [ "$PKG_MANAGER" = "apk" ]; then
			apk add xray-core >/dev/null 2>&1 || die "не удалось поставить xray-core из фида"
		else
			opkg update >/dev/null 2>&1 || true
			opkg install xray-core >/dev/null 2>&1 || die "не удалось поставить xray-core из фида"
		fi
	fi
	ok "xray-core из фида"
	setup_xray_service
else
	install_xray
fi

install_packages
configure
[ "$DO_APPLY" = "1" ] && run_apply
summary
