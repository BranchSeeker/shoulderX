<p align="center">
  <a href="https://github.com/BranchSeeker/shoulderX/releases/latest"><img src="https://img.shields.io/github/v/release/BranchSeeker/shoulderX?label=release" alt="release"></a>
  <a href="https://github.com/BranchSeeker/shoulderX/actions/workflows/build.yml"><img src="https://github.com/BranchSeeker/shoulderX/actions/workflows/build.yml/badge.svg" alt="build"></a>
  <img src="https://img.shields.io/badge/OpenWrt-23.05%2B-blue" alt="OpenWrt">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

# shoulderX

Генератор конфига **Xray** для роутера из подписки — младший брат
[shoulderkop](https://github.com/BranchSeeker/shoulderkop).

shoulderkop раскладывает узлы по секциям podkop (sing-box). shoulderX делает
другое: собирает полноценный клиентский конфиг Xray (`/etc/xray/config.json`)
из той же подписки — с балансировщиками, секциями и маршрутизацией. В комплекте
`luci-app-shoulderx`: одна страница в LuCI, как у shoulderkop.

## Зачем

Проверено на живой ноде провайдера (VLESS + REALITY + gRPC, порт 8004):

| Клиент | Результат |
|---|---|
| Xray 26.x | туннель поднимается, трафик идёт |
| sing-box 1.14.3-extended | `connection upload handshake: closed pipe` |
| sing-box 1.14.4 (официальный) | таймаут |

Часть серверов провайдера **умеет только Xray**. podkop работает на sing-box,
поэтому такие ноды для него бесполезны. shoulderX держит туннель на Xray, а
podkop (если нужен) просто ходит в его socks-порт.

## Режимы и секции

| Режим | Что в туннель | Что напрямую |
|---|---|---|
| **Обход БС** (`lte`) | всё, один балансировщик `auto` | домены и подсети из списков РКН (`geosite.txt`/`geoip.txt`) |
| **Домашний интернет** (`wifi`) | домены секций `yt` и `eu`, у каждой свой балансировщик | всё остальное |

Секции в WiFi-режиме — как `skop_yt` / `skop_eu` в podkop:

* `yt` — **все** WiFi-узлы (РФ + EU): туда идёт только YouTube
  (`ext:geosite.dat:youtube`);
* `eu` — те же WiFi-узлы **без российских**: туда идёт всё остальное, что в РФ
  запрещено (всё, что не попало в whitelist), — то есть весь «запрещённый»
  интернет, кроме YouTube.

Белые списки РФ (домены и IP) идут напрямую, реклама/торренты/телеметрия
блокируются. Российские узлы в `eu` не попадают намеренно: зарубежные сервисы
такие адреса блокируют (ChatGPT отвечает 403), а РФ-сайты и так идут напрямую.
Узел считается российским, если в имени группы есть «Россия»/«Russia»/🇷🇺.

Списки allow-domains больше не используются — маршрут целиком на geo-файлах
RoscomVPN.

`russia_inside` в дефолт не входит намеренно: российские сервисы (Яндекс, ВК,
Кинопоиск, RuTube, Госуслуги, Ozon) должны открываться напрямую — через ноду они
только тратят трафик и часто не работают. А `geoblock` наоборот нужен: в нём
`openai.com`, `chatgpt.com`, `claude.ai`, `anthropic.com` — без туннеля они
отдают 403.

Списки берутся из [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains)
и кэшируются в `/etc/shoulderx/lists` на сутки. Списки РКН shoulderX не качает
заново — читает те, что уже лежат у shoulderkop.

## Балансировщики

Как в podkop, только средствами Xray: на каждую секцию — свой `balancer` со
стратегией `leastPing` плюс `observatory`, который раз в минуту проверяет все
узлы секции через `https://www.gstatic.com/generate_204`.

```json
"balancers": [
  { "tag": "yt", "selector": [ "yt" ], "strategy": { "type": "leastPing" }, "fallbackTag": "yt-1" },
  { "tag": "eu", "selector": [ "eu" ], "strategy": { "type": "leastPing" }, "fallbackTag": "eu-1" }
]
```

Селектор матчит outbound'ы по префиксу тега, поэтому узлы секции называются
`yt-1`, `yt-2`, `eu-1`, … Если в секции один узел, балансировщик не создаётся —
правило указывает прямо на outbound (иначе Xray не находит balancer и не
стартует).

## Синхронизация подписки

`shoulderx apply` каждый раз собирает конфиг **с нуля** из свежей подписки:

* новые серверы добавляются;
* серверы, которых больше нет в подписке, из конфига исчезают;
* в статусе видно, что именно изменилось (`added` / `removed`), это же
  показывается в LuCI.

Перед записью конфиг проверяется `xray run -test`. Если проверка не прошла,
остаётся прежний рабочий конфиг, а в консоль/LuCI уходит ошибка.

## Установка

Одной строкой на роутере (OpenWrt 23.05+, root):

```sh
wget -qO- https://github.com/BranchSeeker/shoulderX/releases/latest/download/shoulderx-install.sh | sh
```

Установщик сам:

1. проверяет платформу — OpenWrt, `DISTRIB_ARCH`, `apk` или `opkg`, место на диске;
2. ставит Xray нужной версии: бинарник под архитектуру из этого же релиза,
   иначе с upstream XTLS, иначе пакет из фида;
3. ставит пакеты `shoulderx` и `luci-app-shoulderx` (`.apk` для 24.10+/SNAPSHOT,
   `.ipk` для 23.x–24.10) со сверкой `SHA256SUMS`;
4. собирает конфиг: подписка напрямую → geo через туннель → туннель + tproxy.

```sh
# с подпиской и режимом сразу
wget -qO- https://github.com/BranchSeeker/shoulderX/releases/latest/download/shoulderx-install.sh \
  | sh -s -- --url='https://sub.example.com/TOKEN' --mode=lte
```

### Если GitHub недоступен

Установщик сам перебирает прокси-зеркала (`gh-proxy.com`, `ghfast.top`,
`ghproxy.net`) для пакетов и Xray. Сам скрипт можно взять через jsDelivr:

```sh
wget -qO- https://cdn.jsdelivr.net/gh/BranchSeeker/shoulderX@v0.3.3/installer/shoulderx-install.sh | sh
```

Своё зеркало (префикс к адресам GitHub):

```sh
… | sh -s -- --mirror=https://gh-proxy.com/
# или
SHOULDERX_MIRROR=https://gh-proxy.com/ sh shoulderx-install.sh
```

Флаги: `--mode=lte|wifi`, `--lte-filter=`, `--wifi-filter=`, `--no-tproxy`,
`--xray-from-upstream`, `--xray-from-feed`, `--no-apply`, `--dry-run`,
`--uninstall [--purge]`.

Вручную (если роутер без доступа к GitHub): скачать из релиза нужные пакеты,
положить на роутер и установить:

```sh
apk add --allow-untrusted ./shoulderx-*.apk ./luci-app-shoulderx-*.apk   # 24.10+
opkg install ./shoulderx_*.ipk ./luci-app-shoulderx_*.ipk                # 23.x–24.10
```

Порядок установки и инициализации — [docs/INSTALL.md](docs/INSTALL.md),
сборка и релиз — [docs/PACKAGING.md](docs/PACKAGING.md).

## Использование

```sh
shoulderx fetch                      # скачать подписку в /etc/shoulderx/sub.json
shoulderx list                       # что нашли, по секциям
shoulderx gen                        # собрать конфиг и показать сводку
shoulderx gen --write --restart      # записать и перезапустить xray
shoulderx apply                      # fetch + gen + write + restart
shoulderx lists                      # обновить списки доменов
shoulderx check                      # проверить сервисы (туннель + напрямую)
shoulderx nodes                      # плитки серверов из конфига: пинг + выбранный
shoulderx status                     # режим, секции, что добавлено/убрано
```

Флаги `gen`:

```
--mode=lte|wifi         какие секции собирать (по умолчанию из uci)
--socks-port=20180      порт socks-инбаунда
--http-port=0           порт HTTP-прокси (0 — не поднимать)
--domains=FILE          список доменов РКН (по умолчанию geosite.txt)
--ips=FILE              список подсетей РКН (по умолчанию geoip.txt)
--no-lists              не добавлять правила из списков
--refresh-lists         перекачать списки сообщества
--out=FILE              куда писать (по умолчанию /etc/xray/config.json)
--write                 записать (без флага только сводка)
--json                  напечатать готовый конфиг в stdout
```

## Проверка сервисов

`shoulderx check` — одна команда, чтобы увидеть, что реально работает и каким
путём идёт трафик:

```
$ shoulderx check --group=proxy
[ok]  YouTube   www.youtube.com   маршрут: tunnel  туннель: 200/534мс  напрямую: 000/7003мс
[ok]  Telegram  web.telegram.org  маршрут: tunnel  туннель: 200/912мс  напрямую: 200/970мс
...
$ shoulderx check --group=ru
[ok]  Яндекс  ya.ru  маршрут: direct  туннель: 000/7006мс  напрямую: 302/483мс
```

Каждый сервис проверяется **двумя путями** — через туннель (socks Xray, как
ходят клиенты) и напрямую, — а колонка «Маршрут» показывает, куда его отправит
текущий конфиг (совпадение с правилами `domain:` в `/etc/xray/config.json`).
Запросы идут параллельно, общий бюджет — один таймаут (7 с).

Группы: `--group=proxy` (YouTube, Telegram, ChatGPT, Instagram, X, Discord),
`--group=ru` (Яндекс, ВК, Кинопоиск, RuTube, Госуслуги, Ozon), `--group=all`.
`--json` — машинный вывод для LuCI.

Типичная картина «всё наоборот» сразу видна: у прокси-сервисов `туннель: 200`, а
`напрямую: 000`; у российских — наоборот.

## Плитки серверов

`shoulderx nodes` показывает узлы, которые сейчас лежат в конфиге, по секциям:

```
секция yt (2):
  [*] yt-1     ru01.example.net:443      tcp+reality      47мс
  [ ] yt-2     ru02.example.net:443      grpc+reality     98мс
секция eu (19):
  [ ] eu-1     203.0.113.10:443          grpc+reality     44мс
  ...
  [*] eu-19    203.0.113.25:443          tcp+reality      60мс
```

* `[*]` — узел, который балансировщик выбрал **прямо сейчас**. Данные берутся из
  самого Xray: `xray api bi` (для этого в конфиг добавляется локальный API на
  `127.0.0.1:20190`, `option api_port`).
* «Пинг» — время TCP-подключения к узлу (DNS + connect), запросы идут
  параллельно; `—` значит, что узел не отвечает.
* В LuCI это плитки: под каждой секцией карточки с тегом, адресом, транспортом и
  задержкой, выбранный узел подсвечен зелёным.

## LuCI

**Сервисы → ShoulderX**: ссылка подписки, HWID, режим, списки секций `yt`/`eu`,
порты, расписание обновления, кнопки «Обновить подписку», «Обновить списки»,
«Пересобрать конфиг» и блок статуса (режим, секции, добавленные/убранные узлы).

## Если подписка не скачивается

Провайдер (Remnawave) отдаёт Xray JSON только клиенту Happ и привязывает конфиг
к устройству по заголовку `x-hwid`. Отсюда две типовые ошибки:

| Сообщение | Что делать |
|---|---|
| `curl не установлен (apk add curl)` | поставить `curl` (пакет объявлен в зависимостях, на живой системе он есть) |
| `провайдер вернул заглушку: устройство с hwid … не зарегистрировано` | исчерпан лимит устройств в подписке. Либо удалить лишнее устройство в кабинете/боте провайдера, либо вписать в поле **HWID** hwid уже зарегистрированного устройства (Happ: Настройки → о приложении) |

Хороший ответ — это JSON на 20–30 КБ; заглушка — 280–536 байт (base64 от
`vless://00000000-…@0.0.0.0:1`). Заглушкой кэш не затирается: остаётся прежний
рабочий конфиг.

Пустой HWID — shoulderX берёт MAC роутера (12 hex). Это отдельное устройство для
провайдера, поэтому на новом роутере он может не пройти, пока не освободится
слот.

## Маршрутизация по geo-файлам (RoscomVPN)

С `option geo '1'` shoulderX собирает правила по профилю **WHITELIST** из
[hydraponique/roscomvpn-routing](https://github.com/hydraponique/roscomvpn-routing):

| правило | куда |
|---|---|
| `ext:geosite.dat:win-spy`, `torrent`, `category-ads` | block |
| `ext:geosite.dat:private`, `ext:geosite.dat:whitelist` | direct |
| `ext:geoip.dat:private`, `ext:geoip.dat:whitelist` | direct |
| остальное | балансировщик (туннель) |

Файлы `geoip.dat` / `geosite.dat` лежат в `/usr/share/xray` и обновляются
командой `shoulderx geo` (или автоматически в `apply`, если старше
`geo_ttl`, по умолчанию неделя). **Качаются только через туннель** — напрямую
jsDelivr из РФ недоступен, поэтому `apply` сначала поднимает bootstrap-конфиг.

Порядок установки и инициализации целиком — [docs/INSTALL.md](docs/INSTALL.md):

1. подписка качается **напрямую**;
2. geo-файлы — **через прокси**;
3. затем поднимается полный туннель с маршрутизацией и tproxy.

## Связка с podkop

podkop умеет ходить в socks-прокси как в обычный outbound:

```sh
uci set podkop.skop_lte.connection_type='proxy'
uci set podkop.skop_lte.proxy_config_type='outbound'
uci set podkop.skop_lte.outbound_json='{"type":"socks","server":"127.0.0.1","server_port":20180}'
uci commit podkop && /etc/init.d/podkop restart
```

Тогда podkop остаётся маршрутизатором (nft, tproxy, DNS, списки), а туннель
держит Xray. Проверено на Cudy WR3000U: LAN → podkop → socks → Xray → нода.

## Проверено

Виртуальный OpenWrt 25.12.6 (x86_64), xray-core 26.10.21, реальная подписка:

```
# обход БС
shoulderx gen --mode=lte --http-port=20181 --write
  секция auto: узлов 1
xray run -test -c /etc/xray/config.json        → Configuration OK
http_proxy=http://127.0.0.1:20181 wget -qO- http://ip-api.com/line/?fields=query
  → 198.51.100.7                              (выход ноды node.example.net:8443)

# домашний интернет
shoulderx gen --mode=wifi --write
  секция yt: узлов 2, доменов 18
  секция eu: узлов 2, доменов 1479
  → xray run -test: Configuration OK, balancers yt/eu на месте
```

## Состояние

- [x] разбор подписки (Xray JSON), отсев заглушек, дубликатов и битых REALITY-узлов
- [x] режимы `lte` / `wifi`, секции `yt` и `eu`
- [x] балансировщики `leastPing` + `observatory` на каждую секцию
- [x] списки: РКН от shoulderkop + сообщество allow-domains с кэшем
- [x] синхронизация: добавленные/удалённые узлы, отчёт в статусе
- [x] валидация `xray run -test` перед записью
- [x] LuCI: страница, меню, ACL
- [ ] tproxy-инбаунд (автономный режим без podkop)
- [ ] предварительная проба узлов перед записью (чтобы в конфиг не попадали мёртвые)
- [ ] сборка пакетов в CI и релизы

## Отличия от shoulderkop

| | shoulderkop | shoulderX |
|---|---|---|
| движок | sing-box (podkop) | Xray |
| результат | секции `skop_*` в uci | `/etc/xray/config.json` |
| режимы | lte / wifi | lte / wifi (секции yt, eu) |
| списки | качает сам | РКН — от shoulderkop, сообщество — сам |
| зачем | «плечо» для podkop | обход ограничений sing-box на REALITY |
