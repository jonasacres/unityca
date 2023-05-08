#!/bin/sh

cmd_exists()
{
  command -v "$1" >/dev/null 2>&1
}

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
		echo "Need curl; unable to locate package manager."
		exit 1
	fi
fi

[ -z "$UNITYCA_URL" ] && UNITYCA_URL="https://ca.kobalabs.net"
[ -z "$SSHD_CONFIG" ] && SSHD_CONFIG="/etc/ssh/sshd_config"
[ -z "$DEFAULT_TRUSTED_USER_CA_KEYS" ] && DEFAULT_TRUSTED_USER_CA_KEYS="/etc/ssh/trusted_user_ca_keys"
[ -z "$HOST_GET_CERT_PATH" ] && HOST_GET_CERT_PATH="/sbin/host-get-cert.sh"
[ -z "$KEY_REVOCATION_SCRIPT_PATH" ] && KEY_REVOCATION_SCRIPT_PATH="/sbin/unityca-revoked-keys.sh"

# if we already have a TrustedUserCAKeys file in sshd_config, use that; otherwise, make one and add it to sshd_config
TRUSTED_USER_CA_KEYS=`cat "$SSHD_CONFIG" | grep -E "^TrustedUserCAKeys " | cut -d' ' -f2 | head -1`
if [ -z "$TRUSTED_USER_CA_KEYS" ]; then
	TRUSTED_USER_CA_KEYS=$DEFAULT_TRUSTED_USER_CA_KEYS

	echo "Adding to $SSHD_CONFIG: TrustedUserCAKeys $TRUSTED_USER_CA_KEYS"
	touch "$TRUSTED_USER_CA_KEYS"
	echo "TrustedUserCAKeys $TRUSTED_USER_CA_KEYS" >> "$SSHD_CONFIG"
fi

# get the user_ca.pub from the UnityCA server
USER_CA_KEY=`curl --fail -s "$UNITYCA_URL/user_ca.pub"`
if [ ! $? -eq 0 ]; then
	echo "Failed to get $UNITYCA_URL/user_ca.pub"
	exit 1
fi

# see if the key is already in the TrustedUserCAKeys file; if not then add it
EXISTING_USER_CA_KEY=`cat "$TRUSTED_USER_CA_KEYS" | grep "$USER_CA_KEY"`
if [ -z "$EXISTING_USER_CA_KEY" ]; then
	echo "Adding trusted CA key: $USER_CA_KEY"
	echo "$USER_CA_KEY" >> $TRUSTED_USER_CA_KEYS
fi

# now get the host-get-cert.sh script
curl -s --fail -o "$HOST_GET_CERT_PATH" "$UNITYCA_URL/scripts/host-get-cert.sh" 2>/dev/null
if [ ! $? -eq 0 ]; then
	echo "Failed to get $UNITYCA_URL/scripts/host-get-cert.sh"
	exit 1
fi

chmod +x "$HOST_GET_CERT_PATH"

# add crontab entry for host-get-cert.sh if we don't have one...
# (just check if the script is referenced on any lines, including commented-out lines
#   -- if so, don't add.)
EXISTING_CRONJOB=`crontab -l 2>/dev/null | grep "$HOST_GET_CERT_PATH"`
if [ -z "$EXISTING_CRONJOB" ]; then
	echo "Installing cronjob ($HOST_GET_CERT_PATH)..."
	(crontab -l 2>/dev/null ; echo "0 * * * * $HOST_GET_CERT_PATH") | crontab -
fi

# also set up the key revocation script
curl -s --fail -o "$KEY_REVOCATION_SCRIPT_PATH" "$UNITYCA_URL/scripts/unityca-revoked-keys.sh" 2>/dev/null
if [ ! $? -eq 0 ]; then
	echo "Failed to get $UNITYCA_URL/scripts/unityca-revoked-keys.sh"
	exit 1
fi

chmod +x "$KEY_REVOCATION_SCRIPT_PATH"

# and revocation cronjob...
EXISTING_CRONJOB=`crontab -l 2>/dev/null | grep "$KEY_REVOCATION_SCRIPT_PATH"`
if [ -z "$EXISTING_CRONJOB" ]; then
	echo "Installing cronjob ($KEY_REVOCATION_SCRIPT_PATH)..."
	(crontab -l 2>/dev/null ; echo "* * * * * $KEY_REVOCATION_SCRIPT_PATH") | crontab -
fi


# now run unityca-revoked-keys.sh
until "$KEY_REVOCATION_SCRIPT_PATH"
do
	echo "Retrying ($HOST_GET_CERT_PATH)..."
	sleep 1
done

# ...and also run host-get-cert.sh
until "$HOST_GET_CERT_PATH"
do
	echo "Retrying ($HOST_GET_CERT_PATH)..."
	sleep 1
done

# now restart sshd
if cmd_exists systemctl; then
	# systemd-based linux
	systemctl restart sshd
elif cmd_exists rcctl; then
	# openbsd
	rcctl restart sshd
else
	echo "Not sure how to restart SSHD on this system; you'll need to do that..."
fi
