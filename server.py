"""Garmin-Dienst für Noels Health-App.

Ein MCP-Server (Streamable HTTP) mit einem Tool: garmin_tageswerte(tage).
Er läuft auf trader-01 nur auf localhost und ist über einen Cloudflare Tunnel
unter einer geheimen Adresse erreichbar. claude.ai bindet ihn als Connector ein.

Ausgabe wie beim bisherigen PC-Server:
  {"rows": [{"date", "sleepH", "sleepScore", "steps", "restingHr",
             "activeKcal", "weightKg", "bodyFatPct"}], "errors": [...]}
"""

from __future__ import annotations

import logging
import os
import threading
from datetime import date, timedelta
from typing import Any

from typing_extensions import NotRequired, TypedDict

from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings

log = logging.getLogger("garmin-mcp")

TOKENSTORE = os.environ.get("GARMIN_TOKENSTORE", os.path.expanduser("~/.garminconnect"))
SECRET = os.environ.get("GARMIN_MCP_SECRET", "")
HOST = os.environ.get("GARMIN_MCP_HOST", "127.0.0.1")
PORT = int(os.environ.get("GARMIN_MCP_PORT", "8765"))
MAX_TAGE = 31


class Tag(TypedDict):
    date: str
    sleepH: NotRequired[float]
    sleepScore: NotRequired[int]
    steps: NotRequired[int]
    restingHr: NotRequired[int]
    activeKcal: NotRequired[int]
    weightKg: NotRequired[float]
    bodyFatPct: NotRequired[float]


class Antwort(TypedDict):
    rows: list[Tag]
    errors: list[str]

# ---------------------------------------------------------------- Garmin-Zugang

_api = None
_api_lock = threading.Lock()


def _login():
    """Meldet sich mit den gespeicherten Tokens an (kein Passwort auf dem Server)."""
    from garminconnect import Garmin

    api = Garmin()
    api.login(TOKENSTORE)
    return api


def _get_api(force: bool = False):
    global _api
    with _api_lock:
        if _api is None or force:
            _api = _login()
        return _api


def _persist_tokens(api) -> None:
    """Erneuerte Tokens zurückschreiben, damit sie einen Neustart überleben."""
    try:
        api.client.dump(TOKENSTORE)
    except Exception as e:  # nicht kritisch
        log.debug("Tokens nicht gespeichert: %s", e)


def _num(v: Any) -> float | None:
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _sleep(api, d: str) -> dict:
    data = api.get_sleep_data(d) or {}
    dto = data.get("dailySleepDTO") or {}
    out: dict = {}
    secs = _num(dto.get("sleepTimeSeconds"))
    if secs and secs > 0:
        out["sleepH"] = round(secs / 3600, 1)
    score = ((dto.get("sleepScores") or {}).get("overall") or {}).get("value")
    if _num(score) is not None:
        out["sleepScore"] = int(_num(score))
    return out


def _summary(api, d: str) -> dict:
    s = api.get_user_summary(d) or {}
    out: dict = {}
    for src, dst in (("totalSteps", "steps"), ("restingHeartRate", "restingHr"), ("activeKilocalories", "activeKcal")):
        v = _num(s.get(src))
        if v is not None:
            out[dst] = int(round(v))
    return out


def _weights(api, start: str, end: str) -> dict[str, dict]:
    """Letzte Messung pro Tag von der Waage."""
    data = api.get_body_composition(start, end) or {}
    result: dict[str, dict] = {}
    entries = data.get("dateWeightList") or []
    # nach Zeitpunkt sortieren, damit die späteste Messung des Tages gewinnt
    entries = sorted(entries, key=lambda e: _num(e.get("date")) or _num(e.get("timestampGMT")) or 0)
    for e in entries:
        day = str(e.get("calendarDate") or "")[:10]
        w = _num(e.get("weight"))
        if not day or w is None:
            continue
        kg = w / 1000 if w > 1000 else w  # Garmin liefert Gramm
        row = {"weightKg": round(kg, 2)}
        bf = _num(e.get("bodyFat"))
        if bf is not None and bf > 0:
            row["bodyFatPct"] = round(bf, 1)
        result[day] = row
    return result


def tageswerte(tage: int) -> Antwort:
    tage = max(1, min(MAX_TAGE, int(tage or 7)))
    heute = date.today()
    days = [(heute - timedelta(days=i)).isoformat() for i in range(tage)]
    errors: list[str] = []

    try:
        api = _get_api()
    except Exception as e:
        return {"rows": [], "errors": [f"Garmin-Anmeldung fehlgeschlagen: {e}"]}

    def collect(api) -> tuple[list[dict], list[str]]:
        rows, errs = [], []
        try:
            weights = _weights(api, days[-1], days[0])
        except Exception as e:
            weights = {}
            errs.append(f"Gewicht: {e}")
        for d in days:
            row: dict = {"date": d}
            for part, fn in (("Schlaf", _sleep), ("Tageswerte", _summary)):
                try:
                    row.update(fn(api, d))
                except Exception as e:
                    errs.append(f"{part} {d}: {e}")
            row.update(weights.get(d, {}))
            rows.append(row)
        return rows, errs

    rows, errors = collect(api)
    # Alles fehlgeschlagen? Einmal neu anmelden und nochmals versuchen.
    if errors and all(len(r) == 1 for r in rows):
        try:
            api = _get_api(force=True)
            rows, errors = collect(api)
        except Exception as e:
            errors.append(f"Garmin-Anmeldung fehlgeschlagen: {e}")
    _persist_tokens(api)
    return {"rows": rows, "errors": errors[:20]}


# ---------------------------------------------------------------- MCP-Server

mcp = MCPServer(
    name="garmin",
    instructions="Liefert Noels Garmin-Tageswerte (Schlaf, Schritte, Ruhepuls, aktive kcal, Gewicht) für seine Health-App.",
)


@mcp.tool(
    name="garmin_tageswerte",
    description=(
        "Garmin-Tageswerte der letzten `tage` Tage (1–31, Standard 7), neuester Tag zuerst. "
        "Pro Tag: date, sleepH, sleepScore, steps, restingHr, activeKcal, weightKg, bodyFatPct "
        "(fehlende Werte werden weggelassen). Fehler stehen in `errors`."
    ),
    structured_output=True,
)
def garmin_tageswerte(tage: int = 7) -> Antwort:
    return tageswerte(tage)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if len(SECRET) < 24:
        raise SystemExit("GARMIN_MCP_SECRET fehlt oder ist zu kurz (mind. 24 Zeichen).")
    path = f"/{SECRET}/mcp"
    log.info("Garmin-Dienst startet auf %s:%s (geheimer Pfad gesetzt)", HOST, PORT)
    mcp.run(
        transport="streamable-http",
        host=HOST,
        port=PORT,
        streamable_http_path=path,
        stateless_http=True,
        json_response=True,
        # Der Dienst hört nur auf localhost; von aussen kommt alles über den
        # Cloudflare Tunnel mit fremdem Host-Header. Schutz = geheimer Pfad.
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )


if __name__ == "__main__":
    main()
