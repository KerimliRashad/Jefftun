import uuid as uuidlib
import secrets
from contextlib import asynccontextmanager
from datetime import datetime, timedelta

from fastapi import FastAPI, Depends, HTTPException, Form
from fastapi.responses import PlainTextResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from pydantic import BaseModel
from typing import Optional

from app import config, xray
from app.database import init_db, get_db, AsyncSessionLocal
from app.models import VpnUser, Server
from app.auth import make_admin_token, require_admin


async def resync_xray():
    """Перечитывает всех пользователей и пересобирает конфиг xray."""
    async with AsyncSessionLocal() as db:
        users = (await db.execute(select(VpnUser))).scalars().all()
        xray.apply(list(users))


async def seed_default_server():
    """Если серверов нет — создаём текущий VPS как первый сервер-страну."""
    async with AsyncSessionLocal() as db:
        existing = (await db.execute(select(Server))).scalars().first()
        if existing:
            return
        db.add(Server(
            name="Server 1 - быстрый",
            country_code="",
            host=config.SERVER_IP,
            port=config.PORT_REALITY,
            public_key=config.REALITY_PUBLIC_KEY,
            short_id=config.REALITY_SHORT_ID,
            sni=config.REALITY_SNI,
            flow="xtls-rprx-vision",
            is_active=True, sort=0,
        ))
        await db.commit()


async def servers_for(u, db):
    """Серверы, доступные конкретному юзеру (с учётом его набора стран)."""
    all_servers = (await db.execute(
        select(Server).where(Server.is_active == True).order_by(Server.sort, Server.id)
    )).scalars().all()
    allowed = u.allowed_server_ids()
    if allowed is None:
        return all_servers
    return [s for s in all_servers if s.id in allowed]


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    await seed_default_server()
    await resync_xray()
    yield


