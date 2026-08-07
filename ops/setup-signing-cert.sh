#!/bin/bash
# One-time setup: create the local code-signing identity the three macOS apps build with.
#
# WHY THIS EXISTS
# The apps used to be ad-hoc signed (CODE_SIGN_IDENTITY "-"). An ad-hoc signature's DESIGNATED
# REQUIREMENT is pinned to the cdhash, which changes on every rebuild — so macOS treats each build as
# a different program and forgets every TCC permission it was granted (Desktop / Documents /
# Downloads / Full Disk Access …). With the autonomous daemon rebuilding all day that means a consent
# dialog per build, forever, and no amount of clicking Allow ever sticks.
#
# A certificate-based signature pins the requirement to the CERT instead:
#     identifier "com.archivereader.app" and certificate leaf = H"<cert sha1>"
# which is byte-identical across rebuilds. One Allow, and it holds.
#
# The cert is SELF-SIGNED and never leaves this machine. Gatekeeper does not trust it and that is
# fine: these builds are local and unquarantined, and TCC keys off the designated requirement, not
# trust. Notarization is still out of scope.
#
# CONSEQUENCE YOU MUST KNOW ABOUT (it cost a debugging cycle on 2026-08-07):
# a self-signed cert has NO Team ID. ENABLE_HARDENED_RUNTIME: YES turns on library validation, which
# only loads code sharing the main binary's Team ID — and "no team" does not satisfy "same team". So
# Xcode 16's Debug build, whose code lives in <App>.debug.dylib inside the bundle, dies at launch with
# SIGABRT and takes every app-hosted test with it. The Debug entitlements therefore carry
# com.apple.security.cs.disable-library-validation. Release keeps hardened runtime AND strict
# validation. Don't remove that entitlement without re-reading this.
#
# Run this ONCE per machine. Interactive by design — step 5 raises a macOS password dialog.
set -euo pipefail

