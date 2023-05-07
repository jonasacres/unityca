#!/bin/bash

# get the FQDN. Linux has -f option on the hostname command to get fqdn,
# and just shows hostname by default. OpenBSD has no such option, and
# always shows fqdn.

if [ -z "$FQDN" ]; then
	echo "No FQDN: $FQDN"
	FQDN=`hostname -f 2>/dev/null`
	if [ ! $? -eq 0 ]; then
		FQDN=`hostname`
	fi
fi

if [ -z "$UNITYCA_URL" ]; then
	UNITYCA_URL="https://ca.kobalabs.net"
fi

if [ -z "$HOSTNAMES" ]; then
	HOSTNAMES=`echo -n "$FQDN"`
fi

if [ -z "$IDENTITY_HOSTNAME" ]; then
	IDENTITY_HOSTNAME=`echo "$HOSTNAMES" | cut -d, -f1`
fi

if [ -z "$KEYFILE_PRIV" ]; then
	KEYFILE_PRIV="/etc/ssh/ssh_host_ed25519_key"
fi

if [ -z "$KEYFILE_CERT" ]; then
	KEYFILE_CERT="$KEYFILE_PRIV-cert.pub"
fi

if [ -z "$KEYFILE_PUB" ]; then
	KEYFILE_PUB="$KEYFILE_PRIV.pub"
fi

TIMESTAMP=`date +%s%N | cut -b1-13`
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
           | tail +2 \
           | head -n -1 \
           | tr -d "\n"`
REQUEST=$(echo "$SIGNED_PART" ; echo ; echo "$SIGNATURE" ; echo "$SIGNATURE")
echo "$REQUEST"

# now issue the request and (hopefully) get our certificate...
echo "Requesting certificate ($UNITYCA_URL)..."
CERTIFICATE=$(echo "$REQUEST" | curl -s -X POST --data-binary @- --fail "$UNITYCA_URL/host" 2>/dev/null)

if [ $? -eq 0 ]; then
	echo $CERTIFICATE > $KEYFILE_CERT
	echo "Success"
else
	echo "Server returned error"
	exit 1
fi
