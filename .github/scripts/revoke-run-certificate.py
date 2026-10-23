#!/usr/bin/env python3
"""Revoke the Apple Development certificate THIS TestFlight run created (#407).

Why this exists: every run is a fresh macOS runner with no signing identity,
so `xcodebuild archive -allowProvisioningUpdates` has Xcode create a NEW Apple
Development certificate for the archive step. Its private key lives only in
the runner's keychain and dies with it, so the certificate can never be used
again — yet it counts against the team's limit. One per build: at build 11
(2026-10-23) the team hit Apple's maximum and the archive refused to sign.
The distribution signature comes from Apple's cloud-managed certificate at
export, so only these development certificates pile up.

What it revokes: ONLY certificates whose serial number is in THIS runner's
keychain, issued to THIS team. The owner's own certificate (the one their
Mac signs device builds with) has its private key on the Mac, never here, so
it can never match. Revoking a development certificate does not touch an
uploaded TestFlight build, which is distribution-signed.

No third-party code: the JWT the App Store Connect API needs is signed with
the `openssl` binary and assembled with the standard library. A package from
PyPI would run in the one step of the workflow that holds the signing key.

Usage:
    revoke-run-certificate.py               # in the workflow; reads the env below
    revoke-run-certificate.py --self-test   # CI: the pure parts, with a throwaway key

Env: ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID, APPLE_TEAM_ID.
Exit 0: revoked, or nothing was created. Exit 1: something was created and is
still there — the run says so, because the limit comes back if it repeats.
"""
# The runner's /usr/bin/python3 can be 3.9, where `int | None` in a signature
# is evaluated at definition time and fails.
from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
DEVELOPMENT_TYPES = "DEVELOPMENT,IOS_DEVELOPMENT"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes, size: int = 32) -> bytes:
    """An ECDSA signature as openssl writes it (DER: SEQUENCE { r, s }) to
    the 64 raw bytes r || s that ES256 in a JWT is."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER sequence")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    raw = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("not a DER integer")
        length = der[i + 1]
        value = der[i + 2:i + 2 + length].lstrip(b"\x00")
        i += 2 + length
        if len(value) > size:
            raise ValueError("integer longer than the curve")
        raw += value.rjust(size, b"\x00")
    return raw


def raw_to_der(raw: bytes) -> bytes:
    """The inverse, for the self-test's round trip through `openssl -verify`."""
    def integer(value: bytes) -> bytes:
        value = value.lstrip(b"\x00") or b"\x00"
        if value[0] & 0x80:
            value = b"\x00" + value
        return bytes([0x02, len(value)]) + value
    body = integer(raw[:32]) + integer(raw[32:])
    return bytes([0x30, len(body)]) + body


def jwt(key_path: str, key_id: str, issuer: str, now: int | None = None) -> str:
    now = int(now if now is not None else time.time())
    compact = (",", ":")
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=compact).encode())
    # Twenty minutes is Apple's ceiling; ten is plenty for two calls.
    payload = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 600,
                                 "aud": "appstoreconnect-v1"}, separators=compact).encode())
    signing_input = f"{header}.{payload}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                         input=signing_input, capture_output=True, check=True).stdout
    return f"{header}.{payload}.{b64url(der_to_raw(der))}"


def normalise_serial(serial: str) -> str:
    """openssl prints `serial=0A1B…`; App Store Connect may drop the leading
    zeros. Compared upper-case with them stripped."""
    return serial.strip().upper().lstrip("0") or "0"


def certificates_in(text: str) -> list[str]:
    return re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", text, re.S)


def serials_from_pems(text: str, team: str) -> list[str]:
    """The serials of the Apple Development certificates in `text` issued to
    `team` (the subject's OU). Anything else is left alone."""
    serials = []
    for pem in certificates_in(text):
        out = subprocess.run(["openssl", "x509", "-noout", "-serial", "-subject", "-nameopt", "RFC2253"],
                             input=pem, capture_output=True, text=True, check=True).stdout
        serial = re.search(r"serial=([0-9A-Fa-f]+)", out)
        subject = re.search(r"subject=\s*(.*)", out)
        if not serial or not subject:
            continue
        fields = subject.group(1)
        if "CN=Apple Development" not in fields or f"OU={team}" not in fields.split(","):
            continue
        serials.append(normalise_serial(serial.group(1)))
    return serials


def keychain_serials(team: str) -> list[str]:
    found = subprocess.run(["security", "find-certificate", "-a", "-c", "Apple Development", "-p"],
                           capture_output=True, text=True).stdout
    return serials_from_pems(found, team)


