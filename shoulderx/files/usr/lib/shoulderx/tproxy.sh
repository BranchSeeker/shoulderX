#!/bin/sh
# tproxy.sh — прозрачный прокси для LAN через локальный Xray.
#
# Трафик из br-lan заворачивается в tproxy-in Xray (127.0.0.1:PORT), дальше
# маршрутизацией Xray решает, куда его деть (в туннель или напрямую по спискам).
#
#   tproxy.sh start [--safe N]   включить (--safe — авто-откат через N секунд)
#   tproxy.sh confirm            отменить авто-откат (значит всё работает)
#   tproxy.sh stop               выключить и убрать правила
#   tproxy.sh status             статус

PORT="${SHOULDERX_TPROXY_PORT:-12345}"
DNSPORT="${SHOULDERX_DNS_PORT:-5353}"
TABLE="shoulderx"
FWMARK="1"
ROUTE_TABLE="100"
SAFE_FILE="/tmp/.shoulderx.tproxy.safe"
FLOW_FILE="/tmp/.shoulderx.flow_offload"
DNS_FILE="/tmp/.shoulderx.dnsmasq"
V6_FILE="/tmp/.shoulderx.ipv6"

nft_bin() { command -v nft >/dev/null 2>&1 && echo nft || echo ""; }

# DNS у БС отдаёт NXDOMAIN на заблокированные домены и подсовывает IPv6.
# На время работы переключаем dnsmasq на вход Xray (через туннель).
save_dns() {
	# уже переключено — второй раз не трогаем
	case "$(uci -q get dhcp.@dnsmasq[0].server)" in
		*127.0.0.1#5353*) [ -f "$DNS_FILE" ] && return ;;
	esac

	# переключаем только если xray реально отвечает на DNS-порту, иначе
	# LAN останется без резолвера совсем. После рестарта xray это не сразу —
	# даём до 10 секунд.
	dns_ok=0
	try=0
	while [ "$try" -lt 10 ]; do
		if nslookup -port="$DNSPORT" www.gstatic.com 127.0.0.1 >/dev/null 2>&1; then
			dns_ok=1
			break
		fi
		try=$((try + 1))
		sleep 1
	done
	if [ "$dns_ok" != "1" ]; then
		echo "xray не отвечает на 127.0.0.1:$DNSPORT — dnsmasq не переключаю"
		return 1
	fi

	nr=$(uci -q get dhcp.@dnsmasq[0].noresolv)
	srv=$(uci -q get dhcp.@dnsmasq[0].server)
	fa=$(uci -q get dhcp.@dnsmasq[0].filter_aaaa)
	printf '%s|%s|%s\n' "${nr:-0}" "${srv:-}" "${fa:-0}" > "$DNS_FILE"

	uci set dhcp.@dnsmasq[0].noresolv='1'
	uci -q delete dhcp.@dnsmasq[0].server
	uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
	# LAN без IPv6: AAAA-ответы только мешают (клиент идёт в мёртвый IPv6)
	uci set dhcp.@dnsmasq[0].filter_aaaa='1'
	uci commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
}

