#!/bin/zsh
# One-time, run while signed in at the Pro: unlock the SnapNow signing keychain and set it to
# never auto-lock (no lock on sleep, no idle timeout). After this tools/install.sh signs from any
# session - SSH, Herdr pane, screen locked - without needing the login keychain. The keychain's
# password is read from the login keychain (service snaplite-signing-keychain) and never stored
# or printed. Re-run if the keychain ever shows as locked again (e.g. after a reboot).
set -euo pipefail
keychain=~/Library/Keychains/snaplite-signing.keychain-db
[[ -e $keychain ]] || { echo "no $keychain - run tools/setup-signing-keychain.sh first" >&2; exit 1; }
if ! security show-keychain-info "$keychain" >/dev/null 2>&1; then
  pw=$(security find-generic-password -a "$USER" -s snaplite-signing-keychain -w) \
    || { echo "could not read the keychain password from the login keychain - are you signed in at this Mac?" >&2; exit 1; }
  security unlock-keychain -p "$pw" "$keychain"
  unset pw
fi
security set-keychain-settings "$keychain"       # no -l (lock on sleep), no -t (timeout): stays unlocked
echo -n "snaplite-signing keychain: unlocked, settings now: "; security show-keychain-info "$keychain" 2>&1
