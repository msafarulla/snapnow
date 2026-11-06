#!/bin/zsh
# Build SnapNow (macOS), sign it, install it to /Applications and launch it.
#
#   tools/install.sh [--no-build] [--local-only | --push-only]
#
# Signing: macOS ties the Screen Recording permission to the app's signature. With a stable identity
# (SNAPLITE_SIGN_IDENTITY, or a SHA-1 in ~/.config/snaplite/signing-identity, optionally kept in the
# keychain ~/Library/Keychains/snaplite-signing.keychain-db) rebuilds keep the permission; without one
# the app is signed ad hoc and macOS asks for the permission again after each rebuild.
#
# Second Mac: set SNAPLITE_PUSH_HOST=user@host (or put it in ~/.config/snaplite/push-host) to also
# copy the signed app there over SSH.
set -euo pipefail
cd "${0:A:h}/.."
export PATH=/opt/homebrew/bin:$HOME/.gem/bin:$PATH
[[ -d $HOME/.gem ]] && export GEM_HOME=$HOME/.gem   # CocoaPods installed as a user gem
app=build/macos/Build/Products/Release/SnapNow.app
config=~/.config/snaplite

# Copies the installed app to `host` safely, even over a connection that keeps dropping: rsync resumes
# where it stopped (each attempt adds to the copy), the copy's signature is checked, and only then is it
# swapped in, keeping the old app until the new one is in place.
push_to() {
  local host=$1 ok=""
  for attempt in $(seq 1 ${SNAPLITE_PUSH_TRIES:-40}); do
    if rsync -a --delete --partial --timeout=20 -e "ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=5" \
         /Applications/SnapNow.app/ "$host:/tmp/SnapNow-staged.app/" 2>/dev/null &&
       ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" 'codesign --verify --deep --strict /tmp/SnapNow-staged.app' 2>/dev/null; then
      ok=1; break
    fi
    echo "copy to $host interrupted (attempt $attempt), resuming…" >&2; sleep 15
  done
  [[ -n $ok ]] || { echo "error: could not copy SnapNow to $host; its current app is untouched" >&2; return 1; }
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" 'set -e
    pkill -x SnapNow || true; pkill -x SnapLite || true; sleep 1
    rm -rf /Applications/SnapNow.app.old /Applications/SnapLite.app   # SnapLite.app: the name before 1.21
    [ -d /Applications/SnapNow.app ] && mv /Applications/SnapNow.app /Applications/SnapNow.app.old
    cp -R /tmp/SnapNow-staged.app /Applications/SnapNow.app
    codesign --verify --deep --strict /Applications/SnapNow.app
    rm -rf /Applications/SnapNow.app.old
    open /Applications/SnapNow.app
    echo "installed on '"$host"': $(defaults read /Applications/SnapNow.app/Contents/Info CFBundleShortVersionString)"'
}

if [[ " $* " == *" --push-only "* ]]; then # just copy the installed app to the second Mac
  host=${SNAPLITE_PUSH_HOST:-$(cat $config/push-host 2>/dev/null || true)}
  [[ -n $host ]] || { echo "error: no push host" >&2; exit 1; }
  push_to "$host"; exit $?
fi

[[ " $* " == *" --no-build "* ]] || flutter build macos --release
cp LICENSE THIRD_PARTY_NOTICES "$app/Contents/Resources/" # libwebp's BSD notice travels with the app

identity=${SNAPLITE_SIGN_IDENTITY:-$(cat $config/signing-identity 2>/dev/null || true)}
keychain=~/Library/Keychains/snaplite-signing.keychain-db
if [[ -n $identity ]]; then
  keychain_args=()
  if [[ -e $keychain ]]; then
    # Already unlocked (tools/keep-signing-unlocked.sh sets it to never auto-lock, so this is the
    # normal case, screen locked or not): nothing to do. Otherwise its password lives in the login
    # keychain - read here, never stored - which macOS only hands out while the user is signed in
    # at this Mac; say so instead of a cryptic "passphrase not correct".
    if ! security show-keychain-info "$keychain" >/dev/null 2>&1; then
      pw=$(security find-generic-password -a "$USER" -s snaplite-signing-keychain -w 2>/dev/null || true)
      if [[ -z $pw ]] || ! security unlock-keychain -p "$pw" "$keychain"; then
        echo "signing keychain is locked and the login keychain won't give its password (not signed in at this Mac?)." >&2
        echo "Sign in at the Pro and run tools/keep-signing-unlocked.sh once; then this works from anywhere." >&2
        exit 1
      fi
      unset pw
    fi
    keychain_args=(--keychain "$keychain")
  fi
  codesign --force --deep "${keychain_args[@]}" --sign "$identity" "$app"
  codesign --force "${keychain_args[@]}" --sign "$identity" --identifier com.mm.SnapLite \
    --entitlements macos/Runner/Release.entitlements "$app"
else
  echo "note: no signing identity; signing ad hoc (Screen Recording permission resets on each rebuild)" >&2
  codesign --force --deep --sign - --entitlements macos/Runner/Release.entitlements "$app"
fi
codesign --verify --deep --strict "$app"

pkill -x SnapNow || true; pkill -x SnapLite || true
sleep 1
rm -rf /Applications/SnapNow.app /Applications/SnapLite.app   # SnapLite.app: the name before 1.21
cp -R "$app" /Applications/
open /Applications/SnapNow.app
echo "installed: $(defaults read /Applications/SnapNow.app/Contents/Info CFBundleShortVersionString)"

host=${SNAPLITE_PUSH_HOST:-$(cat $config/push-host 2>/dev/null || true)}
[[ " $* " == *" --local-only "* || -z $host ]] && exit 0
push_to "$host"