app = FastAPI(title="JeffTUN VPN", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


def gen_token(n=24):
    return secrets.token_urlsafe(n)[:n]


# ══ ПОДПИСКА (для Happ / v2RayTun) ═══════════════════════════════════════════
@app.get("/sub/{token}", response_class=PlainTextResponse)
async def get_subscription(token: str, db: AsyncSession = Depends(get_db)):
    u = (await db.execute(select(VpnUser).where(VpnUser.sub_token == token))).scalar_one_or_none()
    if not u:
        raise HTTPException(status_code=404, detail="Подписка не найдена")
    if not u.enabled:
        # Возвращаем пустую подписку для отключённых
        return PlainTextResponse("", headers={"Profile-Title": "JeffTUN (истёк)"})
    servers = await servers_for(u, db)
    body = xray.subscription_body(u, servers)
    days_left = ""
    if u.expires_at:
        days_left = f" · до {u.expires_at.strftime('%d.%m.%Y')}"
    return PlainTextResponse(body, headers={
        "Profile-Title": f"JeffTUN VPN{days_left}",
        "Profile-Update-Interval": "12",
        "Subscription-Userinfo": _userinfo_header(u),
    })


def _userinfo_header(u) -> str:
    parts = [f"upload=0", f"download={u.traffic_used}"]
    if u.traffic_limit:
        parts.append(f"total={u.traffic_limit}")
    if u.expires_at:
        parts.append(f"expire={int(u.expires_at.timestamp())}")
    return "; ".join(parts)


# ══ АДМИН: вход ══════════════════════════════════════════════════════════════
@app.post("/api/admin/login")
async def admin_login(password: str = Form(...)):
    if password != config.ADMIN_PASSWORD:
        raise HTTPException(status_code=401, detail="Неверный пароль")
    return {"token": make_admin_token()}


def user_dict(u: VpnUser) -> dict:
    return {
        "id": u.id, "name": u.name, "plan": u.plan,
        "sub_token": u.sub_token,
        "sub_url": f"https://{config.PANEL_DOMAIN}:8443/sub/{u.sub_token}",
        "expires_at": u.expires_at.isoformat() if u.expires_at else None,
        "traffic_limit": u.traffic_limit, "traffic_used": u.traffic_used,
        "is_active": u.is_active, "enabled": u.enabled, "is_expired": u.is_expired,
        "telegram_id": u.telegram_id, "server_ids": u.server_ids,
        "created_at": u.created_at.isoformat() if u.created_at else None,
    }


# ══ АДМИН: список / статистика ═══════════════════════════════════════════════
@app.get("/api/admin/stats")
async def stats(_: bool = Depends(require_admin), db: AsyncSession = Depends(get_db)):
    users = (await db.execute(select(VpnUser))).scalars().all()
    active = [u for u in users if u.enabled]
    return {
        "total": len(users),
        "active": len(active),
        "expired": len([u for u in users if u.is_expired]),
        "disabled": len([u for u in users if not u.is_active]),
        "traffic_used": sum(u.traffic_used for u in users),
        "domain": config.PANEL_DOMAIN,
        "server_ip": config.SERVER_IP,
    }


@app.get("/api/admin/users")
async def list_users(_: bool = Depends(require_admin), db: AsyncSession = Depends(get_db)):
    users = (await db.execute(select(VpnUser).order_by(VpnUser.id.desc()))).scalars().all()
    return [user_dict(u) for u in users]


class CreateUser(BaseModel):
    name: str
    days: int = 30            # срок в днях, 0 = бессрочно
    traffic_gb: int = 0       # лимит трафика в ГБ, 0 = безлимит
    plan: str = "basic"
    telegram_id: Optional[int] = None


@app.post("/api/admin/users")
async def create_user(data: CreateUser, _: bool = Depends(require_admin), db: AsyncSession = Depends(get_db)):
    name = data.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Укажите имя")
    if (await db.execute(select(VpnUser).where(VpnUser.name == name))).scalar_one_or_none():
        raise HTTPException(status_code=400, detail="Имя уже занято")

    u = VpnUser(
        name=name,
        uuid=str(uuidlib.uuid4()),
        secret=gen_token(20),
        sub_token=gen_token(24),
        plan=data.plan,
        expires_at=(datetime.utcnow() + timedelta(days=data.days)) if data.days else None,
        traffic_limit=data.traffic_gb * 1024**3,
        telegram_id=data.telegram_id,
    )
    db.add(u)
    await db.commit()
    await db.refresh(u)
    await resync_xray()
    return user_dict(u)


class UpdateUser(BaseModel):
    add_days: Optional[int] = None
    set_traffic_gb: Optional[int] = None
    is_active: Optional[bool] = None
    plan: Optional[str] = None


@app.put("/api/admin/users/{uid}")
async def update_user(uid: int, data: UpdateUser, _: bool = Depends(require_admin), db: AsyncSession = Depends(get_db)):
    u = await db.get(VpnUser, uid)
    if not u:
        raise HTTPException(status_code=404, detail="Не найден")
    if data.add_days is not None:
        base = u.expires_at if (u.expires_at and u.expires_at > datetime.utcnow()) else datetime.utcnow()
        u.expires_at = base + timedelta(days=data.add_days)
    if data.set_traffic_gb is not None:
        u.traffic_limit = data.set_traffic_gb * 1024**3
    if data.is_active is not None:
        u.is_active = data.is_active
    if data.plan is not None:
        u.plan = data.plan
    await db.commit()
    await db.refresh(u)
    await resync_xray()
    return user_dict(u)


@app.delete("/api/admin/users/{uid}")
async def delete_user(uid: int, _: bool = Depends(require_admin), db: AsyncSession = Depends(get_db)):
    u = await db.get(VpnUser, uid)
    if not u:
        raise HTTPException(status_code=404, detail="Не найден")
    await db.delete(u)
    await db.commit()
    await resync_xray()
    return {"status": "ok"}


# ══ АДМИН: серверы-страны ════════════════════════════════════════════════════
def server_dict(s: Server) -> dict:
    return {
        "id": s.id, "name": s.name, "country_code": s.country_code,
        "host": s.host, "port": s.port, "public_key": s.public_key,
        "short_id": s.short_id, "sni": s.sni, "flow": s.flow,
        "is_active": s.is_active, "sort": s.sort,
    }


@app.get("/api/admin/servers")
async def list_servers(_: bool = Depends(require_admin), db: AsyncSession = Depends(get_db)):
    servers = (await db.execute(select(Server).order_by(Server.sort, Server.id))).scalars().all()
    return [server_dict(s) for s in servers]


class ServerIn(BaseModel):
    name: str
    country_code: str = ""
    host: str
    port: int = 443
    public_key: str = ""
    short_id: str = ""
    sni: str = "www.microsoft.com"
    flow: str = "xtls-rprx-vision"
    is_active: bool = True
    sort: int = 0


@app.post("/api/admin/servers")
async def create_server(data: ServerIn, _: bool = Depends(require_admin), db: AsyncSession = Depends(get_db)):
    s = Server(**data.model_dump())
    db.add(s)
    await db.commit()
    await db.refresh(s)
    return server_dict(s)


@app.put("/api/admin/servers/{sid}")
async def update_server(sid: int, data: ServerIn, _: bool = Depends(require_admin), db: AsyncSession = Depends(get_db)):
    s = await db.get(Server, sid)
    if not s:
        raise HTTPException(status_code=404, detail="Сервер не найден")
    for k, v in data.model_dump().items():
        setattr(s, k, v)
    await db.commit()
    return server_dict(s)


@app.delete("/api/admin/servers/{sid}")
async def delete_server(sid: int, _: bool = Depends(require_admin), db: AsyncSession = Depends(get_db)):
    s = await db.get(Server, sid)
    if s:
        await db.delete(s)
        await db.commit()
    return {"status": "ok"}


class SetUserServers(BaseModel):
    server_ids: Optional[str] = None  # "1,3,5" или пусто = все


@app.put("/api/admin/users/{uid}/servers")
async def set_user_servers(uid: int, data: SetUserServers, _: bool = Depends(require_admin), db: AsyncSession = Depends(get_db)):
    u = await db.get(VpnUser, uid)
    if not u:
        raise HTTPException(status_code=404, detail="Не найден")
    u.server_ids = (data.server_ids or "").strip() or None
    await db.commit()
    return {"status": "ok", "server_ids": u.server_ids}


@app.get("/api/admin/downloads")
async def downloads(_: bool = Depends(require_admin)):
    """Сколько людей скачали приложение (счётчики GitHub Releases)."""
    import urllib.request, json as _json, asyncio
    url = "https://api.github.com/repos/kerimlirashad/kerimlirashad/releases/tags/qipcall-latest"

    def fetch():
        req = urllib.request.Request(url, headers={"User-Agent": "JeffTUN"})
        return _json.loads(urllib.request.urlopen(req, timeout=10).read())

    try:
        data = await asyncio.to_thread(fetch)
        assets = [{"name": a["name"], "count": a.get("download_count", 0)}
                  for a in data.get("assets", [])]
        return {"assets": assets, "total": sum(a["count"] for a in assets)}
    except Exception as e:
        return {"assets": [], "total": 0, "error": str(e)}


@app.get("/api/config")
async def public_config():
    return {"domain": config.PANEL_DOMAIN, "reality_configured": bool(config.REALITY_PUBLIC_KEY)}


@app.get("/api/health")
async def health():
    return JSONResponse({"status": "ok"})