CN="Archive Suite Dev"
DAYS=3650                                        # ~10y. Expiry = a new cert = a new requirement = re-consent.
OUT="$HOME/.local/share/archive-suite-signing"   # durable key+cert; BACK THIS UP (see step 4)
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# 0. Refuse to make a SECOND cert with this name. Two identities sharing a CN make `codesign -s "$CN"`
#    fail with "ambiguous (matches ... and ...)", and it is not obvious that is what went wrong.
if security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "An identity named \"$CN\" already exists. Refusing to create a duplicate." >&2
  echo >&2
  security find-identity -p codesigning "$KEYCHAIN" >&2
  echo >&2
  echo "To replace it, delete the old one FIRST (by hash, so nothing else is touched):" >&2
  echo "  security delete-identity -Z <SHA-1> \"$KEYCHAIN\"" >&2
  echo "  security remove-trusted-cert $OUT/cert.pem" >&2
  exit 1
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 1. Extensions that make this a CODE SIGNING cert. Without extendedKeyUsage=codeSigning, codesign
#    will not accept it as an identity at all.
cat > "$WORK/cs.cnf" <<CNF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_cs
[ dn ]
CN = ${CN}
[ v3_cs ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CNF

# 2. Key + self-signed cert. /usr/bin/openssl (LibreSSL) deliberately: it writes a PKCS#12 the macOS
#    Security framework reads without the -legacy dance OpenSSL 3 needs. Note -nodes, NOT the
#    OpenSSL-3 spelling -noenc, which LibreSSL 3.3.6 does not know.
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days "$DAYS" -nodes \
  -config "$WORK/cs.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# 3. Bundle into a PKCS#12 so one `security import` brings in key + cert together.
#    Two non-obvious details, both learned the hard way:
#      * A REAL passphrase, never empty. PKCS#12 MACs "no password" and "empty-string password"
#        differently and macOS rejects the empty-password form with the actively misleading
#        "The user name or passphrase you entered is not correct."
#      * The FILE IS NAMED AFTER THE CN. macOS labels an imported private key from the p12's
#        filename when the key bag carries no friendlyName — so id.p12 produced a key labelled "id"
#        while its cert was labelled "Archive Suite Dev". Any attempt to then address the key by
#        label silently touched the wrong item.
P12PASS="$(/usr/bin/openssl rand -base64 24)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$CN" -out "$WORK/$CN.p12" -passout "pass:$P12PASS"

security import "$WORK/$CN.p12" -k "$KEYCHAIN" -P "$P12PASS" \
  -T /usr/bin/codesign -T /usr/bin/security -f pkcs12

# 4. Trust for code signing, USER trust store only (no sudo, nothing system-wide). Not required for
#    signing to work and irrelevant to TCC; it is what makes `find-identity -v` report it as valid.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

#    Durable copy: the unencrypted key + cert (600 in a 700 dir). Deliberately NOT the p12 — its
#    passphrase is a throwaway that dies with this script. Rebuild one when needed:
#      openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Archive Suite Dev" -out id.p12
#    LOSE THIS KEY AND YOU NEED A NEW CERT = a new designated requirement = re-grant every TCC prompt.
mkdir -p "$OUT"; chmod 700 "$OUT"
cp "$WORK/key.pem" "$WORK/cert.pem" "$OUT/"; chmod 600 "$OUT"/*

# 5. THE STEP THAT PROTECTS THE DAEMON. The -T ACL from step 3 is NOT sufficient on modern macOS: a
#    key's PARTITION LIST separately gates non-interactive use. Without this, the first codesign under
#    launchd raises "codesign wants to use your confidential information stored in ... in your
#    keychain" and the build hangs forever — exactly the freeze
#    ops/autonomous/archive-suite-autonomous.sh's header warns about.
#
#    Deliberately UNSCOPED (no -l): it covers every private signing key in the login keychain rather
#    than one addressed by label. Scoping by label is how this went wrong the first time — the label
#    matched a stale key and the real one kept prompting. Broadening it lets Apple's own tools use
#    those other keys without a prompt, which on a local dev machine is an acceptable trade for a
#    step that cannot silently miss.
#
#    No -k: the flag is deprecated and it would expose the password in the process list. macOS
#    prompts in a dialog instead.
echo "==> macOS will now ask for your login password (keychain partition list)."
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -t private "$KEYCHAIN"

# 6. Verify. NOTE THE METHOD: timing, not exit status. A keychain dialog needs a human, so a sign
#    completing in well under a second proves no prompt appeared. Checking `codesign` merely exited 0
#    cannot distinguish "never prompted" from "prompted and the operator clicked Allow" — which is
#    precisely the false pass that hid this bug for a whole debugging round.
echo
echo "--- codesigning identities ---"
security find-identity -v -p codesigning "$KEYCHAIN"

T="$WORK/verify.app/Contents/MacOS"; mkdir -p "$T"; cp /bin/echo "$T/verify"
cat > "$WORK/verify.app/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.archivesuite.signing-verify</string>
<key>CFBundleExecutable</key><string>verify</string>
</dict></plist>
P
echo
echo "--- non-interactive check (3 signs; each must be well under 1000 ms) ---"
/usr/bin/python3 - "$WORK/verify.app" "$CN" <<'EOF'
import subprocess, sys, time
app, cn = sys.argv[1], sys.argv[2]
slow = False
for i in range(3):
    t0 = time.monotonic()
    r = subprocess.run(["codesign", "--force", "--sign", cn, "--options", "runtime", app],
                       capture_output=True, text=True, timeout=120)
    ms = (time.monotonic() - t0) * 1000
    ok = r.returncode == 0 and ms < 1000
    slow = slow or not ok
    print(f"  sign {i+1}: rc={r.returncode} {ms:8.1f} ms  {'ok' if ok else 'PROMPTED or FAILED'}")
    if r.returncode:
        print("   ", r.stderr.strip()[:300])
sys.exit(1 if slow else 0)
EOF

echo
echo "Key + cert saved to: $OUT   <-- BACK THIS UP"
echo "The three macOS project.yml files already reference CODE_SIGN_IDENTITY: \"$CN\"."
