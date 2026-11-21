// shoulderx — энтипоинт CLI.
//
// Команды:
//   fetch     — скачать подписку в кэш (/etc/shoulderx/sub.json)
//   list      — показать узлы из кэша или файла
//   gen       — собрать конфиг Xray (--write чтобы записать)
//   apply     — fetch + gen --write + restart (то, что зовёт LuCI и cron)
//   status    — состояние: режим, секции, кэш, конфиг, xray
//   lists     — обновить списки доменов (allow-domains) в кэш
//   schedule  — переустановить cron-задачу обновления (off — снять)
//
// Режимы:
//   lte  — «обход БС»: узлы LTE-группы в один балансировщик, списки РКН напрямую;
//   wifi — «домашний интернет»: секции yt и eu, их домены идут в балансировщики,
//          всё остальное напрямую.

'use strict';

let fs = require("fs");
let uci = require("uci");
let fetchmod = require("fetch");
let linksmod = require("links");
let xraymod = require("xray");

const SUB_CACHE = "/etc/shoulderx/sub.json";
const STATE = "/etc/shoulderx/state.json";
const CRONTAB = "/etc/crontabs/root";

// Российские сервисы (russia_inside) в туннель не отправляем: они должны
// открываться напрямую, через ноду только тратят трафик и ломаются.
// geoblock — наоборот, туда входят ChatGPT/Claude (openai.com, chatgpt.com,
// claude.ai, anthropic.com): без туннеля они отдают 403.

// В режиме «Обход БС» эти списки идут в туннель В ПЕРВУЮ ОЧЕРЕДЬ — даже если
// сервис попал в список «доступно напрямую» (YouTube, Instagram, ChatGPT там
// есть, но из РФ они отдают заглушки).

// Российские сервисы, которым в туннеле делать нечего: они отлично работают
// напрямую. Списки itdoginfo про Яндекс/ВК забывают (inside-raw.lst их не
// содержит), поэтому держим базовый набор у себя — он дополняет список РКН.
const RU_DOMAINS = [
	"yandex.ru", "yandex.net", "yandex.com", "ya.ru", "yastatic.net", "dzen.ru",
	"vk.com", "vk.ru", "vkontakte.ru", "userapi.com", "vk-cdn.net", "ok.ru",
	"mail.ru", "my.com", "imgsmail.ru", "max.ru",
	"gosuslugi.ru", "nalog.gov.ru", "nalog.ru", "mos.ru", "rt.ru",
	"sber.ru", "sberbank.ru", "sberbank.com", "alfabank.ru", "tinkoff.ru", "tbank.ru",
	"vtb.ru", "gazprombank.ru", "psbank.ru", "raiffeisen.ru", "mkb.ru",
	"ozon.ru", "wildberries.ru", "wb.ru", "avito.ru", "dns-shop.ru", "mvideo.ru",
	"eldorado.ru", "citilink.ru", "leroymerlin.ru", "vseinstrumenti.ru",
	"kinopoisk.ru", "rutube.ru", "ivi.ru", "okko.tv", "more.tv", "wink.ru",
	"2gis.ru", "2gis.com", "avito.com", "hh.ru", "rabota.ru", "superjob.ru",
	"ria.ru", "lenta.ru", "rbc.ru", "vedomosti.ru", "kommersant.ru", "tass.ru",
	"mts.ru", "megafon.ru", "beeline.ru", "tele2.ru", "yota.ru",
	"rzd.ru", "aeroflot.ru", "s7.ru", "tutu.ru", "yandex.taxi",
	"gismeteo.ru", "mail.yandex.ru", "passport.yandex.ru", "taxi.yandex.ru"
];

// Сервисы для проверки: группа "proxy" — то, что должно идти в туннель,
// "ru" — то, что обычно должно открываться напрямую. Домены — обычные точки входа.
const SERVICES = [
	{ group: "proxy", name: "YouTube", domain: "www.youtube.com" },
	{ group: "proxy", name: "Telegram", domain: "web.telegram.org" },
	{ group: "proxy", name: "ChatGPT", domain: "chatgpt.com" },
	{ group: "proxy", name: "Instagram", domain: "www.instagram.com" },
	{ group: "proxy", name: "X (Twitter)", domain: "x.com" },
	{ group: "proxy", name: "Discord", domain: "discord.com" },
	{ group: "ru", name: "Яндекс", domain: "ya.ru" },
	{ group: "ru", name: "ВК", domain: "vk.com" },
	{ group: "ru", name: "Кинопоиск", domain: "www.kinopoisk.ru" },
	{ group: "ru", name: "RuTube", domain: "rutube.ru" },
	{ group: "ru", name: "Госуслуги", domain: "www.gosuslugi.ru" },
	{ group: "ru", name: "Ozon", domain: "ozon.ru" }
];

// geo-файлы RoscomVPN (профиль WHITELIST): whitelist-домены и адреса РФ идут
// напрямую, всё остальное — в туннель. Качаются ОТДЕЛЬНО от подписки и только
// через туннель: напрямую jsDelivr из РФ часто недоступен.
const GEOIP_URL = "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip/release/geoip.dat";
const GEOSITE_URL = "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/geosite.dat";
const GEO_TTL = 604800;

const CHECK_TIMEOUT = 7;
const JOB_FILE = "/tmp/shoulderx-job.json";

