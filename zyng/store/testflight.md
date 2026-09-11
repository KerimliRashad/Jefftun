# TestFlight — ссылка для тестировщиков

Две разные штуки, не путай:

| | Внутреннее тестирование | Публичная ссылка |
|---|---|---|
| Сколько людей | до 100 | до 10 000 |
| Проверка от Apple | **не нужна** | **нужна** (Beta App Review) |
| Как приглашать | по Apple ID вручную | одна ссылка, любому |
| Когда заработает | сразу, минут через 10 | через 1–2 дня после ревью |

Если тестировать будут пара друзей — делай внутреннее, оно мгновенное.
Если хочешь ссылку «для всех» — раздел ниже про публичную.

---

## Шаг 0. Загрузить сборку (нужно для обоих вариантов)

В Xcode:

1. Вверху рядом с ▶︎ выбери **Any iOS Device (arm64)** вместо симулятора
2. **Product → Archive** (ждать 3–10 минут)
3. Откроется Organizer → **Distribute App** → **App Store Connect** → **Upload**
4. Дальше «Next» до конца, в конце **Upload**

Потом в App Store Connect → твоё приложение → вкладка **TestFlight**.
Сборка появится со статусом «Обрабатывается» (Processing) — это 10–30 минут.
Когда обработается, рядом появится жёлтый треугольник «Missing Compliance».

5. Нажми на него → вопрос про шифрование → отвечай как при обычной отправке
   (VPN использует шифрование, но подпадает под исключение для стандартных
   протоколов)

---

## Вариант А. Внутреннее тестирование — работает сразу

Внутренний тестировщик должен быть пользователем твоего аккаунта разработчика.

1. App Store Connect → **Users and Access** → **+**
2. Впиши имя и **Apple ID друга** (тот email, на который у него зарегистрирован
   Apple ID — это важно, на другой не придёт)
3. Роль — **Developer** или **Marketing**, обе годятся
4. Галочка **Access to TestFlight** (Доступ к TestFlight)
5. Друг получит письмо-приглашение в команду, должен его принять

Дальше:

6. Вкладка **TestFlight** → слева **Internal Testing** → **+** рядом с группой
7. Создай группу, например `Друзья`
8. Добавь в неё людей и добавь сборку

Другу приходит письмо от TestFlight. Он ставит приложение **TestFlight** из App
Store, открывает письмо с телефона → **View in TestFlight** → **Install**.

Ревью Apple тут не нужно совсем.

---

## Вариант Б. Публичная ссылка

Ссылка выглядит так: `https://testflight.apple.com/join/XXXXXXXX`
Её можно кинуть в Telegram, и любой поставит приложение.

### Сначала заполни Test Information

Без этого Apple не примет сборку на бета-ревью.

TestFlight → слева внизу **Test Information**:

- **Beta App Description** — текст ниже, готовый
- **Feedback Email** — `kerimlicorp@gmail.com`
- **Privacy Policy URL** — `https://zyng.online/privacy.html`
- **Contact Information** — имя, фамилия, email, телефон

### Потом создай внешнюю группу

1. TestFlight → слева **External Testing** → **+** → назови `Публичная бета`
2. Внутри группы включи **Enable Public Link**
3. Ограничь число тестировщиков, если хочешь (можно оставить 10 000)
4. **Добавь сборку в группу** — вот в этот момент и уходит запрос на
   **Beta App Review**

### Ждать

Beta App Review — от нескольких часов до двух дней. Оно мягче обычного ревью, но
это всё равно проверка живым человеком.

Когда одобрят, в группе появится сама ссылка — копируй и раздавай.

---

## Готовый текст: Beta App Description

Вставь в поле **Beta App Description**.

```
Zyng — VPN-клиент для тех, у кого уже есть ключ или ссылка-подписка от своего
провайдера. Само приложение доступ к VPN не продаёт и не предоставляет.

ЧТО ПРОВЕРИТЬ

• Добавление ключа и ссылки-подписки
• Подключение большой кнопкой на главном экране
• Смену IP-адреса — открой https://ifconfig.me при включённом VPN
• Пинг серверов в списке
• Таймер сессии: свернуть приложение на минуту и открыть снова
• Live Activity на экране блокировки
• Переключатель в Пункте управления (iOS 18 и новее)

ЧТО ПРИСЛАТЬ, ЕСЛИ ЧТО-ТО НЕ РАБОТАЕТ

Модель iPhone, версию iOS, название сервера и что именно произошло.
Скриншот сильно помогает. Ключ присылать не нужно — он личный.
```

Английский вариант, если понадобится:

```
Zyng is a VPN client for people who already have a configuration key or a
subscription link from their own provider. The app itself neither sells nor
provides VPN access.

WHAT TO TEST

• Adding a key and a subscription link
• Connecting with the main power button
• That the IP address changes — open https://ifconfig.me while connected
• Server latency in the list
• The session timer: background the app for a minute, then reopen it
• The Live Activity on the Lock Screen
• The Control Center toggle (iOS 18 and later)

IF SOMETHING BREAKS

Send the iPhone model, iOS version, the server name and what happened.
A screenshot helps a lot. No need to send your key — it is private.
```

---

## Важно про статус аккаунта

Beta App Review — это тоже проверка человеком, и **Guideline 5.4 там тоже
применяется**: VPN-приложения требуют аккаунта Organization. Аккаунт пока
Individual, конвертация не завершена, поэтому публичную ссылку могут отклонить
по той же причине, что и обычную отправку.

Внутреннее тестирование (вариант А) этой проверки не проходит вообще — оно
работает при любом статусе аккаунта. Поэтому пока конвертация не закончилась,
надёжный путь — вариант А.
