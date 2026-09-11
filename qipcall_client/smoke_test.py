"""Проверка запуска Zyng без графики.

Подменяет tkinter и customtkinter заглушками и прогоняет сборку интерфейса:
создание окна во всех темах и языках, экран настроек, список серверов с
данными и сборку конфигов xray.

Настоящего окна не появится, но именно так ловятся ошибки, из-за которых
собранный exe запускается и молча закрывается. Запускать перед релизом:

    python smoke_test.py

"""

import os, sys, types, traceback, json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

class W:
    """Заглушка виджета: принимает что угодно, делает ничего."""
    def __init__(self, *a, **kw): self._kw = kw
    def __getattr__(self, name):
        if name.startswith("__"): raise AttributeError(name)
        return W._noop
    @staticmethod
    def _noop(*a, **kw): return W()
    def __getitem__(self, k): return {"width": 190, "height": 34}.get(k, 100)
    def __setitem__(self, k, v): pass
    def __iter__(self): return iter(())
    def winfo_children(self): return []
    def winfo_width(self): return 300
    def get(self, *a, **k): return ""
    def cget(self, *a, **k): return ""

def _mk(name): return type(name, (W,), {})

tk = types.ModuleType("tkinter")
for n in ("Canvas","Label","Frame","Tk","Toplevel","StringVar","PhotoImage","Menu"):
    setattr(tk, n, _mk(n))
mb = types.ModuleType("tkinter.messagebox")
mb.showinfo = mb.showerror = mb.askyesno = lambda *a, **k: True
tk.messagebox = mb
sys.modules["tkinter"] = tk; sys.modules["tkinter.messagebox"] = mb

ctk = types.ModuleType("customtkinter")
for n in ("CTk","CTkFrame","CTkLabel","CTkButton","CTkOptionMenu","CTkScrollableFrame",
          "CTkFont","CTkImage","CTkSwitch","CTkToplevel","CTkInputDialog","CTkEntry",
          "CTkTextbox","CTkProgressBar","CTkSegmentedButton"):
    setattr(ctk, n, _mk(n))
ctk.StringVar = _mk("StringVar")
ctk.set_appearance_mode = lambda *a, **k: None
ctk.set_default_color_theme = lambda *a, **k: None
ctk.get_appearance_mode = lambda: "Dark"
sys.modules["customtkinter"] = ctk

sys.argv = ["qipcall.py"]
import qipcall
print("  импорт модуля: ок")

fails = 0
for theme in ("dark","light","black","system"):
    for lang in ("ru","en"):
        qipcall.apply_lang(lang); qipcall.apply_theme(theme)
        try:
            qipcall.ZyngApp(W())
        except Exception:
            print(f"  ✗ ПАДЕНИЕ: тема={theme} язык={lang}")
            traceback.print_exc(); fails += 1; break
    if fails: break
if not fails:
    print("  создание окна во всех темах и языках: ок")

qipcall.apply_theme("dark"); qipcall.apply_lang("ru")
try:
    app = qipcall.ZyngApp(W())
    for name in ("render_tabs","render_servers","open_settings","_about","_faq","_stats"):
        getattr(app, name)()
    print("  настройки, список серверов, диалоги: ок")
except Exception:
    print("  ✗ ПАДЕНИЕ на экранах"); traceback.print_exc(); fails += 1

# ── С реальными данными ──────────────────────────────────────────────────────
app = qipcall.ZyngApp(W())
app.links = [
    "vless://11111111-2222-3333-4444-555555555555@de.example.com:443?type=xhttp&security=reality&pbk=AAA&sid=01&sni=a.com#%F0%9F%87%A9%F0%9F%87%AA%20Germany",
    "vless://11111111-2222-3333-4444-555555555555@nl.example.com:443?type=ws&path=/x&security=tls#Netherlands",
    "vmess://eyJhZGQiOiJydS5leGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6IjExMTExMTExLTIyMjItMzMzMy00NDQ0LTU1NTU1NTU1NTU1NSIsIm5ldCI6ImdycGMiLCJwcyI6IlJVIn0=",
    "trojan://pass@fr.example.com:443?type=httpupgrade&path=/u#France",
    "ss://YWVzLTI1Ni1nY206cGFzcw==@us.example.com:8388#USA",
    "hysteria2://pass@fi.example.com:443?sni=f.com#Finland",
    "tuic://uuid:pass@se.example.com:443#Sweden",
]
app.pings = {0: 42, 1: 180, 2: 900, 3: None, 4: "…", 5: "x"}
app.selected_idx = 1
app.subs = [{"url": "https://sub.example.com/x", "title": "Моя подписка"}]
app.sub_info = {"traffic": "10 GB / ∞", "expire": "до 2027"}
app.active_tab = "https://sub.example.com/x"
try:
    app.render_servers()
    app._update_current("Germany")
    app._flash("тест")
    for ms in (42, 180, 900, None, "…", "x"):
        app._ping_text(ms)
    print("  список из 7 серверов, все протоколы: ок")
