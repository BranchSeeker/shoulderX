// xray.uc — разбор подписки и сборка конфига Xray.
//
// Подписка Remnawave для Happ — это массив готовых Xray-конфигов, по одному на
// группу серверов (LTE, WiFi ❯ Россия, WiFi ❯ USA, ...). Outbound'ы внутри уже
// в формате Xray, поэтому конвертировать ничего не нужно: берём их как есть,
// меняем только tag и собираем свой конфиг.
//
// Заглушка «Приложение не подходит» — два vless на 0.0.0.0:1 с нулевым uuid.
//
// Разделы (sections) — как секции podkop:
//   lte  — всё в туннель, списки РКН напрямую (один балансировщик "auto");
//   wifi — «домашний интернет»: домены из списков секций идут в их
//          балансировщики ("yt", "eu"), остальное — напрямую.

'use strict';

const PROTOCOLS = [ "vless", "vmess", "trojan", "shadowsocks" ];
const SKIP_TAGS = [ "direct", "block", "dns-out", "dns", "api-out" ];

// Запасной список YouTube на случай, когда geo-файлов на роутере ещё нет:
// основной путь — ext:geosite.dat:youtube, а это чтобы «домашний интернет»
// не превращался в «всё напрямую» до первого скачивания geo.
const YT_DOMAINS = [
	"domain:youtube.com", "domain:youtu.be", "domain:ytimg.com",
	"domain:youtube-nocookie.com", "domain:googlevideo.com",
	"domain:yt.be", "domain:youtubei.googleapis.com",
	"domain:youtubeembeddedplayer.googleapis.com",
	"domain:youtubekids.com", "domain:youtubegaming.com"
];

// Схемы на geo-файлах fast4g.ru:
//   lte  — default: proxy, whitelist: direct
//   wifi — default: direct, youtube: yt (proxy), russian-block: eu (proxy)
//
// PROXY_DOMAINS — запасной набор, если geo-файлов нет вовсе (wifi без geo).
const PROXY_DOMAINS = [
	"domain:chatgpt.com", "domain:openai.com", "domain:claude.ai", "domain:anthropic.com",
	"domain:instagram.com", "domain:facebook.com", "domain:fbcdn.net", "domain:meta.com",
	"domain:x.com", "domain:twitter.com", "domain:t.co", "domain:twimg.com",
	"domain:discord.com", "domain:discordapp.com", "domain:discord.gg",
	"domain:github.com", "domain:githubusercontent.com", "domain:githubassets.com",
	"domain:spotify.com", "domain:netflix.com", "domain:telegram.org", "domain:t.me"
];


// lc() опускает только латиницу; кириллицу приводим сами, попарно по UTF-8
// (ucode работает с байтами, поэтому идём по двухбайтовым буквам).
const CYR_UP = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ";
const CYR_LO = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя";

