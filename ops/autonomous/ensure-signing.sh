#!/usr/bin/env bash
# ensure-signing.sh — make sure a STABLE local code-signing identity exists on this Mac.
#
# WHY: the Suite apps are ad-hoc signed ("-"), so every rebuild gets a NEW code identity. The macOS
# Keychain ties an item's "Always Allow" to the requesting app's code signature, so an ad-hoc rebuild is
# seen as a "different app" and the Keychain RE-PROMPTS for API-key access on every build — which blocks
# unattended autonomous runs (this actually happened, 2026-07-16). A stable self-signed cert gives one
# persistent Designated Requirement, so each provider item's "Always Allow" sticks across future rebuilds.
# ArchiveProcessor/launch.sh re-signs the built Debug app with this identity before launching it.
#
# The cert is LOCAL to this Mac's login keychain and is NEVER committed (it's a private key). It does not
# need to be Gatekeeper-trusted — codesign uses an untrusted self-signed identity fine, and the Keychain
# ACL matches on the (stable) Designated Requirement, not on trust.
#
# IDEMPOTENT: does nothing if the identity already exists. It deliberately does NOT regenerate an existing
# cert — a new cert = a new Designated Requirement = the Keychain would re-prompt once more.
set -u

CERT_CN="${SIGN_IDENTITY:-Archive Suite Dev}"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
  echo "ensure-signing: identity '$CERT_CN' already present — nothing to do."
  exit 0
fi

command -v openssl >/dev/null 2>&1 || { echo "ensure-signing: openssl not found — cannot create the dev cert."; exit 1; }
echo "ensure-signing: creating self-signed code-signing identity '$CERT_CN'…"

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
P12PASS="archive-suite-dev"   # transient PKCS#12 transport password; the key lands in the login keychain

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=$CERT_CN" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1 \
  || { echo "ensure-signing: openssl cert generation failed."; exit 1; }

# -legacy: OpenSSL 3's default PKCS#12 MAC/cipher can't be imported by macOS's Security framework.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
  -passout "pass:$P12PASS" -name "$CERT_CN" >/dev/null 2>&1 \
  || { echo "ensure-signing: PKCS#12 export failed."; exit 1; }

# -A: allow any tool (i.e. codesign) to use the private key WITHOUT a per-use Keychain prompt — this is a
#     local dev signing key, not a secret to guard. -T /usr/bin/codesign additionally whitelists codesign.
security import "$TMP/id.p12" -k "$LOGIN_KC" -P "$P12PASS" -A -T /usr/bin/codesign >/dev/null 2>&1 \
  || { echo "ensure-signing: keychain import failed."; exit 1; }

if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
  echo "ensure-signing: created '$CERT_CN' (self-signed; not Gatekeeper-trusted — fine, the Designated Requirement is stable)."
  exit 0
fi
echo "ensure-signing: WARNING — import reported OK but the identity isn't visible; builds will fall back to ad-hoc."
exit 1
