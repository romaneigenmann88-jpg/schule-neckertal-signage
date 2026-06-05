#!/usr/bin/env python3
"""Schule Neckertal – Signage: PPTX aus SharePoint via Microsoft Graph laden.

Client-Credentials-Flow (App-Only). Liest die App-Zugangsdaten aus der Umgebung:
  AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET

Lädt die Datei nach --output und gibt den cTag (ändert sich nur bei
Inhaltsänderung) auf stdout aus – für die Änderungserkennung im Workflow.
"""
import argparse
import json
import os
import sys
import urllib.parse
import urllib.request

GRAPH = "https://graph.microsoft.com/v1.0"


def get_token():
    tenant = os.environ["AZURE_TENANT_ID"]
    data = urllib.parse.urlencode({
        "client_id": os.environ["AZURE_CLIENT_ID"],
        "client_secret": os.environ["AZURE_CLIENT_SECRET"],
        "scope": "https://graph.microsoft.com/.default",
        "grant_type": "client_credentials",
    }).encode()
    url = f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"
    with urllib.request.urlopen(urllib.request.Request(url, data=data), timeout=30) as r:
        return json.load(r)["access_token"]


def graph(url, token, raw=False):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read() if raw else json.load(r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--site-id", required=True)
    ap.add_argument("--file-path", required=True, help="Pfad relativ zur Standard-Dokumentbibliothek")
    ap.add_argument("--output", help="Zieldatei (nicht nötig bei --metadata-only)")
    ap.add_argument("--metadata-only", action="store_true",
                    help="Nur den cTag holen (kein Download) – für günstige Änderungsprüfung")
    args = ap.parse_args()

    token = get_token()
    # Pfadsegmente einzeln kodieren, Schrägstriche erhalten
    enc = "/".join(urllib.parse.quote(p) for p in args.file_path.split("/"))
    base = f"{GRAPH}/sites/{args.site_id}/drive/root:/{enc}"

    meta = graph(base, token)
    ctag = meta.get("cTag", "") or meta.get("eTag", "")

    if not args.metadata_only:
        if not args.output:
            sys.exit("--output erforderlich (ohne --metadata-only)")
        content = graph(base + ":/content", token, raw=True)
        with open(args.output, "wb") as f:
            f.write(content)
        sys.stderr.write(f"PPTX geladen: {len(content)} Bytes aus SharePoint (cTag={ctag})\n")

    print(ctag)   # stdout: nur der cTag (zum Abgreifen im Workflow)


if __name__ == "__main__":
    main()
