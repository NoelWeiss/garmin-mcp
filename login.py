"""Einmalige Garmin-Anmeldung auf dem Server (Windows oder Linux).

Fragt E-Mail, Passwort und falls nötig den MFA-Code ab und speichert nur die
Login-Tokens (nicht das Passwort) im Token-Ordner. Danach braucht der Dienst
kein Passwort mehr.

Windows:  C:\\garmin-mcp\\garmin-login.cmd  (als Administrator)
Linux:    sudo garmin-login
"""

from __future__ import annotations

import getpass
import os
import sys
from datetime import datetime
from zoneinfo import ZoneInfo


def load_config(argv: list[str]) -> None:
    path = None
    if "--config" in argv:
        i = argv.index("--config")
        if i + 1 < len(argv):
            path = argv[i + 1]
    path = path or os.environ.get("GARMIN_MCP_CONFIG")
    if not path or not os.path.isfile(path):
        return
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def main() -> int:
    load_config(sys.argv)
    tokenstore = os.environ.get("GARMIN_TOKENSTORE", os.path.expanduser("~/.garminconnect"))
    from garminconnect import Garmin

    print("Garmin-Anmeldung für die Health-App")
    print(f"Tokens werden gespeichert in: {tokenstore}\n")
    email = input("Garmin E-Mail: ").strip()
    password = getpass.getpass("Garmin Passwort (wird nicht angezeigt): ")

    def mfa() -> str:
        return input("MFA-Code aus der E-Mail oder App: ").strip()

    api = Garmin(email=email, password=password, prompt_mfa=mfa)
    try:
        api.login(tokenstore)
    except Exception as e:
        print(f"\nAnmeldung fehlgeschlagen: {e}")
        print("Prüfe E-Mail und Passwort. Bei 'Too many' ein paar Minuten warten.")
        return 1
    api.client.dump(tokenstore)
    print("\nAngemeldet. Tokens gespeichert.")
    heute = datetime.now(ZoneInfo(os.environ.get("GARMIN_MCP_TZ", "Europe/Zurich"))).date().isoformat()
    try:
        steps = (api.get_user_summary(heute) or {}).get("totalSteps")
        print(f"Test: Schritte heute = {steps}")
    except Exception as e:
        print(f"Test-Abruf fehlgeschlagen: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