def request(method: str, path: str, token: str):
    req = urllib.request.Request(API + path, method=method,
                                 headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as response:
        body = response.read()
        return response.status, (json.loads(body) if body else None)


def revoke(serials: list[str], token: str) -> tuple[list[str], list[str]]:
    _, listing = request("GET", f"/certificates?filter[certificateType]={DEVELOPMENT_TYPES}"
                                "&fields[certificates]=serialNumber,name,certificateType&limit=200", token)
    by_serial = {normalise_serial(c["attributes"]["serialNumber"]): c
                 for c in listing.get("data", []) if c.get("attributes", {}).get("serialNumber")}
    revoked, missing = [], []
    for serial in serials:
        certificate = by_serial.get(serial)
        if certificate is None:
            missing.append(serial)
            continue
        status, _ = request("DELETE", f"/certificates/{certificate['id']}", token)
        if status in (200, 204):
            revoked.append(serial)
        else:
            missing.append(serial)
    return revoked, missing


def main() -> int:
    env = {k: os.environ.get(k, "") for k in ("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID", "APPLE_TEAM_ID")}
    absent = [k for k, v in env.items() if not v]
    if absent:
        print(f"::warning::not revoking: {', '.join(absent)} not set")
        return 1
    serials = keychain_serials(env["APPLE_TEAM_ID"])
    if not serials:
        print("No Apple Development certificate in this runner's keychain: nothing was created, nothing to revoke.")
        return 0
    try:
        token = jwt(env["ASC_KEY_PATH"], env["ASC_KEY_ID"], env["ASC_ISSUER_ID"])
        revoked, missing = revoke(serials, token)
    except (urllib.error.URLError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"::warning::could not revoke this run's development certificate ({type(error).__name__}: {error}). "
              "It counts against the team's limit until revoked by hand — see #407.")
        return 1
    for serial in revoked:
        print(f"Revoked this run's Apple Development certificate {serial}.")
    if missing:
        print(f"::warning::still on the account: {', '.join(missing)} — see #407.")
        return 1
    return 0


def self_test() -> int:
    """The parts that need no Apple account, on a throwaway key and a
    throwaway self-signed certificate."""
    with tempfile.TemporaryDirectory() as tmp:
        key = os.path.join(tmp, "key.pem")
        pub = os.path.join(tmp, "pub.pem")
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key],
                       check=True, capture_output=True)
        subprocess.run(["openssl", "ec", "-in", key, "-pubout", "-out", pub], check=True, capture_output=True)

        token = jwt(key, "KEYID12345", "issuer-uuid", now=1_800_000_000)
        header, payload, signature = token.split(".")
        pad = lambda s: s + "=" * (-len(s) % 4)
        assert json.loads(base64.urlsafe_b64decode(pad(header))) == {"alg": "ES256", "kid": "KEYID12345", "typ": "JWT"}
        claims = json.loads(base64.urlsafe_b64decode(pad(payload)))
        assert claims["aud"] == "appstoreconnect-v1" and claims["exp"] - claims["iat"] == 600
        raw = base64.urlsafe_b64decode(pad(signature))
        assert len(raw) == 64, "ES256 is 64 raw bytes"
        der_file = os.path.join(tmp, "sig.der")
        with open(der_file, "wb") as f:
            f.write(raw_to_der(raw))
        verify = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", der_file],
                                input=f"{header}.{payload}".encode(), capture_output=True)
        assert verify.returncode == 0, "the converted signature verifies"

        assert normalise_serial("00ab12") == "AB12" and normalise_serial("000") == "0"

        def cert(subject: str) -> str:
            path = os.path.join(tmp, "c.pem")
            subprocess.run(["openssl", "req", "-x509", "-new", "-key", key, "-days", "1", "-subj", subject,
                            "-out", path], check=True, capture_output=True)
            return open(path).read()
        ours = cert("/CN=Apple Development: Created via API (TEAM123456)/OU=TEAM123456/O=Synthetic")
        theirs = cert("/CN=Apple Development: Created via API (OTHER00000)/OU=OTHER00000/O=Synthetic")
        other = cert("/CN=Apple Distribution: Synthetic/OU=TEAM123456/O=Synthetic")
        found = serials_from_pems(ours + "\n" + theirs + "\n" + other, "TEAM123456")
        assert len(found) == 1, f"only this team's development certificate: {found}"
        assert serials_from_pems("", "TEAM123456") == []
    print("self-test passed")
    return 0


if __name__ == "__main__":
    sys.exit(self_test() if "--self-test" in sys.argv[1:] else main())
