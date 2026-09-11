// Обновления Jeff Browser: кнопка на панели + всплывающее уведомление.
// Сравнивает встроенную версию с манифестом на GitHub. Если вышла новая —
// зелёный значок на кнопке И одно уведомление (не спамит, раз на версию).

const CURRENT = "1.0";  // версия текущей сборки браузера
const MANIFEST_URL = "https://raw.githubusercontent.com/kerimlirashad/kerimlirashad/claude/icq-messenger-b0bt2n/jeff_browser/BROWSER_RELEASE.json";
const FALLBACK_PAGE = "https://github.com/kerimlirashad/kerimlirashad/releases/tag/jeffbrowser";

let downloadUrl = FALLBACK_PAGE;

async function check() {
  try {
    const r = await fetch(MANIFEST_URL + "?t=" + Date.now(), { cache: "no-store" });
    const d = await r.json();
    const latest = String(d.version || "").trim();
    downloadUrl = d.url || FALLBACK_PAGE;

    if (latest && latest !== CURRENT) {
      browser.browserAction.setBadgeText({ text: "!" });
      browser.browserAction.setBadgeBackgroundColor({ color: "#2ea043" });
      browser.browserAction.setTitle({ title: "Доступно обновление Jeff " + latest });

      // всплывающее уведомление — один раз на каждую новую версию
      const key = "notified_" + latest;
      const st = await browser.storage.local.get(key);
      if (!st[key]) {
        browser.notifications.create("jeff-update", {
          type: "basic",
          iconUrl: browser.runtime.getURL("icon.png"),
          title: "Jeff Browser — обновление " + latest,
          message: (d.notes || "Доступна новая версия.") + "\nНажмите, чтобы скачать."
        });
        await browser.storage.local.set({ [key]: true });
      }
    } else {
      browser.browserAction.setBadgeText({ text: "" });
      browser.browserAction.setTitle({ title: "Jeff Browser — актуальная версия (" + CURRENT + ")" });
    }
  } catch (e) { /* нет сети — тихо */ }
}

browser.browserAction.onClicked.addListener(() => browser.tabs.create({ url: downloadUrl }));
browser.notifications.onClicked.addListener(() => browser.tabs.create({ url: downloadUrl }));

check();
setInterval(check, 3 * 60 * 60 * 1000);  // перепроверка раз в 3 часа