function out(s) {
	print("" + s + "\n");
}
function ensure_dir(path) {
	system("mkdir -p '" + path + "' >/dev/null 2>&1");
}
function as_list(v, def) {
	if (v == null)
		return def;
	if (type(v) == "array") {
		let res = [];
		for (let x in v) {
			x = trim("" + x);
			if (x != "")
				push(res, x);
		}
		return (length(res) > 0) ? res : def;
	}
	let s = trim("" + v);
	if (s == "")
		return def;
	let res = [];
	for (let x in split(s, " "))
		for (let y in split(x, ","))
			if (trim(y) != "")
				push(res, trim(y));
	return (length(res) > 0) ? res : def;
}
// LuCI пишет изменения в /tmp/.uci (delta) и коммитит их только по кнопке
// «Сохранить». Наша кнопка сохраняет форму, но коммит из браузера может не
// пройти, поэтому фиксируем изменения сами: apply всегда работает с тем, что
// реально стоит в /etc/config/shoulderx.
function uci_commit_pending() {
	let c = uci.cursor();
	c.load("shoulderx");
	c.commit("shoulderx");
}
// "a,b,,c" -> [ "a", "b", "c" ]
function csv(str) {
	let out = [];
	for (let x in split("" + str, ",")) {
		x = trim(x);
		if (x != "")
			push(out, x);
	}
	return out;
}
function xray_ensure_enabled() {
	let cur = trim(fetchmod.cmd_out("uci -q get xray.enabled.enabled"));
	if (cur == "1")
		return;
	if (trim(fetchmod.cmd_out("uci -q show xray.enabled")) != "") {
		system("uci set xray.enabled.enabled='1' >/dev/null 2>&1");
		system("uci commit xray >/dev/null 2>&1");
	}
}
function xray_wait(want) {
	for (let i = 0; i < 5; i++) {
		let running = (trim(fetchmod.cmd_out("pidof xray")) != "");
		if (running == want)
			return true;
		system("sleep 1");
	}
	return false;
}
function bi_tag(text, section) {
	let in_sel = false;
	for (let l in split(text, "\n")) {
		l = trim("" + l);
		if (index(l, "Selects:") >= 0) {
			in_sel = true;
			continue;
		}
		if (!in_sel || l == "")
			continue;
		for (let tok in split(l, " ")) {
			tok = trim(tok);
			if (tok == "" || int(tok) != 0 && "" + int(tok) == tok)
				continue;
			if (section != "") {
				if (substr(tok, 0, length(section) + 1) == section + "-")
					return tok;
				continue;
			}
			let dash = index(tok, "-");
			if (dash > 0)
				return tok;
		}
	}
	return "";
}
function balancer_ready(api_port, tag) {
	if (api_port <= 0 || tag == "")
		return false;

	let text = fetchmod.cmd_out("/usr/bin/xray api bi -s 127.0.0.1:" + api_port + " " + tag + " 2>&1");
	return (bi_tag(text, tag) != "");
}
function wait_ready(s, tags) {
	if (trim(fetchmod.cmd_out("pidof xray")) == "")
		return false;
	if (length(tags) == 0)
		return true;

	for (let i = 0; i < 30; i++) {
		for (let tg in tags) {
			if (balancer_ready(s.api_port, tg))
				return true;
		}
		system("sleep 1");
	}
	return false;
}
function balancer_selected(api_port, section) {
	let text = fetchmod.cmd_out("/usr/bin/xray api bi -s 127.0.0.1:" + api_port + " " + section + " 2>&1");
	return bi_tag(text, section);
}
// Чем управлять Xray: явная настройка, иначе пакет из фида, иначе наш инстанс
// (установщик кладёт бинарник и /etc/init.d/shoulderx-xray).
function init_path(want) {
	if (want != "")
		return want;
	if (fs.stat("/etc/init.d/xray") != null)
		return "/etc/init.d/xray";
	return "/etc/init.d/shoulderx-xray";
}