except Exception:
    print("  ✗ ПАДЕНИЕ на данных"); traceback.print_exc(); sys.exit(1)

# Сборка конфигов — то, что уходит в xray
built = 0
for ln in app.links:
    try:
        ob = qipcall.parse_link(ln)
    except ValueError:
        continue          # hysteria2/tuic идут через sing-box, это не ошибка
    except Exception:
        print(f"  ✗ разбор упал: {ln[:45]}"); traceback.print_exc(); sys.exit(1)
    try:
        cfg = qipcall.build_xray_config(ob, app.prefs)
        st = cfg["outbounds"][0].get("streamSettings", {})
        net = st.get("network", "tcp")
        key = {"xhttp":"xhttpSettings","ws":"wsSettings","grpc":"grpcSettings",
               "httpupgrade":"httpupgradeSettings","h2":"httpSettings"}.get(net)
        if key and key not in st:
            print(f"  ✗ {net}: нет блока {key} — xray получит конфиг без транспорта"); sys.exit(1)
        built += 1
    except SystemExit: raise
    except Exception:
        print(f"  ✗ конфиг не собрался: {ln[:45]}"); traceback.print_exc(); sys.exit(1)
print(f"  конфиги xray ({built} ключа), транспорты на месте: ок")

# ── Плашка обновления ────────────────────────────────────────────────────────
# Она показывается редко — только когда вышла новая версия, — поэтому ломается
# незаметно и живёт сломанной до следующего релиза. Проверяем на каждом прогоне.
app._show_update("9.9.9", "Тестовое описание изменений")
assert app.update_bar is not None, "плашка обновления не появилась"
app._hide_update()
assert app.update_bar is None, "плашка обновления не закрывается"
app._show_update("9.9.9", "")
app._hide_update()
print("  плашка обновления: ок")

# ── Разбор адреса для замера задержки ────────────────────────────────────────
cases = [
    ("vless://uuid@example.com:443?type=tcp#N", "example.com", 443),
    ("trojan://pass@t.example.org:8443#N", "t.example.org", 8443),
]
for link, host, port in cases:
    h, p = qipcall.link_host_port(link)
    assert (h, p) == (host, port), (link, h, p)

import base64 as _b64
inner = _b64.urlsafe_b64encode(b"aes-256-gcm:secret@ss.example.net:8388").decode().rstrip("=")
h, p = qipcall.link_host_port("ss://" + inner + "#Node")
assert (h, p) == ("ss.example.net", 8388), ("ss base64", h, p)
print("  адреса для пинга, включая ss:// в base64: ок")

# ── Проверка прохождения трафика ─────────────────────────────────────────────
# Она превращает «подключено, но ничего не грузится» в понятное сообщение,
# поэтому её собственная поломка была бы особенно обидной.
ok, why = qipcall._proxy_works(1, timeout=2)
assert ok is False and why, "проверка трафика должна сообщать причину"

import socket as _sk, threading as _th
_srv = _sk.socket(); _srv.bind(("127.0.0.1", 0)); _srv.listen(1)
_port = _srv.getsockname()[1]
def _fake():
    c, _ = _srv.accept()
    c.recv(3); c.sendall(b"\x05\x00")
    c.recv(64); c.sendall(bytes([5, 4, 0, 1, 0, 0, 0, 0, 0, 0]))
    c.close()
_th.Thread(target=_fake, daemon=True).start()
ok, why = qipcall._proxy_works(_port, timeout=3)
assert ok is False and "недоступ" in why, ("отказ SOCKS не расшифрован", why)
print("  проверка прохождения трафика: ок")