restore_dns() {
	if [ ! -f "$DNS_FILE" ]; then
		# состояние потерялось (например, после перезагрузки): если dnsmasq
		# всё ещё смотрит в xray, возвращаем штатный режим
		case "$(uci -q get dhcp.@dnsmasq[0].server)" in
			*127.0.0.1#5353*)
				uci -q delete dhcp.@dnsmasq[0].server
				uci set dhcp.@dnsmasq[0].noresolv='0'
				uci commit dhcp
				/etc/init.d/dnsmasq restart >/dev/null 2>&1
				;;
		esac
		return
	fi

	line=$(cat "$DNS_FILE" 2>/dev/null)
	nr=${line%%|*}
	rest=${line#*|}
	srv=${rest%%|*}
	fa=${rest#*|}

	uci -q delete dhcp.@dnsmasq[0].server
	for one in $srv; do
		uci add_list dhcp.@dnsmasq[0].server="$one"
	done
	uci set dhcp.@dnsmasq[0].noresolv="${nr:-0}"
	if [ "${fa:-0}" = "1" ]; then
		uci set dhcp.@dnsmasq[0].filter_aaaa='1'
	else
		uci -q delete dhcp.@dnsmasq[0].filter_aaaa
	fi
	uci commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	rm -f "$DNS_FILE"
}

# IPv6 в LAN обходит tproxy (он только для IPv4) и уводит трафик мимо
# туннеля. На время работы выключаем RA/DHCPv6, при остановке возвращаем.
save_ipv6() {
	[ -f "$V6_FILE" ] && return

	ra=$(uci -q get dhcp.lan.ra)
	dh6=$(uci -q get dhcp.lan.dhcpv6)
	printf '%s|%s\n' "${ra:-server}" "${dh6:-server}" > "$V6_FILE"

	uci set dhcp.lan.ra='disabled'
	uci set dhcp.lan.dhcpv6='disabled'
	uci commit dhcp
	/etc/init.d/odhcpd restart >/dev/null 2>&1
}

restore_ipv6() {
	[ -f "$V6_FILE" ] || return

	line=$(cat "$V6_FILE" 2>/dev/null)
	ra=${line%%|*}
	dh6=${line#*|}

	uci set dhcp.lan.ra="${ra:-server}"
	uci set dhcp.lan.dhcpv6="${dh6:-server}"
	uci commit dhcp
	/etc/init.d/odhcpd restart >/dev/null 2>&1
	rm -f "$V6_FILE"
}

# Адреса узлов из конфига: соединения клиентов к этим адресам заворачивать
# нельзя — иначе VPN-клиент на телефоне/ПК (Happ) попадёт внутрь нашего
# туннеля, и получится двойной прокси, который обычно просто не работает.
node_ips() {
	[ -f /etc/xray/config.json ] || return 0

	addrs=$(ucode -e '
		let fs = require("fs");
		let c = json(fs.readfile("/etc/xray/config.json")) || {};
		for (let o in (c.outbounds || [])) {
			let s = o.settings || {};
			let v = (s.vnext || s.servers || [])[0];
			if (v != null && v.address != null)
				print("" + v.address + "\n");
		}
	' 2>/dev/null | sort -u)

	for a in $addrs; do
		case "$a" in
			*[a-zA-Z]*)
				nslookup "$a" 2>/dev/null | sed -n '/^Name:/,$p' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 4
				;;
			*)
				echo "$a"
				;;
		esac
	done | sort -u
}

# Flow offload в OpenWrt уводит установленные потоки мимо netfilter — tproxy
# такие пакеты просто не видит. Запоминаем настройки и выключаем на время.
save_flow_offload() {
	[ -f "$FLOW_FILE" ] && return

	sw=$(uci -q get firewall.@defaults[0].flow_offloading)
	hw=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
	sw=${sw:-0}
	hw=${hw:-0}

	case "$sw$hw" in
		*1*) ;;
		*) return ;;
	esac

	printf '%s %s\n' "$sw" "$hw" > "$FLOW_FILE"

	uci set firewall.@defaults[0].flow_offloading='0'
	uci set firewall.@defaults[0].flow_offloading_hw='0'
	uci commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
}

restore_flow_offload() {
	[ -f "$FLOW_FILE" ] || return

	read -r sw hw < "$FLOW_FILE" 2>/dev/null
	[ -n "$sw" ] || sw=1
	[ -n "$hw" ] || hw=1

	uci set firewall.@defaults[0].flow_offloading="$sw"
	uci set firewall.@defaults[0].flow_offloading_hw="$hw"
	uci commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1

	rm -f "$FLOW_FILE"
}

cleanup() {
	# сначала убираем policy routing, потом таблицу
	while ip rule del fwmark "$FWMARK" lookup "$ROUTE_TABLE" 2>/dev/null; do :; done
	ip route del local 0.0.0.0/0 dev lo table "$ROUTE_TABLE" 2>/dev/null
	if [ -n "$(nft_bin)" ]; then
		nft delete table inet "$TABLE" 2>/dev/null
	fi
	restore_flow_offload
	restore_dns
	restore_ipv6
	rm -f "$SAFE_FILE"
}

