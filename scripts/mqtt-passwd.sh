#!/usr/bin/env bash
# Sets one user's password in Mosquitto's passwd file, the encrypted copy in this repo.
#
# Prompts for the password and hashes it the way mosquitto_passwd does, so the clear password
# never reaches the disk, a process listing or the shell history. The decrypted file only
# lives in this process. Run it from a real terminal: the prompt reads /dev/tty.
#
#   scripts/mqtt-passwd.sh ha
#
# Commit the file afterwards; Reloader restarts the broker once Flux applies the Secret.
set -euo pipefail

FILE="${MQTT_PASSWD_FILE:-$(cd "$(dirname "$0")/.." && pwd)/kubernetes/apps/home-automation/mosquitto/passwd.sops.yaml}"
USER_NAME="${1:?usage: $0 <user>}"
if ! [[ "$USER_NAME" =~ ^[a-z0-9_-]+$ ]]; then
  echo "invalid user name: $USER_NAME" >&2
  exit 1
fi

# mosquitto 2.x format: $7$<iterations>$<salt>$<digest>, PBKDF2-SHA512, base64 throughout.
HASH_PY='
import base64, getpass, hashlib, json, os, sys
user = sys.argv[1]
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
pw = getpass.getpass(f"New MQTT password for {user}: ")
if not pw or pw != getpass.getpass("Again: "):
    sys.exit("empty or different passwords, nothing changed")
salt = os.urandom(12)
digest = hashlib.pbkdf2_hmac("sha512", pw.encode(), salt, 101)
entry = f"{user}:$7$101${base64.b64encode(salt).decode()}${base64.b64encode(digest).decode()}"
found = any(l.split(":", 1)[0] == user for l in lines)
lines = [entry if l.split(":", 1)[0] == user else l for l in lines] + ([] if found else [entry])
action = "updated" if found else "added"
print(f"{action} {user}, {len(lines)} users in the file", file=sys.stderr)
print(json.dumps(base64.b64encode(("\n".join(lines) + "\n").encode()).decode()))
'

# Held in a variable, not piped into sops: a failed prompt would otherwise hand sops an empty
# value, and it would write a passwd file with no users at all.
VALUE=$(sops -d --extract '["data"]["passwd"]' "$FILE" | base64 -d | python3 -c "$HASH_PY" "$USER_NAME")
if [ -z "$VALUE" ]; then
  echo "nothing to write" >&2
  exit 1
fi
printf '%s' "$VALUE" | sops set --value-stdin "$FILE" '["data"]["passwd"]'
