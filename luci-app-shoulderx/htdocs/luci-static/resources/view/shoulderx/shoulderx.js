'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require dom';

// ShoulderX — одна страница: подписка и режим, плитки серверов с пинг-тестом,
// кнопки автозапуска/старта сервиса, форма настроек, тест сервисов и
// диагностика под спойлером.
//
// «Обновить подписку» — сохраняет настройки, тянет подписку и пересобирает
// /etc/xray/config.json (серверы, которых больше нет в подписке, исчезают).
//
// Кнопки автозапуска и старта работают как в podkop: сначала показывается
// «проверяю…», через небольшую задержку запрашивается состояние (симлинк в
// /etc/rc.d + pidof xray) и кнопки перерисовываются по факту.

var MODE_LTE = 'lte';
var MODE_WIFI = 'wifi';



function errText(e) {
	return (e && e.message) ? e.message : String(e);
}

function modeName(m) {
	return (m === MODE_WIFI) ? _('домашний интернет') : _('обход БС');
}

function run(argv) {
	return fs.exec('/usr/bin/shoulderx', argv).then(function (r) {
		if (r.code !== 0)
			throw new Error((r.stderr || r.stdout || ('код ' + r.code)).trim());
		return r;
	});
}

// То же, но ненулевой код не считается ошибкой: check/nodes/state возвращают 1,
// когда часть сервисов не отвечает, а JSON с результатами всё равно нужен.
function runLoose(argv) {
	return fs.exec('/usr/bin/shoulderx', argv).catch(function () {
		return { code: 1, stdout: '', stderr: '' };
	});
}

function wait(ms) {
	return new Promise(function (resolve) { window.setTimeout(resolve, ms); });
}

function fmtTime(ts) {
	if (!ts)
		return '—';
	return new Date(ts * 1000).toLocaleString();
}

function codeText(code, ms) {
	if (!code || code === '000' || code === '')
		return '—';
	return code + (ms ? ' · ' + ms + ' мс' : '');
}

function routeText(route) {
	if (route === 'direct')
		return _('напрямую');
	if (route === 'tunnel')
		return _('туннель');
	if (route === 'geo')
		return _('по geo-спискам');
	return '?';
}

// Результаты проверки сервисов — карточками, а не таблицей: на телефоне
// таблица из шести колонок разваливается в нечитаемую стопку.
function checkCard(r, mode) {
	var color = r.ok ? '#2e7d32' : '#b00020';

	return E('div', {
		'style': 'flex:1 1 230px;min-width:210px;max-width:340px;font-size:12px;line-height:1.35;' +
			'border:1px solid ' + color + ';border-radius:4px;padding:5px 8px'
	}, [
		E('div', { 'style': 'display:flex;justify-content:space-between;gap:6px;font-weight:bold;font-size:12px' }, [
			E('span', { 'style': 'word-break:break-word' }, r.name),
			E('span', {}, r.ok ? '✅' : '❌')
		]),
		E('div', { 'style': 'color:#777;font-size:11px;word-break:break-all' }, r.domain),
		E('div', { 'style': 'font-size:11px;margin-top:3px' },
			_('маршрут: ') + routeText(r.route) +
			((r.group === 'ru' && r.route === 'tunnel')
				? ' ⚠ ' + (mode === 'lte'
					? _('РФ-сервис идёт в туннель — добавь его в «Списки доменов напрямую»')
					: _('РФ-сервис уходит в туннель — убери russia_inside из списков секции eu'))
				: '') +
			((r.group === 'proxy' && r.route === 'direct')
				? ' ⚠ ' + (mode === 'lte'
					? _('идёт напрямую — добавь список в «Списки в туннель»')
					: _('идёт напрямую — добавь список в секцию yt или eu'))
				: '')),
		// РФ-сервисы через туннель не проверяем — показываем только прямой путь
		E('div', { 'style': 'font-size:11px' },
			r.via_skipped
				? _('напрямую: ') + codeText(r.direct_code, r.direct_ms)
				: _('туннель: ') + codeText(r.via_code, r.via_ms) +
				  ' · ' + _('напрямую: ') + codeText(r.direct_code, r.direct_ms))
	]);
}

