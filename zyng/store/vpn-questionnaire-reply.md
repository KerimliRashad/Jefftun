# Ответ на автоматический запрос Apple по VPN

Отказ **2.1.0 Performance: App Completeness** с таким письмом — не отказ по
существу. Это стандартный запрос, который Apple шлёт всем приложениям с
VPN-функциональностью. Нужно письменно ответить на три вопроса, и ревью
продолжится.

Текст надо вставить **в двух местах**:

1. **Reply to App Review** — ответом на само сообщение
2. **App Information → App Review Information → Notes** — то же самое, туда же
   добавить рабочий ключ

---

## Текст ответа (копируй целиком)

```
Thank you for your questions regarding the VPN functionality.

1) WHAT USER INFORMATION IS THE APP COLLECTING USING VPN?

None. The app collects no user information whatsoever through the VPN or
otherwise.

Zyng is a VPN client, not a VPN service. It does not operate any servers. The
user supplies their own configuration key or subscription link obtained from a
provider they already use, and the app establishes a tunnel to that server
using the standard iOS NetworkExtension framework.

The app has no account system, no registration, no login, no analytics SDK, no
advertising SDK and no third-party SDKs of any kind. It has no backend of its
own to send data to.

Specifically, the app does not collect, log, read or store:
- browsing history or visited domains
- DNS queries
- traffic contents of any kind
- IP addresses
- session times or connection history
- device identifiers for tracking purposes

2) FOR WHAT PURPOSES ARE YOU COLLECTING THIS INFORMATION?

Not applicable — no information is collected.

The only data the app stores is what the user enters themselves: their
configuration keys and subscription URLs, plus which server they last selected.
This is kept exclusively in the app's local storage on the device, is never
transmitted anywhere, and is deleted when the app is deleted.

3) WILL THE DATA BE SHARED WITH ANY THIRD PARTIES?

No. No data is shared with anyone, because none is collected.

For completeness, the app makes network requests in exactly three situations,
all initiated by the user's own configuration:

- The VPN tunnel itself, to the server whose key the user added.
- Refreshing a subscription: an HTTPS request to the subscription URL the user
  added, to retrieve the current server list. This goes directly from the
  device to that provider.
- Latency measurement: a short request to the selected server's address and
  port, and to public connectivity-check endpoints (such as Apple's network
  check page), solely to display response time. These requests carry no user
  information.

ADDITIONAL INFORMATION

The tunnel is implemented with sing-box, an open-source project distributed
under GPLv3: https://github.com/SagerNet/sing-box

The app uses only standard, publicly available encryption: TLS and open
protocols (VLESS, VMESS, Trojan, Shadowsocks, Hysteria2, TUIC). No proprietary
cryptography is implemented.

Our privacy policy is available at https://zyng.online/privacy.html

HOW TO TEST

1. Launch the app and tap "Добавить ключ / подписку" (Add key / subscription).
2. Paste the test key below and tap "Добавить" (Add).
3. Tap the large power button on the main screen.
4. Approve the system VPN permission prompt.
5. The status changes to "Защищено" (Protected). You can confirm the traffic is
   routed by checking that the IP address has changed at https://ifconfig.me

TEST KEY

<ВСТАВЬ СЮДА РАБОЧИЙ КЛЮЧ vless://... ИЛИ ССЫЛКУ-ПОДПИСКУ>

This key is valid and will remain active throughout the review.

Contact: kerimlicorp@gmail.com
```

---

## Что делать по шагам

1. На странице отказа нажми **Reply to App Review**
2. Вставь текст выше, подставив вместо `<ВСТАВЬ СЮДА...>` рабочий ключ
3. Отправь
4. Открой **App Information** → прокрути до **App Review Information** →
   в поле **Notes** вставь тот же текст
5. **Save**
6. Вернись в **Distribution** и нажми **Update Review** (или
   **Add for Review** → **Submit**)

Пересобирать и заново загружать приложение **не нужно** — сборка уже у них,
не хватало только ответа.

---

## Почему ключ обязателен

Ревьюер должен своими руками увидеть, что VPN подключается. Без рабочего ключа
он не сможет пройти дальше первого экрана и отклонит снова — уже по существу,
а не автоматически.

Ключ должен оставаться живым всё время проверки, это обычно несколько дней.
