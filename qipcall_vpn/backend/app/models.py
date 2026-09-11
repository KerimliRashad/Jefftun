from datetime import datetime
from sqlalchemy import Column, String, Integer, BigInteger, Boolean, DateTime
from sqlalchemy.orm import DeclarativeBase


class Base(DeclarativeBase):
    pass


class VpnUser(Base):
    __tablename__ = "vpn_users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    # Логин/метка пользователя (email в терминах xray)
    name = Column(String(100), unique=True, nullable=False)
    # UUID для VLESS/VMess
    uuid = Column(String(64), unique=True, nullable=False)
    # Пароль для Trojan / Shadowsocks
    secret = Column(String(64), nullable=False)
    # Токен для ссылки-подписки /sub/{token}
    sub_token = Column(String(64), unique=True, nullable=False)

    # Тариф / срок
    plan = Column(String(50), default="basic")
    expires_at = Column(DateTime, nullable=True)          # None = бессрочно
    traffic_limit = Column(BigInteger, default=0)         # байты, 0 = безлимит
    traffic_used = Column(BigInteger, default=0)

    is_active = Column(Boolean, default=True)
    telegram_id = Column(BigInteger, nullable=True)
    # Список id серверов через запятую, к которым есть доступ. Пусто/NULL = все.
    server_ids = Column(String(255), nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)

    @property
    def is_expired(self):
        return self.expires_at is not None and self.expires_at < datetime.utcnow()

    @property
    def enabled(self):
        return self.is_active and not self.is_expired

    def allowed_server_ids(self):
        if not self.server_ids:
            return None  # None = доступны все серверы
        return {int(x) for x in self.server_ids.split(",") if x.strip().isdigit()}


class Server(Base):
    """Сервер-страна. Каждый = отдельная точка (VPS) со своими параметрами."""
    __tablename__ = "servers"

    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String(100), nullable=False)          # "France - быстрый"
    country_code = Column(String(4), default="")        # FR, DE, FI...
    host = Column(String(255), nullable=False)          # ip или домен
    port = Column(Integer, default=443)
    # REALITY параметры этого узла
    public_key = Column(String(120), default="")
    short_id = Column(String(32), default="")
    sni = Column(String(255), default="www.microsoft.com")
    flow = Column(String(32), default="xtls-rprx-vision")
    is_active = Column(Boolean, default=True)
    sort = Column(Integer, default=0)
    created_at = Column(DateTime, default=datetime.utcnow)
