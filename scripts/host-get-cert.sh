#!/bin/sh

# we need curl to continue; check if it exists
# if not, try to find the appropriate package manager and install
if [ ! command -v curl >/dev/null 2>&1 ]; then
	if [ command -v apt-get >/dev/null 2>&1 ]; then
		# linux, debian based
		apt install -y curl
		if [ ! $? -eq 0 ]; then
			echo "Unable to install curl."
			exit 1
		fi
	elif [ command -v yum >/dev/null 2>&1 ]; then
		# linux, red hat based
		yum install -y curl
		if [ ! $? -eq 0 ]; then
			echo "Unable to install curl."
			exit 1
		fi
	elif [ command -v pkg_add >/dev/null 2>&1 ]; then
		# openbsd
		pkg_add curl
		if [ ! $? -eq 0 ]; then
			echo "Unable to install curl."
			exit 1
		fi
	else
		# well shucks
		echo "Need curl."
		exit 1
	fi
fi

# get the FQDN. Linux has -f option on the hostname command to get fqdn,
# and just shows hostname by default. OpenBSD has no such option, and
# always shows fqdn.
FQDN=`hostname -f 2>/dev/null`
if [ ! $? -eq 0 ]; then
	FQDN=`hostname`
fi

HOSTNAMES=`echo -n $FQDN`
URL="https://ca.kobalabs.net/host"
KEYFILE_PRIV="/etc/ssh/ssh_host_ed25519_key"
KEYFILE_CERT="$KEYFILE_PRIV-cert.pub"
KEYFILE_PUB="$KEYFILE_PRIV.pub"
TIMESTAMP=`date +%s%N | cut -b1-13`
IDENTITY="unityca-$TIMESTAMP@$HOSTNAME"

# generate a key if we don't have one yet...
if [ ! -e $KEYFILE_PUB ]; then
	echo "Generating host key ($KEYFILE_PRIV)..."
	ssh-keygen -t ed25519 -f "$KEYFILE_PRIV"
fi

# now build our request...
KEY_PUB=`cat "$KEYFILE_PUB"`
SIGNED_PART=`echo $HOSTNAMES  ; \
	         echo $TIMESTAMP ; \
	         echo $KEY_PUB   ; \
	         echo $KEY_PUB`
SIGNATURE=`  echo -n $SIGNED_PART \
           | ssh-keygen -Y sign \
                        -I "$IDENTITY" \
                        -f "$KEYFILE_PRIV" \
                        -n "$HOSTNAMES" \
                        - \
                        2>/dev/null \
           | tail +2 \
           | head -n -1 \
           | tr -d "\n"`
REQUEST=`(echo $SIGNED_PART ; echo ; echo $SIGNATURE ; echo $SIGNATURE)`

# now issue the request and (hopefully) get our certificate...
echo "Requesting certificate ($URL)..."
CERTIFICATE=`echo $REQUEST | curl -s -X POST --data-binary - --fail "$URL" 2>/dev/null`

if [ $? -eq 0 ]; then
	echo $CERTIFICATE > $KEYFILE_CERT
	echo "Success"
else
	echo "Server returned error"
	exit 1
fi