function checkTable(d) {
	var rows = (d && d.rows) ? d.rows : [];
	if (rows.length === 0)
		return E('p', {}, _('Нет данных'));

	var cards = [];
	rows.forEach(function (r) { cards.push(checkCard(r, d.mode)); });

	return E('div', {}, [
		E('p', { 'style': 'margin:6px 0' },
			_('Проверено: ') + rows.length + _(' · не отвечают: ') + (d.failed || 0)),
		E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:6px' }, cards)
	]);
}

// Плитки серверов из текущего конфига: секция → компактные карточки.
// Выбранный балансировщиком узел выделяется только зелёной обводкой.
function nodeCard(n) {
	var style = 'min-width:170px;max-width:240px;font-size:12px;line-height:1.3;' +
		'border-radius:4px;padding:4px 7px;background:transparent;' +
		(n.selected ? 'border:2px solid #2e7d32;' : 'border:1px solid #bbb;');

	return E('div', { 'style': style }, [
		E('div', { 'style': 'font-weight:bold;font-size:12px;word-break:break-word' },
			(n.name || n.tag) + (n.selected ? '  ✓' : '')),
		E('div', { 'style': 'color:#777;font-size:11px;word-break:break-all' },
			n.tag + ' · ' + n.endpoint),
		E('div', { 'style': 'font-size:11px' },
			(n.net || '') + ' · ' + ((n.ms > 0) ? (n.ms + ' ' + _('мс')) : _('нет ответа')))
	]);
}

function nodesPanel(d) {
	var sections = (d && d.sections) ? d.sections : [];
	if (sections.length === 0)
		return E('p', {}, _('В конфиге нет узлов — нажмите «Обновить подписку».'));

	var blocks = [];
	sections.forEach(function (sec) {
		var cards = [];
		(sec.nodes || []).forEach(function (n) { cards.push(nodeCard(n)); });

		blocks.push(E('div', { 'style': 'margin-bottom:10px' }, [
			E('div', { 'style': 'font-weight:bold;font-size:13px;margin:6px 0 4px' },
				_('секция ') + sec.tag + ' (' + (sec.nodes || []).length + ')'),
			E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:6px' }, cards)
		]));
	});

	return E('div', {}, blocks);
}

function statusText(st) {
	if (!st || st.updated == null)
		return _('Данных пока нет — нажмите «Обновить подписку».');

	var lines = [];
	lines.push(_('Режим: ') + modeName(st.mode));
	lines.push(_('Узлов в конфиге: ') + (st.nodes || 0));
	if (st.sections && st.sections.length) {
		st.sections.forEach(function (s) {
			lines.push('  ' + s.tag + ': ' + s.nodes + ' ' + _('узлов') + ', ' +
				s.domains + ' ' + _('доменов'));
		});
	}
	if (st.added && st.added.length)
		lines.push(_('Добавлены: ') + st.added.join(', '));
	if (st.removed && st.removed.length)
		lines.push(_('Убраны: ') + st.removed.join(', '));
	lines.push(_('Обновлено: ') + fmtTime(st.updated));
	lines.push(_('Xray: ') + (st.running ? _('работает') : _('остановлен')));
	return lines.join('\n');
}

// Как в shoulderkop: если пользователь всё-таки нажал штатное «Сохранить и
// применить», конфиг тоже пересобирается — событие uci-applied.
var appliedHooked = false;
var applying = false;

