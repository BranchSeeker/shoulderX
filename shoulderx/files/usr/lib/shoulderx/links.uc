// links.uc — подписка в виде share-ссылок (vless://, trojan://), как их отдают
// некоторые панели. Приводим ссылки к тем же объектам, что и Xray JSON из
// подписки Remnawave, чтобы дальше работал общий разбор (nodes_from_text).

'use strict';

function unhex(c) {
	let i = index("0123456789abcdef", lc("" + c));
	return (i >= 0) ? i : 0;
}

function urldecode(s) {
	let out = "", i = 0;
	s = "" + s;
	while (i < length(s)) {
		let c = substr(s, i, 1);
		if (c == "%" && i + 2 < length(s)) {
			out += chr(unhex(substr(s, i + 1, 1)) * 16 + unhex(substr(s, i + 2, 1)));
			i += 3;
		} else if (c == "+") {
			out += " ";
			i++;
		} else {
			out += c;
			i++;
		}
	}
	return out;
}

// "a=1&b=2" -> { a: "1", b: "2" }
function query(str) {
	let q = {};
	for (let kv in split("" + str, "&")) {
		if (kv == "")
			continue;
		let eq = index(kv, "=");
		if (eq < 0) {
			q[urldecode(kv)] = "";
			continue;
		}
		q[urldecode(substr(kv, 0, eq))] = urldecode(substr(kv, eq + 1));
	}
	return q;
}

// Разбор "scheme://..." на части: userinfo, host, port, query, имя (fragment).
function split_link(link) {
	let s = "" + link;
	let p = index(s, "://");
	if (p < 0)
		return null;
	let scheme = lc(substr(s, 0, p));
	let rest = substr(s, p + 3);

	let name = "";
	let hash = index(rest, "#");
	if (hash >= 0) {
		name = urldecode(substr(rest, hash + 1));
		rest = substr(rest, 0, hash);
	}

	let q = {};
	let qm = index(rest, "?");
	if (qm >= 0) {
		q = query(substr(rest, qm + 1));
		rest = substr(rest, 0, qm);
	}

	let at = index(rest, "@");
	let user = "", hostport = rest;
	if (at >= 0) {
		user = substr(rest, 0, at);
		hostport = substr(rest, at + 1);
	}

	let host = hostport, port = 0;
	let c = rindex(hostport, ":");
	if (c >= 0) {
		host = substr(hostport, 0, c);
		port = int(substr(hostport, c + 1));
	}
	host = replace(host, "[", "");
	host = replace(host, "]", "");

	return { scheme: scheme, user: urldecode(user), host: host, port: port, q: q, name: name };
}

function streams(l) {
	let q = l.q;
	let net = (q.type != null && q.type != "") ? lc(q.type) : "tcp";
	let sec = (q.security != null && q.security != "") ? lc(q.security) : "none";
	let ss = {};

	if (net == "ws" || net == "websocket") {
		ss.network = "ws";
		let ws = { path: (q.path != null && q.path != "") ? q.path : "/" };
		if (q.host != null && q.host != "")
			ws.headers = { Host: q.host };
		ss.wsSettings = ws;
	} else if (net == "grpc" || net == "gun") {
		ss.network = "grpc";
		let g = { serviceName: (q.serviceName != null) ? q.serviceName : "" };
		if (q.mode == "multi")
			g.multiMode = true;
		ss.grpcSettings = g;
	} else if (net == "xhttp" || net == "splithttp") {
		ss.network = "xhttp";
		let x = { path: (q.path != null && q.path != "") ? q.path : "/" };
		if (q.host != null && q.host != "")
			x.host = q.host;
		if (q.mode != null && q.mode != "")
			x.mode = q.mode;
		ss.xhttpSettings = x;
	} else if (net == "http" || net == "h2") {
		ss.network = "h2";
		let h = { path: (q.path != null && q.path != "") ? q.path : "/" };
		if (q.host != null && q.host != "")
			h.host = [ q.host ];
		ss.httpSettings = h;
	} else {
		ss.network = "tcp";
		if (q.headerType == "http") {
			let req = { path: [ (q.path != null && q.path != "") ? q.path : "/" ] };
			if (q.host != null && q.host != "")
				req.headers = { Host: [ q.host ] };
			ss.tcpSettings = { header: { type: "http", request: req } };
		}
	}

	if (sec == "reality") {
		ss.security = "reality";
		let rs = {
			serverName: (q.sni != null && q.sni != "") ? q.sni : ((q.host != null) ? q.host : ""),
			publicKey: (q.pbk != null) ? q.pbk : "",
			shortId: (q.sid != null) ? q.sid : "",
			fingerprint: (q.fp != null && q.fp != "") ? q.fp : "chrome"
		};
		if (q.spx != null && q.spx != "")
			rs.spiderX = q.spx;
		ss.realitySettings = rs;
	} else if (sec == "tls") {
		ss.security = "tls";
		let ts = { serverName: (q.sni != null && q.sni != "") ? q.sni : ((q.host != null) ? q.host : "") };
		if (q.alpn != null && q.alpn != "")
			ts.alpn = split(q.alpn, ",");
		if (q.fp != null && q.fp != "")
			ts.fingerprint = q.fp;
		ss.tlsSettings = ts;
	} else {
		ss.security = "none";
	}

	return ss;
}

function vless_outbound(link, name) {
	let l = split_link(link);
	if (l == null || l.host == "" || l.port == 0 || l.user == "")
		return null;

	let user = { id: l.user, encryption: (l.q.encryption != null && l.q.encryption != "") ? l.q.encryption : "none" };
	if (l.q.flow != null && l.q.flow != "")
		user.flow = l.q.flow;

	return {
		tag: "proxy",
		protocol: "vless",
		settings: { vnext: [ { address: l.host, port: l.port, users: [ user ] } ] },
		streamSettings: streams(l),
		__name: (name != "") ? name : (l.name != "" ? l.name : (l.host + ":" + l.port))
	};
}

function trojan_outbound(link) {
	let l = split_link(link);
	if (l == null || l.host == "" || l.port == 0 || l.user == "")
		return null;
	return {
		tag: "proxy",
		protocol: "trojan",
		settings: { servers: [ { address: l.host, port: l.port, password: l.user } ] },
		streamSettings: streams(l),
		__name: (l.name != "") ? l.name : (l.host + ":" + l.port)
	};
}

// Текст подписки -> массив конфигов в формате, который понимает nodes_from_text.
// Возвращает null, если это не похоже на share-ссылки.
function payload(text) {
	if (text == null)
		return null;

	let links = [];
	for (let line in split("" + text, "\n")) {
		line = trim(line);
		if (line == "" || substr(line, 0, 1) == "#")
			continue;
		if (index(lc(line), "://") > 0)
			push(links, line);
	}
	if (length(links) == 0)
		return null;

	let configs = [];
	for (let link in links) {
		let low = lc(link);
		let o = null;
		if (substr(low, 0, 8) == "vless://")
			o = vless_outbound(link, "");
		else if (substr(low, 0, 9) == "trojan://")
			o = trojan_outbound(link);
		if (o == null)
			continue;

		let name = o.__name;
		delete o.__name;
		push(configs, {
			remarks: name,
			outbounds: [
				o,
				{ tag: "direct", protocol: "freedom", settings: {} },
				{ tag: "block", protocol: "blackhole", settings: {} }
			]
		});
	}

	return (length(configs) > 0) ? configs : null;
}

return {
	payload: payload,
	vless_outbound: vless_outbound,
	urldecode: urldecode
};