function lower(str) {
	let s = lc("" + str);
	let out = "", i = 0;
	while (i < length(s)) {
		let pair = substr(s, i, 2);
		let k = index(CYR_UP, pair);
		if (k >= 0 && (k % 2) == 0) {
			out += substr(CYR_LO, k, 2);
			i += 2;
		} else {
			out += substr(s, i, 1);
			i += 1;
		}
	}
	return out;
}
function has(hay, needle) {
	return index(lower(hay), lower(needle)) >= 0;
}
function is_proxy(o) {
	if (type(o) != "object" || o.protocol == null)
		return false;
	if (index(PROTOCOLS, "" + o.protocol) < 0)
		return false;
	let tag = (o.tag != null) ? "" + o.tag : "";
	if (index(SKIP_TAGS, tag) >= 0)
		return false;
	return true;
}
// Похоже ли это на рабочий outbound. Xray падает на всём конфиге, если у узла
// security=reality без realitySettings, поэтому такие узлы отбрасываем заранее.
// Ключ бывает в двух полях: publicKey (старый формат) или password (новый,
// так его отдаёт панель для Xray 25+); принимаем оба.
function outbound_ok(o) {
	let ss = o.streamSettings;
	if (type(ss) != "object")
		return true;
	if ("" + ss.security != "reality")
		return true;
	let rs = ss.realitySettings;
	if (type(rs) != "object")
		return false;

	let key = rs.publicKey;
	if (key == null || key == "")
		key = rs.password;
	if (key == null || key == "")
		return false;
	if (rs.serverName == null || rs.serverName == "")
		return false;
	return true;
}
// "адрес:порт#id" — ключ дедупликации и человекочитаемый endpoint.
function endpoint(o) {
	let s = o.settings;
	if (type(s) != "object")
		return "";

	let vn = s.vnext;
	if (type(vn) == "array" && length(vn) > 0) {
		let v = vn[0];
		let id = "";
		if (type(v.users) == "array" && length(v.users) > 0 && v.users[0].id != null)
			id = "" + v.users[0].id;
		return "" + v.address + ":" + v.port + "#" + id;
	}

	let sv = s.servers;
	if (type(sv) == "array" && length(sv) > 0) {
		let v = sv[0];
		let id = (v.password != null) ? "" + v.password : "";
		return "" + v.address + ":" + v.port + "#" + id;
	}

	return "";
}
function is_stub(ep) {
	return (substr("" + ep, 0, 10) == "0.0.0.0:1#");
}
// Провайдер вместо конфига может отдать заглушку: base64 от
// vless://00000000-0000-0000-0000-000000000000@0.0.0.0:1 или короткий текст.
// Это значит «устройство не зарегистрировано» (лимит hwid), а не «нет связи».
function is_stub_payload(text) {
	if (text == null)
		return true;
	let t = trim("" + text);
	if (length(t) < 64)
		return true;
	if (substr(lc(t), 0, 16) == "dmxlc3m6ly8wmdawn")
		return true;
	if (substr(t, 0, 20) == "dmxlc3M6Ly8wMDAwMDAw")
		return true;
	if (index(t, "vless://00000000-0000-0000-0000-000000000000") >= 0)
		return true;
	return false;
}
function configs(text) {
	let d;
	try {
		d = json(text);
	} catch (e) {
		return null;
	}
	if (d == null)
		return null;
	if (type(d) == "array")
		return d;
	if (type(d) == "object")
		return [ d ];
	return null;
}
// nodes_from_text(text) -> { nodes: [ { name, group, endpoint, outbound } ], error }
function nodes_from_text(text) {
	let list = configs(text);
	if (list == null)
		return { nodes: [], error: "не JSON-конфиг Xray (возможно, заглушка)" };

	let nodes = [], seen = {};

	for (let cfg in list) {
		if (type(cfg) != "object")
			continue;
		let group = (cfg.remarks != null) ? "" + cfg.remarks : "";
		let obs = cfg.outbounds;
		if (type(obs) != "array")
			continue;
		for (let o in obs) {
			if (!is_proxy(o))
				continue;
			if (!outbound_ok(o))
				continue;
			let ep = endpoint(o);
			if (ep == "" || is_stub(ep) || seen[ep] != null)
				continue;
			seen[ep] = true;
			// Имя сервера в подписке — это remarks группы; tag внутри группы
			// обычно безликий («proxy-1»), поэтому для плиток берём группу.
			let name = (group != "") ? group : ((o.tag != null) ? "" + o.tag : "");
			push(nodes, { name: name, group: group, endpoint: ep, outbound: o });
		}
	}

	return { nodes: nodes, error: "" };
}
// Совпадает ли узел с одним из фильтров (подстрока в имени группы, без учёта
// регистра). Фильтры задаются в LuCI: «LTE» для обхода БС, «WiFi» для дома,
// плюс исключения для секций yt и eu.
function matches(n, filters) {
	for (let f in filters) {
		f = trim("" + f);
		if (f == "")
			continue;
		if (has(n.group, f) || has(n.name, f))
			return true;
	}
	return false;
}
function default_lte_filter(opts) {
	return (opts != null && opts.lte_filter != null && length(opts.lte_filter) > 0)
		? opts.lte_filter : [ "LTE" ];
}
function default_wifi_filter(opts) {
	return (opts != null && opts.wifi_filter != null && length(opts.wifi_filter) > 0)
		? opts.wifi_filter : [ "WiFi" ];
}
function default_yt_exclude(opts) {
	return (opts != null && opts.yt_exclude != null) ? opts.yt_exclude : [];
}
function default_eu_exclude(opts) {
	return (opts != null && opts.eu_exclude != null && length(opts.eu_exclude) > 0)
		? opts.eu_exclude : [ "Россия", "Russia", "🇷🇺" ];
}
// mode: lte | wifi | all
function filter_mode(nodes, mode, opts) {
	let out = [];
	for (let n in nodes) {
		if (mode == "lte" && !matches(n, default_lte_filter(opts)))
			continue;
		if (mode == "wifi" && !matches(n, default_wifi_filter(opts)))
			continue;
		push(out, n);
	}
	return out;
}
// Группы узлов для конфига.
//   lte  -> [ { tag: "auto", nodes } ]  (только LTE-группа, иначе все)
//   wifi -> [ { tag: "yt", nodes }, { tag: "eu", nodes } ]  (пустые не добавляются)
function split_groups(nodes, mode, opts) {
	let groups = [];

	if (mode == "lte") {
		let lte_nodes = filter_mode(nodes, "lte", opts);
		if (length(lte_nodes) == 0)
			lte_nodes = nodes;
		if (length(lte_nodes) == 0)
			return groups;
		push(groups, { tag: "auto", nodes: lte_nodes });
		return groups;
	}

	let wifi_nodes = filter_mode(nodes, "wifi", opts);
	if (length(wifi_nodes) == 0)
		wifi_nodes = nodes;

	// WiFi-режим: обе секции — WiFi-узлы за вычетом своих исключений.
	//   yt: исключения из опции yt_exclude (по умолчанию пусто)
	//   eu: исключения из опции eu_exclude (по умолчанию Россия)
	let yx = default_yt_exclude(opts);
	let ex = default_eu_exclude(opts);
	let yt_nodes = [], eu_nodes = [];
	for (let n in wifi_nodes) {
		if (!matches(n, yx))
			push(yt_nodes, n);
		if (!matches(n, ex))
			push(eu_nodes, n);
	}
	if (length(yt_nodes) == 0)
		yt_nodes = wifi_nodes;
	if (length(eu_nodes) == 0)
		eu_nodes = wifi_nodes;

	if (length(yt_nodes) > 0)
		push(groups, { tag: "yt", nodes: yt_nodes });
	if (length(eu_nodes) > 0)
		push(groups, { tag: "eu", nodes: eu_nodes });
	return groups;
}
// Цель правила: балансировщик группы, если узлов больше одного, иначе outbound.
function target_for(g) {
	if (length(g.nodes) > 1)
		return { balancerTag: g.tag };
	return { outboundTag: g.tag + "-1" };
}
// build(opts) -> { config, nodes, sections, error }
//
// opts:
//   groups     — [ { tag, nodes, domains } ]; domains есть только у wifi-секций
//   mode       — "lte" | "wifi"
//   rkn        — { domains, ips } для lte-режима
//   socks_port, http_port, log_level
function build(opts) {
	let groups = opts.groups || [];
	if (length(groups) == 0)
		return { config: null, nodes: [], sections: [], error: "нет узлов для конфига" };

	let port = (opts.socks_port != null) ? opts.socks_port : 20180;
	let outs = [], balancers = [], selectors = [], meta = [], sections = [];

	for (let g in groups) {
		let tags = [];
		for (let i = 0; i < length(g.nodes); i++) {
			let n = g.nodes[i];
			let copy = json(sprintf("%J", n.outbound));
			copy.tag = g.tag + "-" + (i + 1);
			push(outs, copy);
			push(tags, copy.tag);
			push(meta, { tag: copy.tag, section: g.tag, name: n.name, endpoint: n.endpoint });
		}
		if (length(tags) > 1) {
			push(balancers, {
				tag: g.tag,
				selector: [ g.tag ],
				// если все узлы секции мертвы — пускаем напрямую: LAN без
				// интернета хуже, чем LAN без обхода
				fallbackTag: "direct",
				strategy: { type: "leastPing" }
			});
			push(selectors, g.tag);
		}
		push(sections, { tag: g.tag, nodes: length(tags), domains: length(g.domains || []) });
	}

	push(outs, { tag: "direct", protocol: "freedom", settings: {} });
	push(outs, { tag: "block", protocol: "blackhole", settings: {} });

	// Схемы маршрутизации на geo-файлах fast4g.ru:
	//   lte  («обход БС»):  напрямую только whitelist/private, всё остальное — в туннель
	//   wifi («домашний»):  по умолчанию напрямую; youtube -> секция yt,
	//                       russian-block (заблокированное в РФ) -> секция eu
	let rules = [];
	let geo = (opts.geo === true);
	let geo_site = (opts.geo_site != null) ? opts.geo_site : "geosite.dat";
	let geo_ip = (opts.geo_ip != null) ? opts.geo_ip : "geoip.dat";
	let site = function (tag) { return "ext:" + geo_site + ":" + tag; };
	let ipt = function (tag) { return "ext:" + geo_ip + ":" + tag; };
	let target_rule = function (tg) {
		let r = { type: "field" };
		if (tg.balancerTag != null)
			r.balancerTag = tg.balancerTag;
		else
			r.outboundTag = tg.outboundTag;
		return r;
	};

	let ytg = null, eug = null, autog = null;
	for (let g in groups) {
		if (g.tag == "yt")
			ytg = g;
		else if (g.tag == "eu")
			eug = g;
		else if (g.tag == "auto")
			autog = g;
	}

	// DNS-запросы из dns-in всегда через туннель: провайдер перехватывает 53-й
	// порт и на заблокированное отдаёт NXDOMAIN — с «прямым» DNS YouTube не
	// открывается вовсе.
	let dns_group = null;
	if (opts.mode == "lte")
		dns_group = autog;
	else
		dns_group = (eug != null) ? eug : autog;
	if (geo && dns_group != null) {
		let dr = target_rule(target_for(dns_group));
		dr.inboundTag = [ "dns-in" ];
		push(rules, dr);
	}

	// белые списки мобильного интернета + приватные диапазоны — всегда напрямую
	let push_direct = function () {
		let r1 = { type: "field", outboundTag: "direct" };
		let r2 = { type: "field", outboundTag: "direct" };
		if (geo) {
			r1.domain = [ site("WHITELIST"), site("PRIVATE") ];
			r2.ip = [ ipt("WHITELIST"), ipt("PRIVATE") ];
		} else {
			r1.domain = [ "geosite:whitelist", "geosite:private" ];
			r2.ip = [ "geoip:whitelist", "geoip:private" ];
		}
		push(rules, r1);
		push(rules, r2);
	};

	if (opts.mode == "lte") {
		// обход БС: напрямую только белый список, остальное — в туннель.
		// Заблокированное в РФ — явно в туннель ДО белого списка: домены
		// вроде chatgpt.com живут на Cloudflare, чьи адреса есть в geoip:WHITELIST,
		// и без этого правила уходили напрямую (403).
		if (geo && autog != null) {
			let pr = target_rule(target_for(autog));
			pr.domain = [ site("RUSSIAN-BLOCK"), site("YOUTUBE") ];
			push(rules, pr);
		}
		push_direct();
		if (autog != null) {
			let r = target_rule(target_for(autog));
			r.network = "tcp,udp";
			push(rules, r);
		} else {
			push(rules, { type: "field", network: "tcp,udp", outboundTag: "direct" });
		}
	} else {
		// домашний интернет: youtube -> yt, заблокированное в РФ -> eu, остальное напрямую
		if (ytg != null) {
			let r1 = target_rule(target_for(ytg));
			r1.domain = geo ? [ site("YOUTUBE") ] : YT_DOMAINS;
			push(rules, r1);
			if (geo) {
				let r2 = target_rule(target_for(ytg));
				r2.ip = [ ipt("YOUTUBE") ];
				push(rules, r2);
			}
		}
		push_direct();
		if (eug != null) {
			if (geo) {
				let r1 = target_rule(target_for(eug));
				r1.domain = [ site("RUSSIAN-BLOCK") ];
				push(rules, r1);
				let r2 = target_rule(target_for(eug));
				r2.ip = [ ipt("RUSSIAN-BLOCK") ];
				push(rules, r2);
			} else {
				let r1 = target_rule(target_for(eug));
				r1.domain = PROXY_DOMAINS;
				push(rules, r1);
			}
		}
		push(rules, { type: "field", network: "tcp,udp", outboundTag: "direct" });
	}

	let inbounds = [ {
		tag: "socks-in",
		listen: "127.0.0.1",
		port: port,
		protocol: "socks",
		settings: { auth: "noauth", udp: true }
	} ];

	if (opts.http_port != null && opts.http_port > 0) {
		push(inbounds, {
			tag: "http-in",
			listen: "127.0.0.1",
			port: opts.http_port,
			protocol: "http",
			settings: {}
		});
	}

	// tproxy-in: прозрачный приём LAN-трафика (nft tproxy). Sniffing нужен,
	// чтобы правила по домену работали: адрес назначения при tproxy — это
	// уже IP сервиса, а имя берём из TLS SNI / HTTP Host.
	let tproxy_port = (opts.tproxy_port != null) ? opts.tproxy_port : 0;
	if (tproxy_port > 0) {
		push(inbounds, {
			tag: "tproxy-in",
			listen: "0.0.0.0",
			port: tproxy_port,
			protocol: "dokodemo-door",
			settings: { network: "tcp,udp", followRedirect: true },
			streamSettings: { sockopt: { tproxy: "tproxy" } },
			sniffing: { enabled: true, destOverride: [ "http", "tls", "quic" ], routeOnly: false }
		});

		// DNS через туннель: у БС свой DNS, который отдаёт NXDOMAIN на
		// заблокированные домены (www.youtube.com) и уводит всё в IPv6.
		// dnsmasq спрашивает этот вход, а он уходит в туннель.
		let dns_port = (opts.dns_port != null) ? opts.dns_port : 5353;
		if (dns_port > 0) {
			push(inbounds, {
				tag: "dns-in",
				listen: "127.0.0.1",
				port: dns_port,
				protocol: "dokodemo-door",
				settings: { address: "1.1.1.1", port: 53, network: "udp,tcp" }
			});
		}
	}

	// API нужен, чтобы LuCI показывал плитки серверов: `xray api bi` отдаёт,
	// какой outbound выбрал каждый балансировщик, `statsquery` — трафик.
	let api_port = (opts.api_port != null) ? opts.api_port : 0;
	let api_rule = null;
	if (api_port > 0) {
		push(inbounds, {
			tag: "api-in",
			listen: "127.0.0.1",
			port: api_port,
			protocol: "dokodemo-door",
			settings: { address: "127.0.0.1" }
		});
		// правило API обязано стоять первым, иначе оно перехватит чужой трафик
		let with_api = [ { type: "field", inboundTag: [ "api-in" ], outboundTag: "api" } ];
		for (let r in rules)
			push(with_api, r);
		rules = with_api;
	}

	let cfg = {
		log: { loglevel: (opts.log_level != null) ? opts.log_level : "warning" },
		inbounds: inbounds,
		outbounds: outs,
		// IPIfNonMatch: если домен не поймали правилом — Xray резолвит его и
		// проверяет IP-правила (белые списки РФ по geoip)
		routing: { domainStrategy: "IPIfNonMatch", rules: rules, balancers: balancers }
	};

	if (api_port > 0)
		cfg.api = { tag: "api", services: [ "HandlerService", "RoutingService", "StatsService" ] };

	if (length(selectors) > 0) {
		cfg.observatory = {
			subjectSelector: selectors,
			// IP вместо домена: observatory не должен зависеть от DNS роутера,
			// который сам ходит через туннель (иначе deadlock на старте)
			probeUrl: "https://8.8.8.8/",
			probeInterval: "1m",
			enableConcurrency: true
		};
	}

	return { config: cfg, nodes: meta, sections: sections, error: "" };
}

return {
	nodes_from_text: nodes_from_text,
	configs_from: configs,
	filter_mode: filter_mode,
	split_groups: split_groups,
	build: build,
	endpoint: endpoint,
	is_stub: is_stub,
	is_stub_payload: is_stub_payload,
	matches: matches
};
