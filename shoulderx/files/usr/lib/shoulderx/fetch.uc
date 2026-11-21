// fetch.uc — загрузка подписки.
//
// Remnawave отдаёт Xray JSON только «своим» клиентам: нужен UA Happ и заголовок
// x-hwid. Без них приходит заглушка на 500 байт («Приложение не подходит»).
// Заголовок x-hwid — 12 hex из MAC роутера, как в shoulderkop. Если у провайдера
// лимит устройств, hwid можно задать руками в /etc/config/shoulderx.

'use strict';

let fs = require("fs");

const UA_DEFAULT = "Happ/2.7.0";
const CONNECT_TIMEOUT = 8;
const MAX_TIME = 40;

let seq = 0;

function own_pid() {
	let s = fs.readfile("/proc/self/stat");
	if (s == null || s == "")
		return "" + time();
	let sp = index(s, " ");
	return (sp > 0) ? substr(s, 0, sp) : "" + time();
}
function tmpfile(tag) {
	seq++;
	return "/tmp/.shoulderx." + tag + "." + own_pid() + "." + seq;
}
// system() в этой сборке ucode не отдаёт stdout — пишем в файл и читаем.
function cmd_out(cmd) {
	let tmp = tmpfile("out");
	system(cmd + " > " + tmp + " 2>/dev/null");
	let out = fs.readfile(tmp);
	fs.unlink(tmp);
	return (out == null) ? "" : trim(out);
}
function cmd_quiet(cmd) {
	system(cmd + " >/dev/null 2>&1");
}
// Есть ли curl. Без него «нет связи» — не сеть виновата, а пакет.
function have_curl() {
	return (cmd_out("command -v curl") != "");
}
// HWID из MAC: 12 hex-символов в верхнем регистре.
function hwid(mac, fallback) {
	let hex = "";
	if (mac != null) {
		for (let i = 0; i < length(mac); i++) {
			let c = substr(mac, i, 1);
			if (index("0123456789abcdef", lc(c)) >= 0)
				hex += c;
		}
	}
	if (length(hex) > 12)
		hex = substr(hex, 0, 12);
	if (hex == "")
		hex = (fallback != null && fallback != "") ? fallback : "000000000000";
	return uc(hex);
}
// MAC первого доступного интерфейса.
function local_hwid() {
	let mac = fs.readfile("/sys/class/net/br-lan/address");
	if (mac == null)
		mac = fs.readfile("/sys/class/net/eth0/address");
	if (mac == null)
		mac = fs.readfile("/sys/class/net/wan/address");
	return hwid(mac, "");
}
// download(url, opts) -> { ok, code, body, error }
// opts: ua, hwid, timeout, proxy (порт socks на 127.0.0.1), out (файл вместо буфера)
function download(url, opts) {
	opts = opts || {};
	let ua = opts.ua || UA_DEFAULT;
	let hdr = "";
	if (opts.hwid != null && opts.hwid != "")
		hdr = "-H 'x-hwid: " + opts.hwid + "' ";
	let prox = "";
	if (opts.proxy != null && opts.proxy > 0)
		prox = "-x socks5h://127.0.0.1:" + opts.proxy + " ";

	let body = (opts.out != null) ? opts.out : tmpfile("sub");
	let maxt = (opts.timeout != null) ? opts.timeout : MAX_TIME;
	let args = "-sS -4 -o '" + body + "' -w '%{http_code}' " +
		"--connect-timeout " + CONNECT_TIMEOUT + " -m " + maxt + " " +
		prox + "-A '" + ua + "' " + hdr + "'" + url + "'";
	let code = cmd_out("curl " + args);

	// Часы роутера часто врут (нет NTP) — падает проверка сертификата, и это
	// выглядит как «нет связи». Пробуем ещё раз без проверки TLS.
	if ((code == "000" || code == "") && index("" + url, "https://") == 0) {
		code = cmd_out("curl -k " + args);
		if (code == "200") {
			let now = cmd_out("date");
			system("logger -t shoulderx 'TLS не проверялся (часы: " + now + ")'");
		}
	}
	let res = { ok: false, code: code, body: "", error: "" };
	if (opts.out != null) {
		// файл: читать в память не нужно, только проверить размер
		let st = fs.stat(opts.out);
		res.size = (st != null) ? st.size : 0;
		if (code == "200" && res.size > 0) {
			res.ok = true;
			return res;
		}
		if (code == "200")
			res.error = "пустой файл";
		else if (code == "000" || code == "")
			res.error = have_curl() ? "curl: нет связи" : "curl не установлен (apk add curl)";
		else
			res.error = "http " + code;
		return res;
	}

	let data = fs.readfile(body);
	fs.unlink(body);
	if (data != null)
		res.body = data;

	if (code == "200" && length(res.body) > 0) {
		res.ok = true;
	} else if (code == "000" || code == "") {
		res.error = have_curl() ? "curl: нет связи" : "curl не установлен (apk add curl)";
	} else {
		res.error = "http " + code;
	}
	return res;
}

return {
	download: download,
	have_curl: have_curl,
	hwid: hwid,
	local_hwid: local_hwid,
	cmd_out: cmd_out,
	cmd_quiet: cmd_quiet
};
