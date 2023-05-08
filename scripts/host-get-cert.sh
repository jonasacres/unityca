#!/bin/sh

cmd_exists()
{
  command -v "$1" >/dev/null 2>&1
}

if cmd_exists curl; then
  CURL="curl"
elif cmd_exists /usr/local/bin/curl; then
  CURL="/usr/local/bin/curl"
elif cmd_exists /usr/bin/curl; then
  CURL="/usr/bin/curl"
else
  echo "Unable to locate curl"
fi

# get the FQDN. Linux has -f option on the hostname command to get fqdn,
# and just shows hostname by default. OpenBSD has no such option, and
# always shows fqdn.

if [ -z "$FQDN" ]; then
	FQDN=`hostname -f 2>/dev/null`
	if [ ! $? -eq 0 ]; then
		FQDN=`hostname`
	fi
fi

[ -z "$UNITYCA_URL" ] && UNITYCA_URL="https://ca.kobalabs.net"
[ -z "$HOSTNAMES" ] && HOSTNAMES=`echo -n "$FQDN"`
[ -z "$IDENTITY_HOSTNAME" ] && IDENTITY_HOSTNAME=`echo "$HOSTNAMES" | cut -d, -f1`
[ -z "$KEYFILE_PRIV" ] && KEYFILE_PRIV="/etc/ssh/ssh_host_ed25519_key"
[ -z "$KEYFILE_CERT" ] && KEYFILE_CERT="$KEYFILE_PRIV-cert.pub"
[ -z "$KEYFILE_PUB" ] && KEYFILE_PUB="$KEYFILE_PRIV.pub"
[ -z "$SSHD_CONFIG" ] && SSHD_CONFIG="/etc/ssh/sshd_config"

TIMESTAMP=`date +%s`
IDENTITY="unityca-$TIMESTAMP@$IDENTITY_HOSTNAME"

# generate a key if we don't have one yet...
if [ ! -e $KEYFILE_PUB ]; then
	echo "Generating host key ($KEYFILE_PRIV)..."
	ssh-keygen -t ed25519 -f "$KEYFILE_PRIV"
fi

# now build our request...
KEY_PUB=`cat "$KEYFILE_PUB"`
SIGNED_PART=`echo "$HOSTNAMES"  ; \
	         echo "$TIMESTAMP" ; \
	         echo "$KEY_PUB"   ; \
	         echo "$KEY_PUB"`
SIGNATURE=`  echo "$SIGNED_PART" \
           | ssh-keygen -Y sign \
                        -I "$IDENTITY" \
                        -f "$KEYFILE_PRIV" \
                        -n "$HOSTNAMES" \
                        - \
                        2>/dev/null \
           | grep -v "SIGNATURE" \
           | tr -d "\n"`
REQUEST=$(echo "$SIGNED_PART" ; echo ; echo "$SIGNATURE" ; echo "$SIGNATURE")

# now issue the request and (hopefully) get our certificate...
echo "Requesting certificate ($UNITYCA_URL)..."
CERTIFICATE=$(echo "$REQUEST" | "$CURL" -s -X POST --data-binary @- --fail "$UNITYCA_URL/host" 2>/dev/null)

if [ $? -eq 0 ]; then
	echo $CERTIFICATE > $KEYFILE_CERT
	echo "Success (obtained fresh certificate)"
else
	echo "Server returned error"
	exit 1
fi

# now do the HostCertificate line...
HOST_CERTIFICATE=`cat "$SSHD_CONFIG" | grep -E "^HostCertificate " | cut -d' ' -f2 | head -1`
if [ -z "$HOST_CERTIFICATE" ]; then
	echo "Adding to $SSHD_CONFIG: HostCertificate $KEYFILE_CERT"
	echo "HostCertificate $KEYFILE_CERT" >> "$SSHD_CONFIG"
fi