function settings() {
	let c = uci.cursor();
	c.load("shoulderx");

	function g(opt, def) {
		let v = c.get("shoulderx", "settings", opt);
		if (v == null || v == "")
			return def;
		return "" + v;
	}

	// subscription_url может быть списком: берём первую непустую ссылку.
	let urls = as_list(c.get("shoulderx", "settings", "subscription_url"), []);

	return {
		url: (length(urls) > 0) ? urls[0] : "",
		urls: urls,
		mode: g("mode", "lte"),
		socks_port: int(g("socks_port", "20180")),
		http_port: int(g("http_port", "0")),
		api_port: int(g("api_port", "20190")),
		tproxy_port: int(g("tproxy_port", "0")),
		dns_port: int(g("dns_port", "5353")),
		lte_filter: as_list(c.get("shoulderx", "settings", "lte_filter"), [ "LTE" ]),
		wifi_filter: as_list(c.get("shoulderx", "settings", "wifi_filter"), [ "WiFi" ]),
		out: g("config_path", "/etc/xray/config.json"),
		init: init_path(g("xray_init", "")),
		ua: g("user_agent", "Happ/2.7.0"),
		hwid: g("hwid", ""),
		restart: g("restart_cmd", "/etc/init.d/xray restart"),
		schedule: (g("enable_schedule", "0") == "1"),
		interval: g("update_interval", "6h"),
		// маршрутизация по geo-файлам RoscomVPN (whitelist -> direct)
		geo: (g("geo", "0") == "1"),
		geo_dir: g("geo_dir", "/usr/share/xray"),
		geoip_url: g("geoip_url", GEOIP_URL),
		geosite_url: g("geosite_url", GEOSITE_URL),
		geo_ttl: int(g("geo_ttl", "0"))
	};
}
function parse_args(argv) {
	let a = {};
	for (let i = 1; i < length(argv); i++) {
		let v = argv[i];
		if (v == "--write")
			a.write = true;
		else if (v == "--restart")
			a.restart = true;
		else if (v == "--no-restart")
			a.no_restart = true;
		else if (v == "--json")
			a.json = true;
		else if (v == "--quiet")
			a.quiet = true;
		else if (v == "--refresh-lists")
			a.refresh_lists = true;
		else if (substr(v, 0, 6) == "--url=")
			a.url = substr(v, 6);
		else if (substr(v, 0, 7) == "--mode=")
			a.mode = substr(v, 7);
		else if (substr(v, 0, 8) == "--group=")
			a.group = substr(v, 8);
		else if (substr(v, 0, 7) == "--file=")
			a.file = substr(v, 7);
		else if (substr(v, 0, 6) == "--out=")
			a.out = substr(v, 6);
		else if (substr(v, 0, 13) == "--socks-port=")
			a.socks_port = int(substr(v, 13));
		else if (substr(v, 0, 12) == "--http-port=")
			a.http_port = int(substr(v, 12));
		else if (substr(v, 0, 11) == "--api-port=")
			a.api_port = int(substr(v, 11));
		else if (substr(v, 0, 14) == "--tproxy-port=")
			a.tproxy_port = int(substr(v, 14));
		else if (substr(v, 0, 7) == "--safe=")
			a.safe = substr(v, 7);
		else if (substr(v, 0, 13) == "--lte-filter=")
			a.lte_filter = substr(v, 13);
		else if (substr(v, 0, 14) == "--wifi-filter=")
			a.wifi_filter = substr(v, 14);
		else if (substr(v, 0, 13) == "--yt-exclude=")
			a.yt_exclude = substr(v, 13);
		else if (substr(v, 0, 13) == "--eu-exclude=")
			a.eu_exclude = substr(v, 13);
		else if (v == "--async")
			a.async = true;
		else if (v == "--worker")
			a.worker = true;
	}
	return a;
}
function file_size(path) {
	let st = fs.stat(path);
	if (st == null)
		return -1;
	return st.size;
}
function load_text(a) {
	let path = a.file || SUB_CACHE;
	let t = fs.readfile(path);
	if (t == null)
		return { text: null, path: path };
	return { text: t, path: path };
}
// Скачать одну подписку: массив Xray-конфигов Happ. Возвращает результат
// с разбором ошибки (заглушка по hwid — самый частый случай).
function fetch_one(url, hw, ua, proxy) {
	let r = fetchmod.download(url, { ua: ua, hwid: hw, proxy: (proxy != null) ? proxy : 0 });
	if (!r.ok)
		return { ok: false, url: url, error: r.error, configs: [] };

	// Заглушка вместо конфига: провайдер не признал устройство (лимит hwid).
	if (xraymod.is_stub_payload(r.body))
		return { ok: false, url: url, stub: true,
			error: "заглушка: устройство с hwid " + hw + " не зарегистрировано " +
			       "(укажи hwid из Happ или удали лишнее устройство у провайдера)",
			configs: [] };

	let list = xraymod.configs_from(r.body);
	if (list == null) {
		// бывает подписка в виде share-ссылок (vless://…), а не Xray JSON
		let from_links = linksmod.payload(r.body);
		if (from_links == null)
			return { ok: false, url: url, error: "ответ не похож ни на Xray JSON, ни на ссылки vless://", configs: [] };
		list = from_links;
	}

	return { ok: true, url: url, error: "", size: length(r.body), configs: list };
}
// Скачать все подписки из списка и склеить в один массив конфигов.
// Кэш не затирается, если ни одна ссылка не дала конфиг.
function fetch_subscription(s, urls, proxy) {
	let hw = (s.hwid != "") ? s.hwid : fetchmod.local_hwid();
	let merged = [], results = [];

	for (let u in urls) {
		let r = fetch_one(u, hw, s.ua, proxy);
		push(results, r);
		if (!r.ok)
			continue;
		for (let c in r.configs)
			push(merged, c);
	}

	if (length(merged) == 0) {
		let first = (length(results) > 0) ? results[0].error : "нет ссылок";
		return { ok: false, error: first, hwid: hw, results: results };
	}

	ensure_dir("/etc/shoulderx");
	fs.writefile(SUB_CACHE, sprintf("%J", merged));
	return { ok: true, error: "", hwid: hw, results: results,
	         size: file_size(SUB_CACHE), configs: length(merged) };
}
function cmd_fetch(a) {
	let s = settings();
	let urls = (a.url != null && a.url != "") ? [ a.url ] : s.urls;
	if (length(urls) == 0) {
		out("нет ссылки подписки: задай option subscription_url или --url=");
		return 2;
	}

	let r = fetch_subscription(s, urls);
	for (let one in r.results)
		out((one.ok ? "[ok]  " : "[!!]  ") + one.url + " — " +
			(one.ok ? (one.size + " байт, конфигов " + length(one.configs)) : one.error));

	if (!r.ok) {
		out("ни одна подписка не дала конфиг — кэш не тронут");
		return 1;
	}

	out("кэш: " + r.size + " байт, конфигов " + r.configs + " → " + SUB_CACHE);
	return 0;
}
function print_nodes(nodes) {
	for (let i = 0; i < length(nodes); i++) {
		let n = nodes[i];
		print(sprintf("  %2d  %-46s %-9s %s\n", i + 1, n.endpoint,
			(n.tag != null) ? n.tag : "", (n.name != null) ? n.name : ""));
	}
}
function cmd_list(a) {
	let src = load_text(a);
	if (src.text == null) {
		out("нет файла " + src.path + " — сначала shoulderx fetch");
		return 1;
	}
	if (xraymod.is_stub_payload(src.text)) {
		out("в кэше заглушка провайдера — нужен hwid зарегистрированного устройства (LuCI → ShoulderX → HWID)");
		return 1;
	}
	let parsed = xraymod.nodes_from_text(src.text);
	if (parsed.error != "") {
		out("ошибка разбора: " + parsed.error);
		return 1;
	}
	let mode = a.mode || settings().mode;
	let s0 = settings();
	let fopts = {
		lte_filter: (a.lte_filter != null) ? csv(a.lte_filter) : s0.lte_filter,
		wifi_filter: (a.wifi_filter != null) ? csv(a.wifi_filter) : s0.wifi_filter
	};
	let groups = xraymod.split_groups(parsed.nodes, mode, fopts);
	out("всего узлов: " + length(parsed.nodes) + ", режим " + mode);
	for (let g in groups) {
		out("  секция " + g.tag + ": " + length(g.nodes));
		print_nodes(g.nodes);
	}
	return 0;
}
// Узлы из готового конфига — чтобы показать, что подписка добавила и убрала.
function previous_endpoints(path) {
	let text = fs.readfile(path);
	if (text == null)
		return [];
	let c = json(text);
	let res = [];
	if (type(c) != "object" || type(c.outbounds) != "array")
		return res;
	for (let o in c.outbounds) {
		if (type(o) != "object")
			continue;
		let tag = (o.tag != null) ? "" + o.tag : "";
		if (tag == "direct" || tag == "block")
			continue;
		let ep = xraymod.endpoint(o);
		if (ep != "")
			push(res, ep);
	}
	return res;
}
function diff_nodes(old_eps, new_nodes) {
	let old_set = {}, new_set = {}, added = [], removed = [];
	for (let e in old_eps)
		old_set[e] = true;
	for (let n in new_nodes) {
		new_set[n.endpoint] = true;
		if (old_set[n.endpoint] == null)
			push(added, n.endpoint);
	}
	for (let e in old_eps)
		if (new_set[e] == null)
			push(removed, e);
	return { added: added, removed: removed };
}
// Детали узлов из готового конфига: tag, адрес, порт, SNI, транспорт.
// Нужны плиткам в LuCI и команде nodes — в самом конфиге имя сервера не хранится.
function node_details(cfg) {
	let res = [];
	if (type(cfg) != "object" || type(cfg.outbounds) != "array")
		return res;

	for (let o in cfg.outbounds) {
		if (type(o) != "object")
			continue;
		let tag = (o.tag != null) ? "" + o.tag : "";
		if (tag == "direct" || tag == "block" || tag == "api")
			continue;

		let s = (type(o.settings) == "object") ? o.settings : {};
		let v = null;
		if (type(s.vnext) == "array" && length(s.vnext) > 0)
			v = s.vnext[0];
		else if (type(s.servers) == "array" && length(s.servers) > 0)
			v = s.servers[0];
		if (v == null)
			continue;

		let ss = (type(o.streamSettings) == "object") ? o.streamSettings : {};
		let rs = (type(ss.realitySettings) == "object") ? ss.realitySettings : {};
		let ts = (type(ss.tlsSettings) == "object") ? ss.tlsSettings : {};
		let sni = "";
		if (rs.serverName != null)
			sni = "" + rs.serverName;
		else if (ts.serverName != null)
			sni = "" + ts.serverName;

		let net = (ss.network != null) ? "" + ss.network : "tcp";
		let sec = (ss.security != null) ? "" + ss.security : "none";

		push(res, {
			tag: tag,
			section: split(tag, "-")[0],
			server: "" + v.address,
			port: int(v.port),
			sni: sni,
			net: net + ((sec != "none") ? ("+" + sec) : ""),
			endpoint: "" + v.address + ":" + v.port
		});
	}
	return res;
}
function save_state(mode, built, diff) {
	// Имена серверов из подписки в конфиг не попадают (там только теги),
	// поэтому кладём их рядом — из них собираются плитки в LuCI.
	let name_by_tag = {};
	for (let n in built.nodes)
		name_by_tag[n.tag] = n.name;

	let details = node_details(built.config);
	for (let d in details)
		d.name = (name_by_tag[d.tag] != null) ? name_by_tag[d.tag] : d.tag;

	let st = {
		updated: time(),
		mode: mode,
		nodes: length(built.nodes),
		sections: built.sections,
		added: diff.added,
		removed: diff.removed,
		details: details
	};
	ensure_dir("/etc/shoulderx");
	fs.writefile(STATE, sprintf("%J", st) + "\n");
}
function geo_path(s, which) {
	return s.geo_dir + "/" + which;
}
function geo_age(s, which) {
	let st = fs.stat(geo_path(s, which));
	if (st == null)
		return -1;
	return time() - st.mtime;
}
// Нужно ли (пере)качать geo: файлов нет или они старше TTL.
// geo_ttl = 0 — не обновлять автоматически: файлы едут в пакете, обновление
// вручную (`shoulderx geo`) или вместе с пакетом. Иначе каждая сборка в сети
// без доступа к CDN висела бы на таймаутах.
function geo_need(s) {
	if (!s.geo)
		return false;
	if (geo_age(s, "geoip.dat") < 0 || geo_age(s, "geosite.dat") < 0)
		return true;
	if (s.geo_ttl <= 0)
		return false;
	return (geo_age(s, "geoip.dat") > s.geo_ttl || geo_age(s, "geosite.dat") > s.geo_ttl);
}
// Готовы ли файлы для конфига.
function geo_ready(s) {
	return s.geo && geo_age(s, "geoip.dat") >= 0 && geo_age(s, "geosite.dat") >= 0;
}
// Скачать geo-файлы. via_proxy = порт socks (0 — напрямую).
// Качаем в .new и подменяем только при успехе: рабочий конфиг не ломаем.
function geo_download(s, via_proxy) {
	ensure_dir(s.geo_dir);
	let res = { ok: false, error: "", sizes: [] };

	let files = [ [ s.geoip_url, "geoip.dat" ], [ s.geosite_url, "geosite.dat" ] ];
	for (let f in files) {
		let dst = geo_path(s, f[1]);
		let tmp = dst + ".new";
		let r = fetchmod.download(f[0], { out: tmp, proxy: via_proxy, timeout: 60 });
		if (!r.ok) {
			res.error = f[1] + ": " + r.error;
			system("rm -f '" + tmp + "' >/dev/null 2>&1");
			return res;
		}
		system("mv '" + tmp + "' '" + dst + "' >/dev/null 2>&1");
		push(res.sizes, f[1] + " " + r.size + " байт");
	}
	res.ok = true;
	return res;
}
function cmd_geo(a) {
	let s = settings();
	if (!s.geo) {
		out("geo-маршрутизация выключена (option geo '0')");
		return 2;
	}

	let via = 0;
	if (a.direct !== true) {
		/* через туннель: напрямую jsDelivr из РФ обычно недоступен */
		via = s.socks_port;
		if (trim(fetchmod.cmd_out("pidof xray")) == "") {
			out("xray не запущен — сначала поднимите туннель (shoulderx gen --write --restart)");
			return 1;
		}
	}

	let r = geo_download(s, via);
	if (!r.ok) {
		out("не удалось скачать geo: " + r.error);
		return 1;
	}
	out("geo обновлены (" + ((via > 0) ? "через туннель" : "напрямую") + "):");
	for (let x in r.sizes)
		out("  " + x);
	return 0;
}
function cmd_gen(a) {
	uci_commit_pending();
	let s = settings();
	let mode = a.mode || s.mode;

	let src = load_text(a);
	if (src.text == null) {
		out("нет файла " + src.path + " — сначала shoulderx fetch");
		return 1;
	}
	if (xraymod.is_stub_payload(src.text)) {
		out("в кэше заглушка провайдера — нужен hwid зарегистрированного устройства (LuCI → ShoulderX → HWID)");
		return 1;
	}

	let parsed = xraymod.nodes_from_text(src.text);
	if (parsed.error != "") {
		out("ошибка разбора подписки: " + parsed.error);
		return 1;
	}

	let s0 = settings();
	let fopts = {
		lte_filter: (a.lte_filter != null) ? csv(a.lte_filter) : s0.lte_filter,
		wifi_filter: (a.wifi_filter != null) ? csv(a.wifi_filter) : s0.wifi_filter
	};
	let groups = xraymod.split_groups(parsed.nodes, mode, fopts);
	if (length(groups) == 0) {
		out("в режиме " + mode + " нет узлов (всего в подписке: " + length(parsed.nodes) + ")");
		return 1;
	}

	let warnings = [];
	// allow-domains больше не используем: маршрут определяют geo-файлы
	// RoscomVPN (whitelist РФ -> напрямую, всё остальное -> туннель).
	let geo_on = (geo_ready(s) && a.no_geo !== true);
	if (s.geo && !geo_on && !a.quiet)
		push(warnings, "geo-файлов нет — работаю по встроенному списку YouTube");

	let port = a.socks_port || s.socks_port;
	let built = xraymod.build({
		groups: groups,
		mode: mode,
		geo: geo_on,
		socks_port: port,
		http_port: (a.http_port != null) ? a.http_port : s.http_port,
		api_port: (a.api_port != null) ? a.api_port : s.api_port,
		tproxy_port: (a.tproxy_port != null) ? a.tproxy_port : s.tproxy_port
	});
	if (built.error != "") {
		out("ошибка сборки конфига: " + built.error);
		return 1;
	}

	let target = a.out || s.out;
	let diff = diff_nodes(previous_endpoints(target), built.nodes);

	if (a.json) {
		print(sprintf("%J", built.config) + "\n");
		return 0;
	}

	if (!a.write) {
		out("режим: " + mode + ", socks 127.0.0.1:" + port);
		for (let sec in built.sections)
			out("  секция " + sec.tag + ": узлов " + sec.nodes + ", доменов " + sec.domains);
		print_nodes(built.nodes);
		if (length(diff.added) > 0)
			out("новые: " + join(",", diff.added));
		if (length(diff.removed) > 0)
			out("убраны: " + join(",", diff.removed));
		for (let w in warnings)
			out("внимание: " + w);
		out("конфиг не записан — добавь --write (цель: " + target + ")");
		return 0;
	}

	// Временный файл обязан кончаться на .json: xray выбирает формат по
	// расширению и на "config.json.new" падает с "failed to read config".
	let tmp = target + ".new.json";
	let wrote = fs.writefile(tmp, sprintf("%J", built.config) + "\n");
	if (wrote == null) {
		out("не удалось записать " + tmp + " (нет каталога?)");
		return 1;
	}
	if (system("/usr/bin/xray run -test -c '" + tmp + "' >/dev/null 2>&1") != 0) {
		out("конфиг не прошёл проверку xray run -test — оставил прежний");
		fs.unlink(tmp);
		return 1;
	}

	system("mv -f '" + tmp + "' '" + target + "'");
	save_state(mode, built, diff);

	if (!a.quiet) {
		out("конфиг записан: " + target);
		for (let sec in built.sections)
			out("  секция " + sec.tag + ": узлов " + sec.nodes + ", доменов " + sec.domains);
		out("новых: " + length(diff.added) + ", убрано: " + length(diff.removed));
		for (let w in warnings)
			out("внимание: " + w);
	}

	if (a.restart && !a.no_restart) {
		// Сначала снимаем tproxy: он держит DNS клиентов на xray (dnsmasq ->
		// 127.0.0.1:5353). Если оставить, observatory не сможет отрезолвить
		// probeUrl (DNS крутится через тот же xray) и балансировщик не выберет
		// узел — LAN останется без интернета.
		if (a.write)
			system("/usr/lib/shoulderx/tproxy.sh stop >/dev/null 2>&1");

		// пакет xray-core не стартует без xray.enabled.enabled=1
		xray_ensure_enabled();
		let rc = system(s.restart + " >/dev/null 2>&1");
		xray_wait(true);
		if (!a.quiet)
			out("перезапуск xray: " + ((rc == 0) ? "ok" : "код " + rc));
	}

	// прозрачный прокси для LAN: включаем/выключаем вместе с конфигом
	let tport = (a.tproxy_port != null) ? a.tproxy_port : s.tproxy_port;
	if (a.write) {
		if (tport > 0) {
			// ждём, пока балансировщик выберет живой узел: включать tproxy
			// раньше — значит отдать LAN в пустоту
			// ждём ВСЕ балансировщики: если включить tproxy, пока eu ещё не
			// выбрал узел, его трафик уйдёт в fallbackTag (direct) — «интернет
			// пропал»
			let tags = [];
			for (let g in built.sections) {
				if (g.nodes > 1)
					push(tags, g.tag);
			}
			let ready = true;
			if (a.restart && !a.no_restart && length(tags) > 0) {
				ready = false;
				for (let i = 0; i < 75; i++) {
					let all = true;
					for (let tg in tags) {
						if (!balancer_ready(s.api_port, tg)) {
							all = false;
							break;
						}
					}
					if (all) {
						ready = true;
						break;
					}
					system("sleep 1");
				}
			}
			if (!ready) {
				system("/usr/lib/shoulderx/tproxy.sh stop >/dev/null 2>&1");
				out("внимание: балансировщики ещё не выбрали узлы — прозрачный прокси не включён, LAN идёт напрямую (повторите apply через минуту)");
			} else {
				system("SHOULDERX_TPROXY_PORT=" + tport + " SHOULDERX_DNS_PORT=" + s.dns_port + " /usr/lib/shoulderx/tproxy.sh start >/dev/null 2>&1");
				if (!a.quiet)
					out("прозрачный прокси LAN: 127.0.0.1:" + tport);
			}
		} else {
			system("/usr/lib/shoulderx/tproxy.sh stop >/dev/null 2>&1");
		}
	}

	return 0;
}
function job_read() {
	let t = fs.readfile(JOB_FILE);
	if (t == null)
		return null;
	try {
		return json(t);
	} catch (e) {
		return null;
	}
}
function job_write(obj) {
	fs.writefile(JOB_FILE, sprintf("%J", obj) + "\n");
}
function job_phase(name) {
	let j = job_read();
	job_write({ state: "running", started: (j != null) ? j.started : time(),
	            phase: name, rc: 0 });
}
function cmd_job(a) {
	let j = job_read();
	if (j == null)
		j = { state: "idle" };
	print(sprintf("%J", j) + "\n");
	return 0;
}
// Значения, пришедшие из LuCI аргументами, сразу пишем в uci: иначе после
// смены режима в браузере конфиг соберётся по старым настройкам.
function uci_store_args(a) {
	let c = uci.cursor();
	c.load("shoulderx");
	let changed = false;

	if (a.mode != null && a.mode != "") {
		c.set("shoulderx", "settings", "mode", a.mode);
		changed = true;
	}
	if (a.lte_filter != null) {
		c.set("shoulderx", "settings", "lte_filter", csv(a.lte_filter));
		changed = true;
	}
	if (a.wifi_filter != null) {
		c.set("shoulderx", "settings", "wifi_filter", csv(a.wifi_filter));
		changed = true;
	}

	if (changed)
		c.commit("shoulderx");
}
function cmd_apply(a) {
	// --async: запускаем себя в фоне и сразу отвечаем — LuCI не ждёт таймаут
	if (a.async === true && a.worker !== true) {
		let parts = [ "apply", "--worker", "--quiet" ];
		if (a.mode != null) push(parts, "--mode=" + a.mode);
		if (a.lte_filter != null) push(parts, "--lte-filter=" + a.lte_filter);
		if (a.wifi_filter != null) push(parts, "--wifi-filter=" + a.wifi_filter);
		if (a.yt_exclude != null) push(parts, "--yt-exclude=" + a.yt_exclude);
		if (a.eu_exclude != null) push(parts, "--eu-exclude=" + a.eu_exclude);
		if (a.url != null && a.url != "") push(parts, "--url=" + a.url);

		job_write({ state: "running", started: time(), phase: "старт", rc: 0 });
		// setsid отвязывает воркер от ssh-сессии: иначе его убивает SIGHUP
		// и в job-файле навсегда остаётся «подписка»
		system("setsid /usr/bin/shoulderx " + join(" ", parts) + " >>/tmp/shoulderx-apply.log 2>&1 &");
		out("применяю в фоне");
		return 0;
	}

	if (a.worker === true)
		job_write({ state: "running", started: time(), phase: "подписка", rc: 0 });

	uci_commit_pending();
	uci_store_args(a);
	let s = settings();

	// в журнал — с чем именно пришли: помогает понять, что прислала LuCI
	let dbg = [];
	if (a.mode != null) push(dbg, "--mode=" + a.mode);
	if (a.lte_filter != null) push(dbg, "--lte=" + a.lte_filter);
	if (a.wifi_filter != null) push(dbg, "--wifi=" + a.wifi_filter);
	system("logger -t shoulderx 'apply " + join(" ", dbg) + " (uci mode=" + s.mode + " lte=" + join(",", s.lte_filter) + " wifi=" + join(",", s.wifi_filter) + ")'");

	let urls = (a.url != null && a.url != "") ? [ a.url ] : s.urls;
	if (length(urls) > 0) {
		// 1. подписка — напрямую (провайдер доступен без туннеля),
		//    при неудаче пробуем через уже поднятый туннель
		let r = fetch_subscription(s, urls);
		if (!r.ok && (trim(fetchmod.cmd_out("pidof xray")) != "")) {
			let r2 = fetch_subscription(s, urls, s.socks_port);
			if (r2.ok)
				r = r2;
			else if (!a.quiet)
				out("подписка: напрямую " + r.error + "; через туннель " + r2.error);
		}
		if (!r.ok) {
			out("подписки не скачались (" + r.error + ") — собираю из кэша");
		} else if (!a.quiet) {
			for (let one in r.results)
				out((one.ok ? "[ok]  " : "[!!]  ") + one.url + " — " +
					(one.ok ? (one.size + " байт") : one.error));
		}
	}

	// 2. geo-файлы — только через туннель: для этого поднимаем bootstrap
	if (geo_need(s)) {
		let boot = {};
		for (let k in a)
			boot[k] = a[k];
		boot.write = true;
		boot.restart = true;
		boot.no_geo = true;
		boot.quiet = true;

		if (!a.quiet)
			out("geo нет или устарели — поднимаю туннель, чтобы их скачать");
		cmd_gen(boot);
		wait_ready(s, [ "auto", "yt", "eu" ]);

		if (a.worker === true)
			job_phase("geo");

		let gr = geo_download(s, s.socks_port);
		if (!gr.ok)
			gr = geo_download(s, 0);
		if (!a.quiet)
			out(gr.ok ? ("geo обновлены" + ((gr.sizes != null) ? (": " + join(", ", gr.sizes)) : ""))
			          : ("geo не скачались: " + gr.error));
	}

	let g = {};
	for (let k in a)
		g[k] = a[k];
	g.write = true;
	if (!a.no_restart)
		g.restart = true;

	if (a.worker === true)
		job_phase("конфиг и перезапуск");

	let rc = cmd_gen(g);
	if (a.worker === true)
		job_write({ state: "done", started: (job_read() != null) ? job_read().started : time(),
		            phase: (rc == 0) ? "готово" : "ошибка", rc: rc, finished: time() });
	return rc;
}
function read_state() {
	let t = fs.readfile(STATE);
	if (t == null)
		return null;
	return json(t);
}
// Быстрое переключение режима из консоли: shoulderx mode lte|wifi
function cmd_mode(a) {
	let want = (ARGV[1] != null) ? ARGV[1] : "";
	if (want != "lte" && want != "wifi") {
		out("usage: shoulderx mode lte|wifi");
		return 2;
	}
	let aa = {};
	for (let k in a)
		aa[k] = a[k];
	aa.mode = want;
	return cmd_apply(aa);
}

