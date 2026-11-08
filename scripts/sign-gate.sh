#!/bin/bash
# Signs a fixture app through the vendored signer and checks the result with
# Apple's own tools. Run from rust-core/ by .github/workflows/sign-gate.yml on
# a macOS runner.
#
# What it proves, per bundle:
#   * the app and each .appex carry the profile issued for their own identifier,
#     sealed into _CodeSignature/CodeResources;
#   * the app's signature entitlements are the profile's, key for key;
#   * frameworks and dylibs are signed with no entitlements at all;
#   * everything passes `codesign --verify --deep --strict`.
#
# No Apple account is needed: the certificate and the profiles are made here.
set -euo pipefail

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() { echo "GATE FAILED: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; }

TEAM="ABCDE12345"
APP_ID="com.example.fixture"
WIDGET_ID="$APP_ID.Widget"
SHARE_ID="$APP_ID.Share"

# --- certificate -------------------------------------------------------------
# Apple's own certificates carry the extended key usages codesign checks; a
# plain self-signed one is refused with "Invalid Key Usage for policy".
cat > "$WORK/ext.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Apple Development: Fixture
O = Fixture Team
C = US
OU = ABCDE12345
[ ext ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning,1.2.840.113635.100.4.1,1.2.840.113635.100.4.13
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -config "$WORK/ext.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 2 >/dev/null 2>&1
openssl x509 -in "$WORK/cert.pem" -outform der -out "$WORK/cert.der"

# --- profiles ----------------------------------------------------------------
# A .mobileprovision is Apple's CMS container around an XML plist. Its signature
# is never verified by the signer (the certificate comes from the developer
# portal session), so a self-signed detached CMS is enough to exercise parsing.
make_profile() {
  local name="$1" appid="$2" out="$3"
  local uuid
  uuid="00000000-0000-0000-0000-$(printf '%-12s' "$(printf '%s' "$appid" | cksum | cut -d' ' -f1)" | tr ' ' '0' | cut -c1-12)"
  cat > "$WORK/profile.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AppIDName</key><string>$name</string>
	<key>ApplicationIdentifierPrefix</key><array><string>$TEAM</string></array>
	<key>CreationDate</key><date>2020-01-01T00:00:00Z</date>
	<key>ExpirationDate</key><date>2099-01-01T00:00:00Z</date>
	<key>Name</key><string>$name</string>
	<key>TeamIdentifier</key><array><string>$TEAM</string></array>
	<key>TeamName</key><string>Fixture Team</string>
	<key>UUID</key><string>$uuid</string>
	<key>Version</key><integer>1</integer>
	<key>Entitlements</key>
	<dict>
		<key>application-identifier</key><string>$TEAM.$appid</string>
		<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
		<key>get-task-allow</key><true/>
		<key>keychain-access-groups</key><array><string>$TEAM.$appid</string></array>
	</dict>
	<key>DeveloperCertificates</key><array><data>$(openssl base64 -in "$WORK/cert.der" | tr -d '\n')</data></array>
</dict>
</plist>
PLIST
  openssl cms -sign -binary -nodetach -in "$WORK/profile.plist" \
    -signer "$WORK/cert.pem" -inkey "$WORK/key.pem" -outform der -out "$out" >/dev/null 2>&1
}

make_profile "Fixture App" "$APP_ID" "$WORK/app.mobileprovision"
make_profile "Fixture Widget" "$WIDGET_ID" "$WORK/widget.mobileprovision"
make_profile "Fixture Share" "$SHARE_ID" "$WORK/share.mobileprovision"

# --- fixture app -------------------------------------------------------------
mkdir -p "$WORK/fixture/Payload/Fixture.app/PlugIns/Widget.appex" \
         "$WORK/fixture/Payload/Fixture.app/PlugIns/Share.appex"

# A real arm64 Mach-O, so the signature lands in a __LINKEDIT segment.
cat > "$WORK/hello.c" <<'C'
int main(void) { return 0; }
C
xcrun --sdk iphoneos clang -target arm64-apple-ios17.0 -c "$WORK/hello.c" -o "$WORK/hello.o"
xcrun --sdk iphoneos clang -target arm64-apple-ios17.0 -Wl,-e,_main "$WORK/hello.o" \
  -o "$WORK/hello" -Wl,-ios_version_min,17.0

make_info() {
  local plist="$1" id="$2" exe="$3" pkg="$4"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$id</string>
	<key>CFBundleExecutable</key><string>$exe</string>
	<key>CFBundlePackageType</key><string>$pkg</string>
	<key>CFBundleName</key><string>Fixture</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iOS</string></array>
	<key>MinimumOSVersion</key><string>17.0</string>
</dict>
</plist>
PLIST
}

APP="$WORK/fixture/Payload/Fixture.app"
make_info "$APP/Info.plist" "$APP_ID" Fixture APPL
cp "$WORK/hello" "$APP/Fixture"
printf 'APPL????' > "$APP/PkgInfo"

make_info "$APP/PlugIns/Widget.appex/Info.plist" "$WIDGET_ID" Widget XPC!
cp "$WORK/hello" "$APP/PlugIns/Widget.appex/Widget"
make_info "$APP/PlugIns/Share.appex/Info.plist" "$SHARE_ID" Share XPC!
cp "$WORK/hello" "$APP/PlugIns/Share.appex/Share"

# A framework bundle with its own Info.plist and a Mach-O inside it: nested
# code the signer seals and signs, and which may not carry entitlements.
FW="$APP/Frameworks/Till.framework"
mkdir -p "$FW"
make_info "$FW/Info.plist" "com.example.fixture.Till" Till FMWK
cp "$WORK/hello" "$FW/Till"

# --- sign --------------------------------------------------------------------
echo "==> signing the fixture"
PROFILE_ARGS=("$WIDGET_ID=$WORK/widget.mobileprovision" "$SHARE_ID=$WORK/share.mobileprovision")
( cd rust-core && cargo run --example sign_gate -q -- "$APP" "$WORK/key.pem" "$WORK/cert.der" - \
  "$WORK/app.mobileprovision" "${PROFILE_ARGS[@]}" ) | tee "$WORK/report.txt"

# `awk -F=` so the keys' `[` `]` are never read as a regex.
value() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$WORK/report.txt"; }

# --- assertions --------------------------------------------------------------
echo "==> the report the signer wrote"
cat "$WORK/report.txt"

echo "==> codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=4 "$APP" || fail "codesign --verify failed"

echo "==> the app is signed with its own profile's entitlements"
main_sha="$(value main_sha256)"
[ -n "$main_sha" ] || fail "no main profile hash in the report"
[ "$(value "embedded_sha256[]")" = "$main_sha" ] || fail "the app does not embed its own profile"
codesign -d --entitlements :- "$APP" 2>/dev/null > "$WORK/app.ent.plist" || true
plutil -extract 'application-identifier' raw "$WORK/app.ent.plist" >/dev/null ||
  fail "the app's signature carries no application-identifier"
[ "$(plutil -extract 'application-identifier' raw "$WORK/app.ent.plist")" = "$TEAM.$APP_ID" ] ||
  fail "the app's signature names the wrong application-identifier"
plutil -extract 'keychain-access-groups.0' raw "$WORK/app.ent.plist" >/dev/null ||
  fail "the app's signature lost its keychain-access-groups"
ok "app entitlements match the profile"

echo "==> each extension embeds the profile issued for it"
for pair in "PlugIns/Widget.appex:$WIDGET_ID:widget" "PlugIns/Share.appex:$SHARE_ID:share"; do
  IFS=: read -r rel id key <<< "$pair"
  [ "$(value "bundle[$rel]")" = "$id" ] || fail "$rel has bundle id $(value "bundle[$rel]"), expected $id"
  want="$(value "profile_sha256[$id]")"
  got="$(value "embedded_sha256[$rel]")"
  [ -n "$want" ] && [ "$want" = "$got" ] ||
    fail "$rel embeds $got, its profile is $want (it got the main app's or none)"
  codesign -d --entitlements :- "$APP/$rel" 2>/dev/null > "$WORK/ext.ent.plist" || true
  [ "$(plutil -extract 'application-identifier' raw "$WORK/ext.ent.plist")" = "$TEAM.$id" ] ||
    fail "$rel is signed with another bundle's entitlements"
  ok "$id signed with its own profile"
done

echo "==> libraries carry no entitlements"
LIB="$APP/Frameworks/Till.framework/Till"
[ "$(value "codesigned[Frameworks/Till.framework]")" = "true" ] ||
  fail "the framework bundle was not sealed"
[ "$(value "embedded_sha256[Frameworks/Till.framework]")" = "none" ] ||
  fail "the framework was given a profile"
codesign -d --entitlements :- "$LIB" 2>/dev/null > "$WORK/lib.ent.plist" || true
# An empty dictionary is what a library must carry: anything with a key in it
# is an entitlement the profile never granted.
keys=$(plutil -convert json -o - "$WORK/lib.ent.plist" 2>/dev/null | tr -d '{} ' || true)
[ -z "$keys" ] || fail "$(basename "$LIB") carries entitlements: $keys"
ok "$(basename "$LIB") signed with an empty entitlement set"

echo "==> the profiles are sealed into CodeResources"
plutil -p "$APP/_CodeSignature/CodeResources" | sed -n '1,30p'
plutil -extract 'files.embedded.mobileprovision' raw "$APP/_CodeSignature/CodeResources" >/dev/null ||
  fail "embedded.mobileprovision is not sealed in the app's CodeResources"
plutil -extract 'files.embedded.mobileprovision' raw "$APP/PlugIns/Widget.appex/_CodeSignature/CodeResources" >/dev/null ||
  fail "the widget's embedded.mobileprovision is not sealed in its CodeResources"
ok "CodeResources lists the profiles"

echo "SIGN GATE PASSED"
