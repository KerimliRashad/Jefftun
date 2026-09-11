import time
import jwt
from fastapi import Header, HTTPException
from app.config import SECRET_KEY

ALGORITHM = "HS256"


def make_admin_token() -> str:
    return jwt.encode({"role": "admin", "exp": int(time.time()) + 86400 * 7}, SECRET_KEY, algorithm=ALGORITHM)


def require_admin(authorization: str = Header(default="")):
    token = authorization.replace("Bearer ", "").strip()
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        if payload.get("role") != "admin":
            raise ValueError
    except Exception:
        raise HTTPException(status_code=401, detail="Требуется вход администратора")
    return True