function cmd_status(a) {
	let s = settings();
	let state = read_state();
	let st = {
		mode: s.mode,
		socks_port: s.socks_port,
		http_port: s.http_port,
		config: s.out,
		cache_bytes: file_size(SUB_CACHE),
		config_bytes: file_size(s.out),
		nodes: 0,
		running: false,
		updated: (state != null) ? state.updated : null,
		sections: (state != null) ? state.sections : [],
		added: (state != null) ? state.added : [],
		removed: (state != null) ? state.removed : []
	};

	let text = fs.readfile(s.out);
	if (text != null) {
		let c = json(text);
		if (type(c) == "object" && type(c.outbounds) == "array") {
			for (let o in c.outbounds) {
				let tag = (o.tag != null) ? "" + o.tag : "";
				if (tag != "direct" && tag != "block")
					st.nodes++;
			}
		}
	}

	st.running = (fetchmod.cmd_out("pidof xray") != "");

	if (a.json) {
		print(sprintf("%J", st) + "\n");
		return 0;
	}

	out("режим: " + st.mode + ", socks 127.0.0.1:" + st.socks_port +
		((st.http_port > 0) ? (", http 127.0.0.1:" + st.http_port) : ""));
	if (length(st.sections) > 0) {
		let parts = [];
		for (let sec in st.sections)
			push(parts, sec.tag + ": " + sec.nodes + " узлов/" + sec.domains + " доменов");
		out("секции: " + join("; ", parts));
	}
	out("подписка: " + ((st.cache_bytes >= 0) ? ("кэш " + st.cache_bytes + " байт") : "не скачана"));
	out("конфиг: " + st.config + " (" + ((st.config_bytes >= 0) ? (st.config_bytes + " байт, узлов " + st.nodes) : "нет") + ")");
	if (length(st.added) > 0)
		out("добавлены в этот раз: " + join(",", st.added));
	if (length(st.removed) > 0)
		out("убраны в этот раз: " + join(",", st.removed));
	out("xray: " + (st.running ? "работает" : "не запущен"));
	return 0;
}
function interval_minutes(iv) {
	iv = "" + iv;
	if (length(iv) > 1 && substr(iv, length(iv) - 1) == "h")
		return int(substr(iv, 0, length(iv) - 1)) * 60;
	if (length(iv) > 1 && substr(iv, length(iv) - 1) == "m")
		return int(substr(iv, 0, length(iv) - 1));
	return 360;
}
function cmd_schedule(off) {
	let s = settings();
	let enabled = off ? false : s.schedule;

	let cur = fs.readfile(CRONTAB);
	let lines = (cur == null) ? [] : split(cur, "\n");
	let kept = [];
	for (let l in lines) {
		if (trim(l) == "")
			continue;
		if (index(l, "/usr/bin/shoulderx") >= 0)
			continue;
		push(kept, l);
	}

	if (enabled) {
		let mins = interval_minutes(s.interval);
		let spec;
		if (mins <= 60)
			spec = "*/" + mins + " * * * *";
		else
			spec = "0 */" + int(mins / 60) + " * * * *";
		push(kept, spec + " /usr/bin/shoulderx apply --quiet");
	}

	ensure_dir("/etc/crontabs");
	let body = "";
	for (let l in kept)
		body += l + "\n";
	fs.writefile(CRONTAB, body);
	system("/etc/init.d/cron restart >/dev/null 2>&1");

	out(enabled ? ("cron: каждые " + s.interval) : "cron: выключен");
	return 0;
}
// Куда уйдёт домен по текущему конфигу: "tunnel" | "direct" | "?".
// Повторяет порядок правил Xray: первое совпадение выигрывает, правило без
// доменов и IP — это catch-all в конце.
function route_for(domain, cfg) {
	let rules = null;
	if (type(cfg) == "object" && type(cfg.routing) == "object")
		rules = cfg.routing.rules;
	if (type(rules) != "array")
		return "?";

	let dom = lc("" + domain);

	for (let r in rules) {
		if (type(r) != "object")
			continue;

		// Правила для конкретного входа (api-in → api) клиентский трафик не
		// описывают — иначе они выглядят как catch-all и «уводят в туннель» всё.
		if (r.inboundTag != null)
			continue;

		if (type(r.domain) == "array") {
			for (let d in r.domain) {
				d = "" + d;
				if (substr(d, 0, 7) != "domain:")
					continue;
				let suffix = lc(substr(d, 7));
				let hit = (dom == suffix) ||
					(length(dom) > length(suffix) &&
					 substr(dom, length(dom) - length(suffix) - 1) == "." + suffix);
				if (hit)
					return (r.outboundTag == "direct") ? "direct" : "tunnel";
			}
			continue;
		}

		// правило без условий по домену/IP — общий случай
		if (r.domain == null && r.ip == null) {
			if (r.balancerTag != null)
				return "tunnel";
			if (r.outboundTag == "direct")
				return "direct";
			if (r.outboundTag != null)
				return "tunnel";
		}
	}
	return "?";
}
// curl отдаёт секунды "1.234567"; double() в этой сборке ucode нет, считаем сами.
function seconds_to_ms(str) {
	let s = trim("" + str);
	let dot = index(s, ".");
	let sec = 0, frac = 0;
	if (dot < 0) {
		sec = int(s);
	} else {
		sec = (dot > 0) ? int(substr(s, 0, dot)) : 0;
		let f = substr(s, dot + 1) + "000";
		frac = int(substr(f, 0, 3));
	}
	return sec * 1000 + frac;
}
function read_result(path) {
	let s = fs.readfile(path);
	if (s == null)
		return { ok: false, code: "000", ms: 0 };
	let parts = split(trim("" + s), " ");
	let code = (length(parts) > 0) ? parts[0] : "000";
	let ms = (length(parts) > 1) ? seconds_to_ms(parts[1]) : 0;
	// 403/451 — это тоже «не работает»: именно так отвечает Cloudflare, когда
	// сервис блокирует страну/адрес ноды (ChatGPT через заблокированную ноду).
	let d = substr("" + code, 0, 1);
	let ok = (d == "2" || d == "3");
	return { ok: ok, code: code, ms: ms };
}
// Проверка сервисов: и через туннель (socks xray, как ходят клиенты), и напрямую.
// Все запросы запускаются параллельно одним sh, чтобы уложиться в один таймаут.
function run_checks(svcs, proxy_port) {
	// rand() в этой сборке ucode нет, pid оболочки достаточно для уникальности
	let dir = "/tmp/.shoulderx.check." + time() + "." + fetchmod.cmd_out("echo $$");
	ensure_dir(dir);

	let script = "cd '" + dir + "' 2>/dev/null\n";
	for (let i = 0; i < length(svcs); i++) {
		let d = svcs[i].domain;
		// РФ-сервисы через туннель не проверяем — они туда и не должны ходить
		if (svcs[i].tunnel != false)
			script += "curl -x socks5h://127.0.0.1:" + proxy_port + " -m " + CHECK_TIMEOUT +
				" -s -o /dev/null -w '%{http_code} %{time_total}' 'https://" + d + "/' > t" + i + " 2>/dev/null &\n";
		script += "curl -m " + CHECK_TIMEOUT +
			" -s -o /dev/null -w '%{http_code} %{time_total}' 'https://" + d + "/' > d" + i + " 2>/dev/null &\n";
	}
	script += "wait\n";

	system("sh -c '" + replace(script, "'", "'\\''") + "' >/dev/null 2>&1");

	let res = [];
	for (let i = 0; i < length(svcs); i++) {
		let via = (svcs[i].tunnel != false)
			? read_result(dir + "/t" + i)
			: { ok: false, code: "", ms: 0, skipped: true };
		push(res, { via: via, direct: read_result(dir + "/d" + i) });
	}

	system("rm -rf '" + dir + "' >/dev/null 2>&1");
	return res;
}
// В geo-режиме маршрут определяют бинарные списки RoscomVPN: заранее по
// конфигу его не посчитать, поэтому проверяем оба пути и смотрим, что вышло.
function cfg_geo_mode(cfg) {
	if (type(cfg) != "object" || type(cfg.routing) != "object")
		return false;
	let rules = cfg.routing.rules;
	if (type(rules) != "array")
		return false;
	for (let r in rules) {
		if (type(r) != "object" || type(r.domain) != "array")
			continue;
		for (let d in r.domain) {
			if (substr("" + d, 0, 4) == "ext:")
				return true;
		}
	}
	return false;
}
function cmd_check(a) {
	let s = settings();
	let cfg = json(fs.readfile(s.out) || "null");
	let geo = cfg_geo_mode(cfg);
	let svcs = [];

	for (let sv in SERVICES) {
		if (a.group != null && a.group != "all" && sv.group != a.group)
			continue;
		push(svcs, { group: sv.group, name: sv.name, domain: sv.domain,
		             route: geo ? "geo" : route_for(sv.domain, cfg),
		             // РФ-сервисы проверяем только напрямую (кроме geo-режима)
		             tunnel: geo ? true : (sv.group != "ru") });
	}
	if (length(svcs) == 0) {
		out("нет сервисов для группы " + a.group);
		return 1;
	}

	let results = run_checks(svcs, s.socks_port);
	let rows = [];
	let failed = 0;

	for (let i = 0; i < length(svcs); i++) {
		let sv = svcs[i];
		let via = results[i].via;
		let dir = results[i].direct;
		// РФ-сервисы должны открываться напрямую — их и проверяем только так.
		// Прокси-сервисы — тем путём, которым пойдут по текущему конфигу.
		let ok = (sv.route == "geo") ? via.ok : (sv.tunnel ? ((sv.route == "direct") ? dir.ok : via.ok) : dir.ok);
		if (!ok)
			failed++;
		push(rows, {
			group: sv.group, name: sv.name, domain: sv.domain, route: sv.route,
			ok: ok,
			via_skipped: (via.skipped === true),
			via_code: via.code, via_ms: via.ms,
			direct_code: dir.code, direct_ms: dir.ms
		});
	}

	if (a.json) {
		print(sprintf("%J", { ts: time(), mode: s.mode, rows: rows, failed: failed }) + "\n");
		return (failed > 0) ? 1 : 0;
	}

	for (let r in rows) {
		let mark = r.ok ? "[ok]  " : "[!!]  ";
		let via_s = r.via_skipped ? "не проверяется" :
			(r.via_code + ((r.via_ms > 0) ? ("/" + r.via_ms + "мс") : ""));
		let route_s = (r.route == "geo") ? "по спискам" : r.route;
		print(sprintf("%s%-14s %-22s маршрут: %-7s туннель: %-14s напрямую: %s\n",
			mark, r.name, r.domain, route_s, via_s,
			r.direct_code + ((r.direct_ms > 0) ? ("/" + r.direct_ms + "мс") : "")));
	}
	out(failed == 0 ? "все сервисы отвечают" : ("не отвечают: " + failed));
	return (failed > 0) ? 1 : 0;
}
// TCP-время до узла (DNS + connect) — «пинг» для плиток, как в podkop.
function ping_nodes(nodes) {
	let dir = "/tmp/.shoulderx.ping." + time() + "." + fetchmod.cmd_out("echo $$");
	ensure_dir(dir);

	let script = "cd '" + dir + "' 2>/dev/null\n";
	for (let i = 0; i < length(nodes); i++)
		script += "curl -s -o /dev/null -m 5 -w '%{time_connect}' 'http://" + nodes[i].server + ":" +
			nodes[i].port + "/' > p" + i + " 2>/dev/null &\n";
	script += "wait\n";
	system("sh -c '" + replace(script, "'", "'\\''") + "' >/dev/null 2>&1");

	let ms = [];
	for (let i = 0; i < length(nodes); i++) {
		let r = fs.readfile(dir + "/p" + i);
		push(ms, (r == null) ? 0 : seconds_to_ms(r));
	}
	system("rm -rf '" + dir + "' >/dev/null 2>&1");
	return ms;
}
function cmd_nodes(a) {
	let s = settings();
	let st = read_state();
	let details = (st != null && type(st.details) == "array") ? st.details : [];

	// state.json мог остаться от прежнего конфига — тогда берём узлы из конфига.
	if (length(details) == 0) {
		let cfg = json(fs.readfile(s.out) || "null");
		details = node_details(cfg);
	}

	if (length(details) == 0) {
		out("в конфиге нет узлов — сначала shoulderx apply");
		return 1;
	}

	let ms = ping_nodes(details);
	let sections = [], seen = {}, selected = {};

	for (let i = 0; i < length(details); i++) {
		let d = details[i];
		if (selected[d.section] == null && s.api_port > 0)
			selected[d.section] = balancer_selected(s.api_port, d.section);
		if (seen[d.section] == null) {
			seen[d.section] = true;
			push(sections, { tag: d.section, nodes: [] });
		}
		d.ms = ms[i];
		d.selected = (selected[d.section] == d.tag);
		push(sections[length(sections) - 1].nodes, d);
	}

	if (a.json) {
		print(sprintf("%J", { ts: time(), sections: sections }) + "\n");
		return 0;
	}

	for (let sec in sections) {
		out("секция " + sec.tag + " (" + length(sec.nodes) + "):");
		for (let n in sec.nodes)
			print(sprintf("  %s %-8s %-42s %-18s %s\n",
				n.selected ? "[*]" : "[ ]", n.tag, n.endpoint, n.net,
				(n.ms > 0) ? (n.ms + "мс") : "—"));
	}
	return 0;
}
// Состояние сервиса: автозапуск (симлинк в /etc/rc.d) и запущенный процесс.
function xray_autostart(init) {
	let out_s = fetchmod.cmd_out("ls /etc/rc.d/S*xray 2>/dev/null");
	return (trim(out_s) != "");
}
function cmd_state(a) {
	let s = settings();
	let pid = trim(fetchmod.cmd_out("pidof xray"));
	let st = {
		autostart: xray_autostart(s.init),
		running: (pid != ""),
		pid: pid,
		init: s.init
	};

	if (a.json) {
		print(sprintf("%J", st) + "\n");
		return 0;
	}

	out("автозапуск: " + (st.autostart ? "включён" : "выключен"));
	out("xray: " + (st.running ? ("работает, pid " + st.pid) : "остановлен"));
	return 0;
}
function cmd_autostart(a) {
	let s = settings();
	let what = (ARGV[1] != null) ? ARGV[1] : "";

	if (what == "on" || what == "1")
		system(s.init + " enable >/dev/null 2>&1");
	else if (what == "off" || what == "0")
		system(s.init + " disable >/dev/null 2>&1");
	else {
		out("usage: shoulderx autostart on|off");
		return 2;
	}

	let st = { autostart: xray_autostart(s.init), running: (trim(fetchmod.cmd_out("pidof xray")) != "") };
	if (a.json) {
		print(sprintf("%J", st) + "\n");
		return 0;
	}
	out("автозапуск: " + (st.autostart ? "включён" : "выключен"));
	return 0;
}
function cmd_service(a) {
	let s = settings();
	let what = (ARGV[1] != null) ? ARGV[1] : "";

	if (what == "start" || what == "on") {
		xray_ensure_enabled();
		system(s.init + " start >/dev/null 2>&1");
		xray_wait(true);
	} else if (what == "stop" || what == "off") {
		// сначала снимаем правила tproxy, иначе LAN останется без интернета
		system("/usr/lib/shoulderx/tproxy.sh stop >/dev/null 2>&1");
		system(s.init + " stop >/dev/null 2>&1");
		xray_wait(false);
	} else {
		out("usage: shoulderx service start|stop");
		return 2;
	}

	let st = { autostart: xray_autostart(s.init), running: (trim(fetchmod.cmd_out("pidof xray")) != "") };
	if (a.json) {
		print(sprintf("%J", st) + "\n");
		return 0;
	}
	out("xray: " + (st.running ? "работает" : "остановлен"));
	return 0;
}
// Прозрачный прокси для LAN: start/stop/status/confirm, реализация в tproxy.sh.
function cmd_tproxy(a) {
	let s = settings();
	let what = (ARGV[1] != null) ? ARGV[1] : "status";
	let env = "SHOULDERX_TPROXY_PORT=" + ((s.tproxy_port > 0) ? s.tproxy_port : 12345) + " ";
	let sh = "/usr/lib/shoulderx/tproxy.sh";

	if (what == "start") {
		let safe = (a.safe != null) ? (" --safe=" + a.safe) : "";
		system(env + sh + " start" + safe);
	} else if (what == "stop") {
		system(sh + " stop");
	} else if (what == "confirm") {
		system(sh + " confirm");
	} else {
		system(env + sh + " status");
	}
	return 0;
}

