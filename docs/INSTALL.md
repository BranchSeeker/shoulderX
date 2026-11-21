# shoulderX: установка и инициализация на роутере

Порядок важен: каждый следующий шаг опирается на предыдущий. Эти же три шага
выполняет `shoulderx apply` — команда идемпотентна, её можно запускать повторно.

## Установка одной строкой

```sh
wget -qO- https://github.com/BranchSeeker/shoulderX/releases/latest/download/shoulderx-install.sh | sh
```

Установщик делает шаги 0–3 сам: проверяет платформу, ставит Xray (бинарник из
релиза под архитектуру), ставит пакеты, настраивает подписку и собирает конфиг.
Флаги: `--url=`, `--mode=lte|wifi`, `--lte-filter=`, `--wifi-filter=`,
`--no-tproxy`, `--xray-from-upstream`, `--xray-from-feed`, `--mirror=`,
`--dry-run`, `--uninstall [--purge]`.

Если GitHub недоступен, установщик перебирает прокси-зеркала сам
(`gh-proxy.com`, `ghfast.top`, `ghproxy.net`), а сам скрипт берётся через
jsDelivr:

```sh
wget -qO- https://cdn.jsdelivr.net/gh/BranchSeeker/shoulderX@v0.3.3/installer/shoulderx-install.sh | sh
```

Дальше — ручной путь, если ставить по шагам.

## Шаг 0. Что нужно на роутере

* OpenWrt 24.10+ (проверено на 25.12.6), `ucode`, `curl`, `ca-bundle`, `nft`;
* `xray-core` (пакет из фида: `apk add xray-core`);
* свободное место ~5 МБ (geo-файлы + кэш подписки).

Файлы пакета:

```
/usr/bin/shoulderx                     CLI
/usr/lib/shoulderx/{main,xray,lists,fetch}.uc
/usr/lib/shoulderx/tproxy.sh           nft-правила прозрачного прокси
/etc/init.d/shoulderx                  сборка конфига при загрузке + cron-сторож
/etc/config/shoulderx                  настройки
```

## Шаг 1. Подписка — НАПРЯМУЮ

Подписка Remnawave скачивается **без туннеля**: домен провайдера доступен и так,
а туннеля на этом шаге ещё нет.

```sh
uci set shoulderx.settings.subscription_url='https://sub.example.com/TOKEN'
uci commit shoulderx
shoulderx fetch
```

* нужен UA `Happ/2.7.0` и заголовок `x-hwid` (12 hex из MAC роутера или свой);
* провайдер ограничивает число устройств по hwid: заглушка («Подписка не
  активна» / `0.0.0.0:1`) означает, что устройство не зарегистрировано;
* если напрямую не вышло, `apply` повторяет попытку через уже поднятый туннель.

Результат: `/etc/shoulderx/sub.json` — массив Xray-конфигов из подписки.

## Шаг 2. geo-файлы — ЧЕРЕЗ ПРОКСИ

Маршрутизация строится на файлах [RoscomVPN](https://github.com/hydraponique/roscomvpn-routing):

```
geoip.dat    https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip/release/geoip.dat
geosite.dat  https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/geosite.dat
```

Качаются **только через туннель** — напрямую jsDelivr из РФ часто недоступен.
Поэтому сначала поднимается *bootstrap*-конфиг (весь трафик в туннель, без
geo-правил), а уже через его socks скачиваются файлы:

```sh
shoulderx gen --write --restart --no-geo   # bootstrap: всё в туннель
shoulderx geo                              # качает geo через socks
```

Файлы кладутся в `/usr/share/xray` (туда смотрит `XRAY_LOCATION_ASSET` из
init-скрипта xray-core) и подменяются атомарно: `*.new` → `mv`, чтобы неудачная
загрузка не сломала рабочий конфиг.

## Шаг 3. Полный туннель с маршрутизацией

Собирается конфиг с правилами RoscomVPN (профиль **WHITELIST**):

| Правило | Куда |
|---|---|
| `ext:geosite.dat:win-spy`, `torrent`, `category-ads` | `block` |
| `ext:geosite.dat:private`, `ext:geosite.dat:whitelist` | `direct` |
| `ext:geoip.dat:private`, `ext:geoip.dat:whitelist` | `direct` |
| всё остальное (`network: tcp,udp`) | балансировщик → туннель |

```sh
uci set shoulderx.settings.geo='1'
uci commit shoulderx
shoulderx apply          # подписка → geo (если нужно) → конфиг → tproxy
```

Дальше включается прозрачный прокси для LAN (`/etc/lib/shoulderx/tproxy.sh`):
nft-правила + policy routing, DNS-запросы клиентов уходят в туннель
(`dnsmasq → 127.0.0.1#5353 → 1.1.1.1` через прокси), IPv6 в LAN на время работы
выключается, чтобы трафик не обходил tproxy.

## Проверка

```sh
shoulderx check        # тест сервисов: туннель и напрямую
shoulderx nodes        # узлы и выбранный балансировщиком
shoulderx status       # режим, секции, что изменилось
shoulderx tproxy status
```

Ожидаемое поведение после шага 3:

* `ya.ru`, `vk.com`, `gosuslugi.ru` → **direct** (по whitelist), 200–600 мс;
* `youtube.com`, `chatgpt.com`, `x.com`, `discord.com` → **туннель**, 200;
* `nslookup www.youtube.com` на роутере отдаёт IPv4-адреса (а не NXDOMAIN).

## Откат

```sh
shoulderx tproxy stop     # снять правила, вернуть DNS/IPv6/flow-offload
shoulderx geo             # перекачать geo
shoulderx service stop    # остановить xray (tproxy снимется автоматически)
```

Состояние роутера целиком: `tar czf /root/shoulderx-state.tar.gz /etc/config/shoulderx
/etc/xray/config.json /etc/shoulderkop/lists /usr/lib/shoulderx`.
