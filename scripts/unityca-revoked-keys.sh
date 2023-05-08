#!/bin/sh

[ -z "$UNITYCA_URL" ] && UNITYCA_URL="https://ca.kobalabs.net"
[ -z "$SSHD_CONFIG" ] && SSHD_CONFIG="/etc/ssh/sshd_config"
[ -z "$DEFAULT_REVOKED_KEYS" ] && DEFAULT_REVOKED_KEYS="/etc/ssh/sshd_revoked_keys"

# if we already have a TrustedUserCAKeys file in sshd_config, use that; otherwise, make one and add it to sshd_config
REVOKED_KEYS=`cat "$SSHD_CONFIG" | grep -E "^RevokedKeys " | cut -d' ' -f2 | head -1`
if [ -z "$REVOKED_KEYS" ]; then
  REVOKED_KEYS=$DEFAULT_REVOKED_KEYS

  echo "Adding to $SSHD_CONFIG: RevokedKeys $REVOKED_KEYS"
  echo "RevokedKeys $REVOKED_KEYS" >> "$SSHD_CONFIG"
  echo "(You'll need to restart sshd after this.)"
fi

# if we already have a revoked keys file, but no corresponding .local file, we must have already had
# revoked keys set up external to this script... so we'll initialize the corresponding sshd_revoked_keys.local
# file with those keys, and include those in every autogenerated sshd_revoked_keys list.
if [ ! -e "$REVOKED_KEYS.local" ]; then
  if [ -e "$REVOKED_KEYS" ]; then
    mv "$REVOKED_KEYS" "$REVOKED_KEYS.local"
  else
    # no existing keys, so just make an empty list
    touch "$REVOKED_KEYS.local"
  fi
fi

touch "$REVOKED_KEYS"


SERVER_REVOKED_LIST=$(curl -s --fail "$UNITYCA_URL/revoked" 2>/dev/null)
if [ ! $? -eq 0 ]; then
  echo "Encountered error querying for $UNITYCA_URL/revoked"
  exit 1
fi

(echo "# Autogenerated from unity-ca-revoked-keys.sh. Add locally-revoked keys to '$REVOKED_KEYS.local' instead." ; \
 echo "# Generated at $(date)" ; \
 echo "$SERVER_REVOKED_LIST" ; \
) | cat - "$REVOKED_KEYS.local" > "$REVOKED_KEYS"

echo "Success (updated revocation list)"