let cmd = ARGV[0] || "help";
let a = parse_args(ARGV);

if (cmd == "fetch") {
	exit(cmd_fetch(a));
} else if (cmd == "list") {
	exit(cmd_list(a));
} else if (cmd == "gen") {
	exit(cmd_gen(a));
} else if (cmd == "apply") {
	exit(cmd_apply(a));
} else if (cmd == "check") {
	exit(cmd_check(a));
} else if (cmd == "nodes") {
	exit(cmd_nodes(a));
} else if (cmd == "state") {
	exit(cmd_state(a));
} else if (cmd == "autostart") {
	exit(cmd_autostart(a));
} else if (cmd == "service") {
	exit(cmd_service(a));
} else if (cmd == "tproxy") {
	exit(cmd_tproxy(a));
} else if (cmd == "geo") {
	exit(cmd_geo(a));
} else if (cmd == "mode") {
	exit(cmd_mode(a));
} else if (cmd == "job") {
	exit(cmd_job(a));
} else if (cmd == "status") {
	exit(cmd_status(a));
} else if (cmd == "schedule") {
	exit(cmd_schedule(ARGV[1] == "off"));
} else {
	print("usage: shoulderx <fetch|list|gen|apply|check|nodes|state|autostart|service|tproxy|geo|status|schedule>\n" +
	      "       [--url=..] [--file=..] [--mode=lte|wifi] [--group=proxy|ru|all]\n" +
	      "       [--socks-port=20180] [--http-port=0] [--api-port=20190] [--tproxy-port=12345]\n" +
	      "       [--no-geo] [--out=FILE] [--write] [--restart] [--json] [--quiet]\n" +
	      "       [--safe=SEC] [--direct]\n" +
	      "       autostart on|off, service start|stop, tproxy start|stop|status|confirm,\n" +
	      "       geo [--direct], schedule off\n");
	exit(2);
}
