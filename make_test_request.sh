#!/bin/bash

URL="http://localhost:8080/host"
HOSTNAME="turing.kobalabs.net"
BONUSHOSTNAMES=",turing.unitymath.io"
HOSTNAMES="$HOSTNAME$BONUSHOSTNAMES"
TIMESTAMP=`date +%s%N | cut -b1-13 | tr -d "\n"`
KEYFILE="/tmp/testkey.unityca"
KEYFILE_PUB="$KEYFILE.pub"
IDENTITY="unityca-$TIMESTAMP@$HOSTNAME"

SIGFILE="/tmp/signature.unityca"
SIGNERSFILE="/tmp/allowed_signers.unityca"
TESTFILE_BASE="/tmp/request.unityca"
TESTFILE_NOSIG="$TESTFILE_BASE.signed_part"

if [ ! -e $KEYFILE ]; then
	ssh-keygen -f "$KEYFILE" -t ed25519 -N "" >/dev/null
fi

(echo $HOSTNAMES  ; \
 echo $TIMESTAMP  ; \
 cat $KEYFILE_PUB ; \
 cat $KEYFILE_PUB \
) > $TESTFILE_NOSIG

(   cat "$TESTFILE_NOSIG" \
  | ssh-keygen -Y sign \
               -I "$IDENTITY" \
               -f "$KEYFILE" \
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
(echo -n "$IDENTITY " ; cat $KEYFILE_PUB | cut -d' ' -f1,2) > $SIGNERSFILE
(cat "$TESTFILE_NOSIG" ; echo ; echo $SIGNATURE ; echo $SIGNATURE) > "$TESTFILE_BASE"
(cat "$TESTFILE_NOSIG" | ssh-keygen -Y verify \
                                    -n "$HOSTNAMES" \
                                    -s "$SIGFILE" \
                                    -I "$IDENTITY" \
                                    -f "$SIGNERSFILE")

if [[ $? -eq 0 ]]; then
    rm -f /tmp/unityca.tmp*
    echo "Signature constructed and verified. Sending request."
    curl -sv -X POST --data-binary "@$TESTFILE_BASE" "$URL"
    if [[ ! $? -eq 0 ]]; then
        exit 1
    fi
fi
