#!/usr/bin/env python3
"""Nachgestellter HelloBaby-Server fuer die Unit-Tests (StueckUploadTests).

Verhaelt sich an `/<szenario>/api/entries.php` wie der echte Server beim
Hochladen in Stuecken: Stuecke nur am passenden Offset, sonst 409 mit dem
echten Stand; Videos sind erst nach einigen Statusabfragen "bereit"; der
Eintrag ist wiederholbar. Das Szenario im Pfad waehlt die Stoerung:

  neu      alles laeuft glatt
  abriss   die Antwort auf das zweite Stueck und auf das erste Anlegen des
           Eintrags geht verloren (Verbindung wird ohne Antwort geschlossen)
  haengt   Stuecke kommen nie durch
  alt      Server ohne das Verfahren: kennt nur multipart mit images[]

Aufruf:  python3 ci/upload_attrappe.py 18765
Der Zustand laesst sich ueber GET /<szenario>/zustand abfragen und ueber
POST /zuruecksetzen leeren. Nur fuer Tests - bindet an 127.0.0.1.
"""
import hashlib
import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

STUECK = 512 * 1024
VIDEO = (".mov", ".mp4", ".m4v", ".webm")

sperre = threading.Lock()
szenarien = {}


def zustand(name):
    return szenarien.setdefault(name, {"uploads": {}, "eintraege": [], "abrisse": 0, "abgelehnt": 0})


class Anfrage(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, muster, *werte):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def antworte(self, code, daten):
        roh = json.dumps(daten).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(roh)))
        self.end_headers()
        self.wfile.write(roh)

    def reisse_ab(self, z):
        """Schliesst die Verbindung, ohne zu antworten."""
        z["abrisse"] += 1
        self.close_connection = True
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def stand(self, upload, bereit=None):
        komplett = len(upload["daten"]) == upload["size"]
        if bereit is None:
            bereit = komplett and not upload["name"].lower().endswith(VIDEO)
        return {"received": len(upload["daten"]), "size": upload["size"], "complete": komplett, "bereit": bereit}

    def do_GET(self):
        self.bediene(b"")

    def do_POST(self):
        self.bediene(self.rfile.read(int(self.headers.get("Content-Length") or 0)))

    def bediene(self, koerper):
        url = urlsplit(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        teile = [t for t in url.path.split("/") if t]
        with sperre:
            if teile == ["bereit"]:
                return self.antworte(200, {"ok": True})
            if teile == ["zuruecksetzen"]:
                szenarien.clear()
                return self.antworte(200, {"ok": True})
            if len(teile) == 2 and teile[1] == "zustand":
                return self.antworte(200, self.bericht(zustand(teile[0])))
            if len(teile) == 3 and teile[1:] == ["api", "entries.php"]:
                return self.eintraege(teile[0], zustand(teile[0]), query, koerper)
            return self.antworte(404, {"error": "unbekannt"})

    def bericht(self, z):
        return {
            "uploads": [
                {"id": kennung, "name": u["name"], "size": u["size"], "received": len(u["daten"]),
                 "sha256": hashlib.sha256(bytes(u["daten"])).hexdigest(),
                 "offsets": u["offsets"], "status": u["status"]}
                for kennung, u in z["uploads"].items()
            ],
            "eintraege": z["eintraege"],
            "abrisse": z["abrisse"],
            "abgelehnt": z["abgelehnt"],
        }

    def eintraege(self, szenario, z, query, koerper):
        aktion = query.get("upload")
        if szenario == "alt":
            return self.alter_server(z, aktion, koerper)

        if aktion == "init" and self.command == "POST":
            felder = {k: v[0] for k, v in parse_qs(koerper.decode()).items()}
            kennung = "%032x" % (len(z["uploads"]) + 1)
            z["uploads"][kennung] = {"name": felder["name"], "size": int(felder["size"]),
                                     "daten": bytearray(), "offsets": [], "status": 0}
            return self.antworte(200, {"upload_id": kennung, "chunk_size": STUECK, "received": 0,
                                       "size": int(felder["size"])})

        if aktion in ("chunk", "status"):
            upload = z["uploads"].get(query.get("id", ""))
            if upload is None:
                return self.antworte(404, {"error": "Upload unbekannt oder abgelaufen.", "upload_fehler": True})
            if aktion == "status":
                komplett = len(upload["daten"]) == upload["size"]
                if komplett:
                    upload["status"] += 1
                # Ein Video ist erst bei der dritten Abfrage umgewandelt.
                bereit = komplett and (not upload["name"].lower().endswith(VIDEO) or upload["status"] > 2)
                return self.antworte(200, self.stand(upload, bereit))
            if szenario == "haengt":
                return self.reisse_ab(z)
            offset = int(query["offset"])
            if offset != len(upload["daten"]) or self.headers.get("Content-Type") != "application/octet-stream":
                z["abgelehnt"] += 1
                return self.antworte(409, dict(self.stand(upload), error="Stueck passt nicht.", upload_fehler=True))
            upload["daten"] += koerper
            upload["offsets"].append(offset)
            if szenario == "abriss" and offset == STUECK and z["abrisse"] == 0:
                return self.reisse_ab(z)
            return self.antworte(200, self.stand(upload))

        if aktion is None and self.command == "POST":
            felder = parse_qs(koerper.decode(), keep_blank_values=True)
            kennungen = felder.pop("uploads[]", [])
            for kennung in kennungen:
                upload = z["uploads"].get(kennung)
                if upload is None or len(upload["daten"]) != upload["size"]:
                    return self.antworte(409, {"error": "Upload ist unvollstaendig.", "upload_fehler": True})
            # Wiederholbar: dieselben Uploads ergeben denselben Eintrag.
            for eintrag in z["eintraege"]:
                if kennungen and eintrag["uploads"] == kennungen:
                    eintrag["anfragen"] += 1
                    return self.antworte(200, {"success": True, "id": eintrag["id"]})
            eintrag = {"id": len(z["eintraege"]) + 1, "felder": {k: v[0] for k, v in felder.items()},
                       "uploads": kennungen, "anfragen": 1}
            z["eintraege"].append(eintrag)
            if szenario == "abriss" and z["abrisse"] == 1:
                return self.reisse_ab(z)
            return self.antworte(200, {"success": True, "id": eintrag["id"]})

        return self.antworte(400, {"error": "Unbekannte Upload-Aktion.", "upload_fehler": True})

    def alter_server(self, z, aktion, koerper):
        """Stand vor dem Verfahren: jede POST-Anfrage ist ein Eintrag."""
        if self.command != "POST":
            return self.antworte(400, {"error": "Missing query parameter: date, year+month, or favorites"})
        if b'name="kalender_datum"' not in koerper:
            return self.antworte(400, {"error": "Required fields missing: kalender_datum"})
        eintrag = {"id": len(z["eintraege"]) + 1, "felder": {}, "uploads": [], "anfragen": 1,
                   "multipart_images": koerper.count(b'name="images[]"'), "koerper_bytes": len(koerper)}
        z["eintraege"].append(eintrag)
        return self.antworte(200, {"success": True, "id": eintrag["id"]})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18765
    ThreadingHTTPServer(("127.0.0.1", port), Anfrage).serve_forever()
