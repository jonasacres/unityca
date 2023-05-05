#!/bin/sh

URL="https://ca.kobalabs.net/host"
KEYFILE_PRIV="/etc/ssh/ssh_host_ed25519_key"
KEYFILE_CERT="$KEYFILE_PRIV-cert.pub"
KEYFILE_PUB="$KEYFILE_PRIV.pub"
TIMESTAMP=`date +%s%N | cut -b1-13`

# generate a key if we don't have one yet...
if [ ! -e $KEYFILE_PUB ]; then
	echo "Generating host key ($KEYFILE_PRIV)..."
	ssh-keygen -t ed25519 -f "$KEYFILE_PRIV"
fi

# now build our request...
KEY_PUB=`cat "$KEYFILE_PUB" | tr -d "\n"`
SIGNED_PART="$HOSTNAME\n$TIMESTAMP\n$KEY_PUB\n$KEY_PUB"
SIGNATURE=`echo -n $SIGNED_PART | ssh-keygen -Y sign -f "$KEYFILE_PRIV" -n "enrollment" - 2>/dev/null | tail +2 | head -n -1 | tr -d "\n"`
REQUEST=`(echo $SIGNED_PART ; echo ; echo $SIGNATURE ; echo $SIGNATURE)`

# now issue the request and (hopefully) get our certificate...
echo "Requesting certificate ($URL)..."
CERTIFICATE=`echo $REQUEST | curl -s -X POST --data-binary - --fail "$URL" 2>/dev/null`

if [ $? -eq 0 ]; then
	echo $CERTIFICATE > $KEYFILE_CERT
	echo "Success"
else
	echo "Server returned error"
fi