start() {
	safe="$1"

	if [ -z "$(nft_bin)" ]; then
		echo "nft не найден" >&2
		return 1
	fi

	# без работающего xray правила = чёрная дыра для LAN
	if ! pidof xray >/dev/null 2>&1; then
		echo "xray не запущен — сначала включите сервис (shoulderx service start)" >&2
		return 1
	fi

	cleanup

	# без этого установленные соединения идут мимо netfilter и tproxy их не видит
	save_flow_offload

	# dnsmasq переключаем только если xray реально отвечает на DNS-порт:
	# иначе роутер останется без DNS вообще
	if nslookup -port="$DNSPORT" www.gstatic.com 127.0.0.1 >/dev/null 2>&1; then
		save_dns
	else
		echo "xray не отвечает на 127.0.0.1:$DNSPORT — dnsmasq не переключаю" >&2
	fi
	save_ipv6

	# policy routing: помеченные пакеты должны обрабатываться локально
	ip rule add fwmark "$FWMARK" lookup "$ROUTE_TABLE" 2>/dev/null
	ip route add local 0.0.0.0/0 dev lo table "$ROUTE_TABLE" 2>/dev/null

	nft -f - <<EOF
table inet $TABLE {
	set nodes {
		type ipv4_addr
		flags interval
	}
	# отдельная nat-цепочка: redirect живёт только в nat-хуках
	chain dnsnat {
		type nat hook prerouting priority dstnat; policy accept;
		iifname != "br-lan" return
		ip daddr { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } return
		udp dport 53 redirect to :53
		tcp dport 53 redirect to :53
	}
	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;
		iifname != "br-lan" return
		ip daddr { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255 } return
		ip daddr @nodes return
		# QUIC не проксируем, но и не «вешаем»: reject заставляет браузер
		# мгновенно перейти на TCP (с drop вкладка висит как «нет интернета»)
		udp dport 443 reject
		meta l4proto tcp tproxy to :$PORT meta mark set $FWMARK accept
		meta l4proto udp tproxy to :$PORT meta mark set $FWMARK accept
	}
}
EOF
	rc=$?
	if [ "$rc" != "0" ]; then
		echo "не удалось создать правила nft" >&2
		cleanup
		return 1
	fi

	# узлы туннеля — мимо tproxy (иначе VPN-клиенты заворачиваются дважды)
	ips=$(node_ips | tr '\n' ',' | sed 's/,$//')
	if [ -n "$ips" ]; then
		nft add element inet "$TABLE" nodes "{ $ips }" 2>/dev/null
	fi

	if [ -n "$safe" ] && [ "$safe" != "0" ]; then
		# откат делает сторож из cron (watch): фоновый sleep умирает вместе
		# с ssh-сессией, а cron переживает всё
		echo "$(( $(date +%s) + safe ))" > "$SAFE_FILE"
		echo "включено, авто-откат через ${safe}с (подтвердить: shoulderx tproxy confirm)"
	else
		echo "включено: LAN -> xray 127.0.0.1:$PORT"
	fi
	return 0
}

confirm() {
	if [ -f "$SAFE_FILE" ]; then
		rm -f "$SAFE_FILE"
		echo "авто-откат отменён"
	else
		echo "нечего подтверждать"
	fi
}

status() {
	if [ -n "$(nft_bin)" ] && nft list table inet "$TABLE" >/dev/null 2>&1; then
		echo "включен: LAN -> 127.0.0.1:$PORT"
		nft list table inet "$TABLE" | sed -n '1,12p'
		return 0
	fi
	echo "выключен"
	return 1
}

# Сторож (cron раз в минуту): если xray не работает, правила снимаем —
# иначе LAN остаётся без интернета совсем. Тут же срабатывает авто-откат
# после `start --safe=N`.
watch() {
	if [ -z "$(nft_bin)" ] || ! nft list table inet "$TABLE" >/dev/null 2>&1; then
		rm -f "$SAFE_FILE"
		return 0
	fi

	if [ -f "$SAFE_FILE" ]; then
		deadline=$(cat "$SAFE_FILE" 2>/dev/null)
		now=$(date +%s)
		if [ -n "$deadline" ] && [ "$now" -ge "$deadline" ] 2>/dev/null; then
			cleanup
			logger -t shoulderx "авто-откат: прозрачный прокси выключен, LAN идёт напрямую"
			return 0
		fi
	fi

	if ! pidof xray >/dev/null 2>&1; then
		cleanup
		logger -t shoulderx "xray не работает — прозрачный прокси снят, LAN идёт напрямую"
		return 0
	fi

	# xray жив, но DNS может не отвечать — тогда LAN останется без резолва
	case "$(uci -q get dhcp.@dnsmasq[0].server)" in
		*127.0.0.1#$DNSPORT*)
			if ! nslookup -port="$DNSPORT" www.gstatic.com 127.0.0.1 >/dev/null 2>&1; then
				restore_dns
				logger -t shoulderx "DNS через xray не отвечает — вернул штатный резолвер"
			fi
			;;
	esac
	return 0
}

case "$1" in
	start)
		shift
		safe=""
		for a in "$@"; do
			case "$a" in
				--safe=*) safe="${a#--safe=}" ;;
				--safe) shift; safe="$1" ;;
			esac
		done
		start "$safe"
		;;
	stop) cleanup; echo "выключено" ;;
	confirm) confirm ;;
	status) status ;;
	watch) watch ;;
	*)
		echo "usage: tproxy.sh start [--safe=N] | stop | confirm | status | watch" >&2
		exit 2
		;;
esac
