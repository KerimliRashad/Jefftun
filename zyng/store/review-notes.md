# Примечания для ревьюера

Поле **App Review Information → Notes** в App Store Connect.

Ревьюеру нужно за пару минут понять, что это, и суметь подключиться. Без
рабочего ключа он не сможет проверить приложение и отклонит его.

---

## Текст (вставь целиком, подставив свой ключ)

```
Zyng is a VPN client. It does not sell or provide VPN access itself — the user
supplies their own configuration key or subscription link from a provider they
already use.

HOW TO TEST

1. Launch the app and tap "Добавить ключ / подписку" (Add key / subscription)
2. Paste the test key below and tap "Добавить" (Add)
3. Tap the large power button on the main screen
4. Approve the system VPN prompt
5. The status changes to "Защищено" (Protected) and traffic is routed through
   the server. You can verify the IP address has changed at https://ifconfig.me

TEST KEY

<ВСТАВЬ СЮДА РАБОЧИЙ КЛЮЧ vless://... ИЛИ ССЫЛКУ-ПОДПИСКУ>

This key is valid and will remain active during review.

PRIVACY AND DATA

The app collects no data. There is no account, no registration, no analytics
and no third-party SDKs. Keys and settings are stored only in the app's local
storage on the device and are never transmitted anywhere.

The app makes network requests in exactly three cases:
- the VPN tunnel itself, to the server the user configured
- refreshing a subscription, to the URL the user added
- a latency check against public connectivity endpoints, to display response time

ENCRYPTION

The app uses only standard, publicly available encryption: TLS and open-source
VPN protocols (VLESS, VMESS, Trojan, Shadowsocks, Hysteria2, TUIC). No
proprietary or custom cryptography is implemented.

The tunnel is powered by sing-box, an open-source project distributed under the
GPLv3 licence: https://github.com/SagerNet/sing-box

CONTACT

kerimlicorp@gmail.com
```

---

## Про Guideline 5.4 (VPN Apps)

Правило требует, чтобы VPN-приложение:

- было подано **организацией**, а не индивидуальным разработчиком — если у
  тебя аккаунт Individual, это может стать поводом для отказа;
- явно объясняло, какие данные собирает и как использует;
- не продавало данные пользователей и не перенаправляло трафик третьим лицам
  без ведома пользователя.

Текст выше отвечает на второй и третий пункты.

**Первый пункт — риск, о котором стоит знать заранее.** Apple периодически
отклоняет VPN-приложения от аккаунтов типа Individual, требуя аккаунт
организации. Если это произойдёт, вариантов два: зарегистрировать юридическое
лицо и перевести аккаунт на Organization, либо оспорить решение, объяснив, что
приложение не предоставляет VPN-сервис, а является клиентом для ключей
пользователя.

Заранее ничего делать не нужно — возможно, вопрос не возникнет. Но если
отклонят именно по 5.4, причина будет в этом.

---

## Демо-аккаунт

Поля **Sign-in required** — оставь выключенным. Учётных записей в приложении
нет, ключ передаётся в Notes.
