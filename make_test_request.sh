#!/bin/bash

UNITYCA_URL="http://localhost:8080/host"
HOSTNAMES="turing.kobalabs.net,turing.unitymath.io"
IDENTITY_HOSTNAME="turing.kobalabs.net"
HOSTNAMES="$HOSTNAME$BONUSHOSTNAMES"
TIMESTAMP=`date +%s%N | cut -b1-13 | tr -d "\n"`
KEYFILE_PRIV="/tmp/testkey.unityca"
KEYFILE_PUB="$KEYFILE_PRIV.pub"
IDENTITY="unityca-$TIMESTAMP@$IDENTITY_HOSTNAME"

SIGFILE="/tmp/signature.unityca"
SIGNERSFILE="/tmp/allowed_signers.unityca"
TESTFILE_BASE="/tmp/request.unityca"
TESTFILE_NOSIG="$TESTFILE_BASE.signed_part"

if [ ! -e $KEYFILE_PRIV ]; then
	ssh-keygen -f "$KEYFILE_PRIV" -t ed25519 -N "" >/dev/null
fi

(echo $HOSTNAMES  ; \
 echo $TIMESTAMP  ; \
 cat $KEYFILE_PUB ; \
 cat $KEYFILE_PUB \
) > $TESTFILE_NOSIG

(   cat "$TESTFILE_NOSIG" \
  | ssh-keygen -Y sign \
               -I "$IDENTITY" \
               -f "$KEYFILE_PRIV" \
               -n "$HOSTNAMES" \
               - \
               2>/dev/null \
) > "$SIGFILE"

SIGNATURE=`( \
	  cat "$SIGFILE" \
	| tail +2 \
	| head -n -1 \
	| tr -d "\n" \
	; echo)`
(echo -n "$IDENTITY " ; cat "$KEYFILE_PUB" | cut -d' ' -f1,2) > $SIGNERSFILE
(cat "$TESTFILE_NOSIG" ; echo ; echo "$SIGNATURE" ; echo "$SIGNATURE") > "$TESTFILE_BASE"
(cat "$TESTFILE_NOSIG" | ssh-keygen -Y verify \
                                    -I "$IDENTITY" \
                                    -n "$HOSTNAMES" \
                                    -s "$SIGFILE" \
                                    -f "$SIGNERSFILE")

if [[ $? -eq 0 ]]; then
    rm -f /tmp/unityca.tmp*
    echo "Signature constructed and verified. Sending request."
    curl -sv -X POST --data-binary "@$TESTFILE_BASE" "$UNITYCA_URL"
    if [[ ! $? -eq 0 ]]; then
        exit 1
    fi
fi
