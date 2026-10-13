"""Einmalige Garmin-Anmeldung auf dem Server.

Fragt E-Mail, Passwort und falls nötig den MFA-Code ab und speichert nur die
Login-Tokens (nicht das Passwort) im Token-Ordner. Danach braucht der Dienst
kein Passwort mehr.

Aufruf (installiert durch install.sh):
    sudo garmin-login
"""

from __future__ import annotations

import getpass
import os
import sys

TOKENSTORE = os.environ.get("GARMIN_TOKENSTORE", os.path.expanduser("~/.garminconnect"))


def main() -> int:
    from garminconnect import Garmin

    print("Garmin-Anmeldung für die Health-App")
    print(f"Tokens werden gespeichert in: {TOKENSTORE}\n")
    email = input("Garmin E-Mail: ").strip()
    password = getpass.getpass("Garmin Passwort (wird nicht angezeigt): ")

    def mfa() -> str:
        return input("MFA-Code aus der E-Mail oder App: ").strip()

    api = Garmin(email=email, password=password, prompt_mfa=mfa)
    try:
        api.login(TOKENSTORE)
    except Exception as e:
        print(f"\nAnmeldung fehlgeschlagen: {e}")
        print("Prüfe E-Mail und Passwort. Bei 'Too many' ein paar Minuten warten.")
        return 1
    api.client.dump(TOKENSTORE)
    name = getattr(api, "display_name", None) or getattr(api, "full_name", None) or "ok"
    print(f"\nAngemeldet ({name}). Tokens gespeichert.")
    print("Test: Schritte heute =", (api.get_user_summary(__import__('datetime').date.today().isoformat()) or {}).get("totalSteps"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
