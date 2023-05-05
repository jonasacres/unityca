#!/bin/sh

UNITYCA_URL="https://ca.kobalabs.net"
SSHD_CONFIG="/etc/ssh/sshd_config"
DEFAULT_TRUSTED_USER_CA_KEYS="/etc/ssh/trusted_user_ca_keys"
HOST_GET_CERT_PATH="/sbin/host-get-cert.sh"

# if we already have a TrustedUserCAKeys file in sshd_config, use that; otherwise, make one and add it to sshd_config
TRUSTED_USER_CA_KEYS=`cat "$SSHD_CONFIG" | grep -E "^TrustedUserCAKeys " | cut -d' ' -f2 | head -1`
if [[ -z $TRUSTED_USER_CA_KEYS ]]; then
	TRUSTED_USER_CA_KEYS=$DEFAULT_TRUSTED_USER_CA_KEYS

	echo "Adding to $SSHD_CONFIG: TrustedUserCAKeys $TRUSTED_USER_CA_KEYS"
	touch $TRUSTED_USER_CA_KEYS
	echo "TrustedUserCAKeys $TRUSTED_USER_CA_KEYS" >> "$SSHD_CONFIG"
fi

# get the user_ca.pub from the UnityCA server
USER_CA_KEY=`curl --fail -s "$UNITYCA_URL/user_ca.pub"`
if [ $? -eq 1 ]; then
	echo "Failed to get $UNITYCA_URL/user_ca.pub"
	exit 1
fi

# see if the key is already in the TrustedUserCAKeys file; if not then add it
EXISTING_USER_CA_KEY=`cat "$TRUSTED_USER_CA_KEYS" | grep "$USER_CA_KEY"`
if [[ -z $EXISTING_USER_CA_KEY ]]; then
	echo "Adding trusted CA key: $USER_CA_KEY"
	echo $USER_CA_KEY >> $TRUSTED_USER_CA_KEYS
fi

# now get the host-get-cert.sh script
curl -q --fail -o "$HOST_GET_CERT_PATH" "$UNITYCA_URL/host-get-cert.sh" 2>/dev/null
if [ $? -eq 1 ]; then
	echo "Failed to get $UNITYCA_URL/host-get-cert.sh"
	exit 1
fi

chmod +x $HOST_GET_CERT_PATH

# now add crontab entry for host-get-cert.sh...
EXISTING_CRONJOB=`crontab -l | grep "$HOST_GET_CERT_PATH"`
if [[ -z $EXISTING_CRONJOB ]]; then
	echo "Installing cronjob ($HOST_GET_CERT_PATH)..."
	(crontab -l ; echo "0 * * * * $HOST_GET_CERT_PATH") | crontab -
end

# now run host-get-cert.sh
until $HOST_GET_CERT_PATH
do
	echo "Retrying..."
	sleep 1
done