function hookAfterApply() {
	if (appliedHooked)
		return;
	appliedHooked = true;

	document.addEventListener('uci-applied', function () {
		fs.exec('/usr/bin/shoulderx', [ 'apply' ]).catch(function (e) {
			ui.addNotification(null, E('p', {}, _('Не удалось пересобрать конфиг: ') + errText(e)), 'error');
		});
	});
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('shoulderx'),
			runLoose([ 'status', '--json' ]).then(function (r) {
				try { return JSON.parse(r.stdout || '{}'); } catch (e) { return {}; }
			}),
			runLoose([ 'nodes', '--json' ]).then(function (r) {
				try { return JSON.parse(r.stdout || '{}'); } catch (e) { return {}; }
			})
		]);
	},

	// --- сервис: автозапуск и старт/стоп, как в podkop -----------------------

	serviceButtons: function (st) {
		var autoOn = !!st.autostart;
		var running = !!st.running;

		return E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:8px;align-items:center' }, [
			E('button', {
				'class': 'cbi-button ' + (autoOn ? 'cbi-button-negative' : 'cbi-button-positive'),
				'click': ui.createHandlerFn(this, 'handleAutostart', !autoOn)
			}, autoOn ? _('Выключить автозапуск') : _('Включить автозапуск')),
			E('button', {
				'class': 'cbi-button ' + (running ? 'cbi-button-negative' : 'cbi-button-positive'),
				'click': ui.createHandlerFn(this, 'handleService', running ? 'stop' : 'start')
			}, running ? _('Остановить') : _('Запустить')),
			E('span', { 'style': 'font-size:90%;color:#666' },
				_('автозапуск: ') + (autoOn ? _('включён') : _('выключен')) +
				_(' · xray: ') + (running ? (_('работает') + (st.pid ? (' (pid ' + st.pid + ')') : '')) : _('остановлен')))
		]);
	},

	refreshService: function () {
		var self = this;
		var node = document.getElementById('shoulderx-service');
		if (!node)
			return Promise.resolve();

		return runLoose([ 'state', '--json' ]).then(function (r) {
			var st = {};
			try { st = JSON.parse(r.stdout || '{}'); } catch (e) {}
			node.innerHTML = '';
			node.appendChild(self.serviceButtons(st));
		});
	},

	handleAutostart: function (on) {
		var self = this;
		return runLoose([ 'autostart', on ? 'on' : 'off' ]).then(function () {
			return wait(300);
		}).then(function () {
			return self.refreshService();
		});
	},

	handleService: function (action) {
		var self = this;
		return runLoose([ 'service', action ]).then(function () {
			return wait(600);
		}).then(function () {
			return self.refreshService();
		});
	},

	// --- остальные действия --------------------------------------------------

	// Применяем сразу при изменении поля: значение берём из самого виджета
	// (ev.target.value), поэтому не зависим от того, сохранился ли uci.
	// Ждём фоновую пересборку: опрашиваем `shoulderx job --json` и держим
	// модальное окно с индикатором, как при «Сохранить и применить».
	waitJob: function () {
		return new Promise(function (resolve) {
			var started = Date.now();
			var tick = function () {
				runLoose([ 'job', '--json' ]).then(function (r) {
					var j = {};
					try { j = JSON.parse(r.stdout || '{}'); } catch (e) { j = {}; }

					if (j.state === 'done' || j.state === 'idle')
						return resolve(j);

					ui.showModal(_('Пересобираем конфиг'), [
						E('p', { 'class': 'spinning' }, _('Применяю настройки…')),
						E('p', {}, (j.phase ? (_('шаг: ') + j.phase) : '')),
						E('p', { 'style': 'color:#777;font-size:90%' },
							_('Это может занять до минуты — ждём, пока узлы ответят.'))
					]);

					// страховка: не крутимся вечно
					if (Date.now() - started > 180000)
						return resolve(j);

					window.setTimeout(tick, 1500);
				}).catch(function () {
					window.setTimeout(tick, 2000);
				});
			};
			tick();
		});
	},

	applyNow: function (args) {
		var self = this;

		// одно применение за раз: смена режима + правка фильтра не должны
		// запускать два рестарта xray одновременно
		if (applying)
			return Promise.resolve();
		applying = true;

		ui.showModal(_('Пересобираем конфиг'), [
			E('p', { 'class': 'spinning' }, _('Применяю настройки…')),
			E('p', { 'style': 'color:#777;font-size:90%' }, _('Интерфейс временно недоступен.'))
		]);

		return run(args.concat([ '--async' ])).then(function () {
			return self.waitJob();
		}).then(function (j) {
			applying = false;
			ui.hideModal();
			return self.reloadForm().then(function () {
				return self.refreshAll();
			}).then(function () {
				if (j && j.rc && j.rc !== 0)
					ui.addNotification(null, E('p', {}, _('Пересобрано с ошибкой, код ') + j.rc), 'warning');
				else
					ui.addTimeLimitedNotification(null, E('p', {}, _('Готово: конфиг пересобран')), 3000, 'info');
			});
		}).catch(function (e) {
			applying = false;
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('Не удалось применить: ') + errText(e)), 'error');
		});
	},

	// Значения виджетов читаем напрямую: mode и фильтры групп узлов.
	// Штатный футер LuCI («Сохранить» / «Сохранить и применить») не нужен:
	// всё делает кнопка «Обновить подписку и применить».
	hideFooter: function () {
		var node = this.mapNode || document.getElementById('shoulderx-form');
		if (!node)
			return;
		var f = node.querySelectorAll('.cbi-page-actions');
		for (var i = 0; i < f.length; i++)
			f[i].style.display = 'none';
	},

	// Значение селекта режима берём прямо из DOM: LuCI отдаёт formvalue из своего
	// кэша uci, который на этой сборке не обновляется — из-за этого кнопка
	// применяла прежний режим.
	modeFromDom: function () {
		var sel = document.querySelectorAll('#shoulderx-form select');
		for (var i = 0; i < sel.length; i++) {
			for (var j = 0; j < sel[i].options.length; j++) {
				if (sel[i].options[j].value === 'lte')
					return sel[i].value;
			}
		}
		return null;
	},

	// Все текстовые поля строки, чей заголовок начинается с title
	fieldValues: function (title) {
		var rows = document.querySelectorAll('#shoulderx-form .cbi-value');
		for (var i = 0; i < rows.length; i++) {
			var t = rows[i].querySelector('.cbi-value-title');
			if (!t || t.textContent.trim().indexOf(title) !== 0)
				continue;
			var out = [];
			// не полагаемся на type="text": у части виджетов атрибута нет
			var inputs = rows[i].querySelectorAll('input');
			for (var k = 0; k < inputs.length; k++) {
				var t2 = (inputs[k].getAttribute('type') || 'text').toLowerCase();
				if (t2 !== 'text' && t2 !== 'url' && t2 !== 'search')
					continue;
				var v = (inputs[k].value || '').trim();
				if (v !== '' && out.indexOf(v) < 0)
					out.push(v);
			}
			return out;
		}
		return null;
	},

	formArgs: function () {
		var self = this;
		var args = [ 'apply' ];

		var mode = this.modeFromDom();
		if (!mode) {
			try {
				var o = self.map.lookupOption('mode', 'settings');
				mode = o ? o.formvalue('settings') : null;
			} catch (e) { mode = null; }
		}
		if (mode) args.push('--mode=' + (Array.isArray(mode) ? mode[0] : mode));

		// ссылки подписки — тоже из формы: иначе первое добавление (когда в uci
		// пусто) уходило в apply без адреса и падало
		var subs = this.fieldValues('Ссылки подписки');
		if (!subs || !subs.length) {
			// запасной путь: значение опции формы (DynamicList отдаёт массив)
			try {
				var so = self.map.lookupOption('subscription_url', 'settings');
				var sv = so ? so.formvalue('settings') : null;
				if (sv != null && sv !== '')
					subs = Array.isArray(sv) ? sv : [ sv ];
			} catch (e) { subs = null; }
		}
		if (subs) {
			for (var i = 0; i < subs.length; i++)
				args.push('--url=' + subs[i]);
		}

		[ [ 'Обход БС: группы узлов', '--lte-filter=' ],
		  [ 'Домашний интернет: группы узлов', '--wifi-filter=' ] ].forEach(function (p) {
			var v = self.fieldValues(p[0]);
			if (v && v.length) args.push(p[1] + v.join(','));
		});

		return args;
	},
	// После apply конфиг уже записан бэкендом, но LuCI держит свою копию uci
	// и показывает «Изменения: N». Перечитываем пакет и форму.
	reloadForm: function () {
		var self = this;
		var p = Promise.resolve();
		try {
			if (typeof uci.unload === 'function')
				p = p.then(function () { return uci.unload('shoulderx'); });
		} catch (e) {}
		return p.then(function () {
			return uci.load('shoulderx');
		}).then(function () {
			if (self.map && typeof self.map.load === 'function')
				return self.map.load();
		}).catch(function () { /* не критично */ });
	},

	// В этой сборке LuCI запись через rpcd может отбиваться (Access denied) —
	// сохранение формы необязательно, значения всё равно уезжают аргументами.
	saveQuiet: function () {
		try {
			var p = this.map.save();
			if (p && typeof p.catch === 'function')
				return p.catch(function () { return null; });
			return p;
		} catch (e) {
			return null;
		}
	},

	handleApply: function (rebuild) {
		var self = this;
		return Promise.resolve().then(function () {
			// 1) попытка записать форму в uci — не критично
			return self.saveQuiet();
		}).then(function () {
			// 3) пересобрать в фоне и дождаться: LuCI не держит долгий запрос
			ui.showModal(_('Обновляю подписку'), [
				E('p', { 'class': 'spinning' }, _('Скачиваю подписку и пересобираю конфиг…')),
				E('p', { 'style': 'color:#777;font-size:90%' }, _('Интерфейс временно недоступен.'))
			]);
			return run(self.formArgs().concat([ '--async' ]));
		}).then(function () {
			return self.waitJob();
		}).then(function (j) {
			ui.hideModal();
			self.hideFooter();
			return self.reloadForm().then(function () {
				return self.refreshAll();
			}).then(function () {
				if (j && j.rc && j.rc !== 0)
					ui.addNotification(null, E('p', {}, _('Обновлено с ошибкой, код ') + j.rc), 'warning');
				else
					ui.addTimeLimitedNotification(null, E('p', {}, _('Конфиг Xray пересобран')), 3000, 'info');
			});
		}).catch(function (e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('Не удалось обновить: ') + errText(e)), 'error');
		});
	},

	handleNodes: function () {
		return this.refreshNodes();
	},

	handleCheck: function (group) {
		var node = document.getElementById('shoulderx-check');
		if (!node)
			return;

		node.innerHTML = '';
		node.appendChild(E('p', {}, _('Проверяю сервисы…')));

		return runLoose([ 'check', '--json', '--group=' + group ]).then(function (r) {
			var d = {};
			try { d = JSON.parse(r.stdout || '{}'); } catch (e) { d = {}; }
			node.innerHTML = '';
			node.appendChild(checkTable(d));
		}).catch(function (e) {
			node.innerHTML = '';
			node.appendChild(E('p', {}, _('Ошибка проверки: ') + errText(e)));
		});
	},


	refreshAll: function () {
		var self = this;
		return Promise.all([ this.refreshStatus(), this.refreshNodes(), this.refreshService() ]).then(function () {
			self.refreshWarning();
		});
	},

	refreshStatus: function () {
		var node = document.getElementById('shoulderx-status');
		if (!node)
			return Promise.resolve();

		return runLoose([ 'status', '--json' ]).then(function (r) {
			var st = {};
			try { st = JSON.parse(r.stdout || '{}'); } catch (e) {}
			node.innerHTML = '';
			node.appendChild(E('pre', { 'style': 'white-space:pre-wrap;margin:0' }, statusText(st)));
			return st;
		});
	},

	refreshNodes: function () {
		var node = document.getElementById('shoulderx-nodes');
		if (!node)
			return Promise.resolve();

		node.innerHTML = '';
		node.appendChild(E('p', {}, _('Опрашиваю узлы…')));

		return runLoose([ 'nodes', '--json' ]).then(function (r) {
			var d = {};
			try { d = JSON.parse(r.stdout || '{}'); } catch (e) { d = {}; }
			node.innerHTML = '';
			node.appendChild(nodesPanel(d));
		}).catch(function (e) {
			node.innerHTML = '';
			node.appendChild(E('p', {}, _('Ошибка: ') + errText(e)));
		});
	},

	// Конфиг мог быть собран в другом режиме, чем выбран сейчас — предупреждаем.
	refreshWarning: function () {
		var node = document.getElementById('shoulderx-warn');
		if (!node)
			return;

		return runLoose([ 'status', '--json' ]).then(function (r) {
			var st = {};
			try { st = JSON.parse(r.stdout || '{}'); } catch (e) {}
			var uciMode = uci.get('shoulderx', 'settings', 'mode') || MODE_LTE;
			node.innerHTML = '';
			if (st.mode && st.mode !== uciMode) {
				node.appendChild(E('p', {
					'style': 'color:#b00020;font-weight:bold;margin:0 0 6px'
				}, _('Конфиг собран в режиме «') + modeName(st.mode) +
				   _('», а выбран «') + modeName(uciMode) +
				   _('» — нажмите «Обновить подписку».')));
			}
		});
	},

	render: function (data) {
		var st = data[1] || {};
		var nd = data[2] || {};
		var m, s, o;

		m = new form.Map('shoulderx', 'ShoulderX',
			_('Собирает конфиг Xray из подписки. Режим «Обход БС» — весь трафик в туннель, списки РКН напрямую; «Домашний интернет» — в туннель идут только домены секций yt и eu.'));

		this.map = m;

		s = m.section(form.NamedSection, 'settings', 'settings', _('Настройки'));

		o = s.option(form.DynamicList, 'subscription_url', _('Ссылки подписки'),
			_('Можно несколько — узлы всех активных складываются в один конфиг. Remnawave отдаёт Xray JSON только для Happ; если провайдер вернул заглушку («лимит устройств»), HWID задаётся в /etc/config/shoulderx.'));
		o.datatype = 'url';
		o.placeholder = 'https://sub.example.com/TOKEN';
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('Режим'),
			_('Меняется конфиг целиком: секции и правила собираются заново. После смены нажмите «Обновить подписку».'));
		// Номера в подписях держат порядок: LuCI сортирует варианты по тексту.
		o.value(MODE_LTE, _('1) Обход БС (lte) — весь LAN в туннель, списки РКН напрямую'));
		o.value(MODE_WIFI, _('2) Домашний интернет (wifi) — секции yt / eu в туннель, остальное напрямую'));
		o.default = MODE_LTE;


		o = s.option(form.Value, 'lte_filter', _('Обход БС: группы узлов'),
			_('Подстрока в имени группы, регистр не важен. По умолчанию «LTE» — в туннель идут только LTE-узлы.'));
		o.placeholder = 'LTE';
		o.default = 'LTE';
		o.depends('mode', MODE_LTE);


		o = s.option(form.Value, 'wifi_filter', _('Домашний интернет: группы узлов'),
			_('Подстрока в имени группы WiFi-узлов. По умолчанию «WiFi».'));
		o.placeholder = 'WiFi';
		o.default = 'WiFi';
		o.depends('mode', MODE_WIFI);


		// Кнопка — именно опцией формы: LuCI перерисовывает строки при смене
		// режима, и вставленный вручную DOM-элемент из строки пропадал.
		var self = this;
		o = s.option(form.Button, '_apply_btn', ' ');
		o.inputtitle = _('Обновить подписку и применить');
		o.inputstyle = 'apply';
		o.onclick = function () { return self.handleApply(); };

		o = s.option(form.Flag, 'geo', _('Маршрутизация по geo-файлам (RoscomVPN whitelist)'),
			_('Белые списки РФ идут напрямую, всё остальное — в туннель. Файлы geoip.dat/geosite.dat качаются через туннель при обновлении подписки.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'enable_schedule', _('Обновлять по расписанию'),
			_('cron: shoulderx apply --quiet.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.ListValue, 'update_interval', _('Период обновления'));
		[ '1h', '3h', '6h', '12h', '1d' ].forEach(function (v) { o.value(v, v); });
		o.default = '6h';
		o.depends('enable_schedule', '1');

		var warnNode = E('div', { 'id': 'shoulderx-warn', 'class': 'cbi-section' });

		var nodesNode = E('div', { 'id': 'shoulderx-nodes' }, nodesPanel(nd));
		var pingButton = E('div', { 'style': 'display:flex;justify-content:flex-end;margin:2px 0 4px' }, [
			E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, 'handleNodes')
			}, _('Пинг-тест'))
		]);
		var tilesBlock = E('div', { 'class': 'cbi-section' }, [ pingButton, nodesNode ]);

		var serviceNode = E('div', { 'id': 'shoulderx-service', 'class': 'cbi-section' },
			E('em', {}, _('Проверяю автозапуск и состояние xray…')));

		var statusNode = E('div', { 'id': 'shoulderx-status' },
			E('pre', { 'style': 'white-space:pre-wrap;margin:0' }, statusText(st)));

		var checkNode = E('div', { 'id': 'shoulderx-check', 'class': 'cbi-section' },
			E('p', {}, _('Проверка сервисов. Прокси-сервисы проверяются двумя путями — через туннель (как ходят клиенты) и напрямую; РФ-сервисы — только напрямую, через туннель они ходить не должны. «Маршрут» показывает, куда запрос отправит текущий конфиг.')));

		var checkActions = E('div', { 'class': 'cbi-page-actions' }, [
			E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, 'handleCheck', 'proxy')
			}, _('Тест прокси-сервисов (YouTube, Telegram, ChatGPT…)')),
			' ',
			E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, 'handleCheck', 'ru')
			}, _('Тест РФ-сервисов (Яндекс, ВК, Кинопоиск, RuTube…)')),
			' ',
			E('button', {
				'class': 'cbi-button',
				'click': ui.createHandlerFn(this, 'handleCheck', 'all')
			}, _('Всё сразу'))
		]);

		var diagBlock = E('details', { 'class': 'cbi-section' }, [
			E('summary', { 'style': 'cursor:pointer;font-weight:bold;padding:4px 0' },
				_('Диагностика (режим, секции, добавленные и убранные узлы)')),
			E('div', { 'style': 'padding:6px 0 0' }, [ statusNode ]),

		]);

		return m.render().then(function (mapNode) {
			// штатный футер формы (Save / Save & Apply) не нужен: применяет
			// кнопка-опция; CSS переживает перерисовку строк LuCI
			var formWrap = E('div', { 'id': 'shoulderx-form' }, [ mapNode ]);
			this.mapNode = mapNode;

			var root = E('div', {}, [
				E('style', {}, '#shoulderx-form .cbi-page-actions { display: none !important; }'),
				warnNode,
				tilesBlock,
				serviceNode,
				formWrap,
				checkActions,
				checkNode,
				diagBlock
			]);

			// как в podkop: небольшая задержка, затем проверка автозапуска и pid
			hookAfterApply();

			window.setTimeout(function () {
				this.hideFooter();
				this.refreshService();
				this.refreshWarning();
			}.bind(this), 400);

			return root;
		}.bind(this));
	},

	// Штатный футер формы (Reset / Save / Save & Apply) не нужен: всё делает
	// кнопка «Обновить подписку» — сохраняет, собирает конфиг и перезапускает xray.
	hideMapFooter: function () {
		if (!this.mapNode)
			return;
		var footers = this.mapNode.querySelectorAll('.cbi-page-actions');
		for (var i = 0; i < footers.length; i++)
			footers[i].style.display = 'none';
	},

	// Перенос кнопки «Обновить подписку» в строку селекта «Режим».
	// Ищем именно тот select, у которого есть option со значением lte —
	// так не зависим от внутренних id LuCI.
	moveApplyButton: function () {
		var holder = document.getElementById('shoulderx-apply-holder');
		if (!holder)
			return;

		var selects = document.querySelectorAll('select');
		for (var i = 0; i < selects.length; i++) {
			var sel = selects[i];
			var isMode = false;
			for (var j = 0; j < sel.options.length; j++) {
				if (sel.options[j].value === MODE_LTE) {
					isMode = true;
					break;
				}
			}
			if (!isMode)
				continue;

			var row = sel.closest ? sel.closest('.cbi-value') : null;
			var field = row ? row.querySelector('.cbi-value-field') : null;
			if (field) {
				holder.style.marginLeft = '8px';
				field.appendChild(holder);
				return;
			}
		}
	}
});
