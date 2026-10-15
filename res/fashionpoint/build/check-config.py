#!/usr/bin/env python3
"""FashionPoint: refuses an edition's client config (the JSON compiled into every binary as FP_CLIENT_CONFIG) that
would build a client which cannot work: a stock RustDesk, a clinic computer that never registers or that asks
someone to accept, a staff client without account login. The rules of the check-config job of fp-release.yml.

    check-config.py <clinic|staff> <config json file>
"""
import json
import sys

edition, path = sys.argv[1], sys.argv[2]
if edition not in ("clinic", "staff"):
    sys.exit("edition must be clinic or staff")
raw = open(path, encoding="utf-8").read().strip()
if not raw:
    sys.exit(f"{path} is empty: the build would be a stock RustDesk.")
try:
    config = json.loads(raw)
except ValueError as e:
    sys.exit(f"{path} is not valid JSON: {e}")
override = config.get("override-settings") or {}
errors = []


def expect(where, key, value):
    if where.get(key) != value:
        errors.append(f"{key} must be {value}")


name = config.get("app-name") or ""
if not name or name == "RustDesk" or not name.replace("-", "").isalnum():
    errors.append("app-name must be set, differ from RustDesk and have no spaces (it becomes a URI scheme)")
for key in ("custom-rendezvous-server", "relay-server", "key"):
    if not override.get(key):
        errors.append(f"override-settings.{key} is missing")
if not str(override.get("api-server", "")).startswith("https://"):
    errors.append("override-settings.api-server must be the https console address (clients that miss it never reach the API)")
expect(override, "allow-auto-update", "N")
if edition == "clinic":
    expect(config, "conn-type", "incoming")
    expect(config, "disable-account", "Y")
    expect(override, "approve-mode", "password")
    expect(override, "verification-method", "use-permanent-password")
    if override.get("register-device") == "N":
        errors.append("register-device must not be N: clinic computers register with the console")
    # src/fp_pair.rs: the website that pairs the computer with a code. A default, not an override, so an
    # administrator can point a test computer at a test website (FPRemote --option fp-pair-url <url>).
    if not str((config.get("default-settings") or {}).get("fp-pair-url", "")).startswith("https://"):
        errors.append("default-settings.fp-pair-url must be the https address of the website's pairing endpoint")
    if "fp-pair-url" in override:
        errors.append("fp-pair-url belongs in default-settings: an override cannot be pointed at a test website")
    if config.get("disable-settings") == "Y":
        expect(override, "allow-command-line-settings-when-settings-disabled", "Y")
else:
    expect(config, "conn-type", "outgoing")
    if config.get("disable-account") == "Y":
        errors.append("disable-account must not be Y: staff log in with their account")
if errors:
    sys.exit(f"{path}: " + "; ".join(errors))
print(f"{path} is valid: app-name {name}, edition {edition}")
