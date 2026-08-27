#!/usr/bin/env python3
"""Prépare une (re)connexion OAuth de Canva ou Google au compte pro du bar.

Le script ne touche à rien tout seul : il génère la paire PKCE, puis affiche
(1) le SQL à coller dans le SQL editor Supabase et (2) l'URL de consentement à
ouvrir *en étant connecté au compte professionnel du bar*. Les jetons sont
ensuite stockés par les Edge Functions `canva-oauth-callback` /
`google-oauth-callback`.

Usage:
    scripts/oauth-connect.py google --client-id <CLIENT_ID>
    scripts/oauth-connect.py canva  --client-id <CLIENT_ID>
"""
import argparse
import base64
import hashlib
import secrets
import urllib.parse

SUPABASE_URL = "https://vfkjiprgawimhmieikyw.supabase.co"

PROVIDERS = {
    "google": {
        "table": "google_calendar_oauth",
        "authorize_url": "https://accounts.google.com/o/oauth2/v2/auth",
        "scopes": [
            "https://www.googleapis.com/auth/calendar.events",
            "https://www.googleapis.com/auth/spreadsheets",
        ],
        "scope_sep": " ",
        # access_type=offline + prompt=consent force Google à renvoyer un
        # refresh_token même si le compte a déjà autorisé l'app une fois.
        "extra": {"access_type": "offline", "prompt": "consent",
                  "include_granted_scopes": "true"},
    },
    "canva": {
        "table": "canva_oauth",
        "authorize_url": "https://www.canva.com/api/oauth/authorize",
        "scopes": ["design:meta:read", "design:content:read"],
        "scope_sep": " ",
        "extra": {},
    },
}


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("provider", choices=sorted(PROVIDERS))
    parser.add_argument("--client-id", required=True,
                        help="client_id de l'app OAuth (visible dans la table oauth correspondante)")
    args = parser.parse_args()

    cfg = PROVIDERS[args.provider]
    redirect_uri = f"{SUPABASE_URL}/functions/v1/{args.provider}-oauth-callback"

    state = b64url(secrets.token_bytes(24))
    verifier = b64url(secrets.token_bytes(64))
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())

    params = {
        "client_id": args.client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": cfg["scope_sep"].join(cfg["scopes"]),
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        **cfg["extra"],
    }
    url = f"{cfg['authorize_url']}?{urllib.parse.urlencode(params)}"

    print("1) Colle ce SQL dans le SQL editor Supabase (projet vandb-reservations) :\n")
    print(f"""update {cfg['table']}
   set pending_state = '{state}',
       pending_code_verifier = '{verifier}'
 where id = 1;
""")
    print("2) Puis ouvre cette URL dans un navigateur CONNECTÉ AU COMPTE PRO DU BAR :\n")
    print(url)
    print(f"\n   (redirect_uri à déclarer côté {args.provider} : {redirect_uri})")


if __name__ == "__main__":
    main()
