#!/bin/sh

# update apk index
apk update
# add python3 pip and cryptography dependencies
apk add python3 python3-dev py3-cryptography wget
# must run with --no-deps because cryptography is installed via apk
pip install rns --no-deps
pip install lxmf --no-deps
pip install urwid
pip install qrcode
pip install nomadnet --no-deps

# must patch TCPInterface.py to allow running through iSH 
# iSH shares network with iOS and fails when setting timeouts with setsockopt 

# get path to TCPInterface.py
TCPINTERFACE_PATH=$(python3 -c "import os, RNS; print(os.path.join(os.path.dirname(RNS.__file__), 'Interfaces', 'TCPInterface.py'))")

echo "patching TCPInterface at: $TCPINTERFACE_PATH"

# download and replace TCPInterface.py
wget -q -O "$TCPINTERFACE_PATH" "https://raw.githubusercontent.com/robertlarue/Reticulum/refs/heads/master/RNS/Interfaces/TCPInterface.py"

echo "starting rnsd to generate config file"
rnsd &
RNS_PID=$!

while [ ! -f ~/.reticulum/config ]; do
  echo "waiting for config file to be created..."
  sleep 0.5
done

sleep 1
kill $RNS_PID

# API for RNS directory
API_URL="https://directory.rns.recipes/api/directory/submitted?search=&type=tcp&status=online"
# Get a list of TCP interfaces from API
JSON_DATA=$(wget -T 10 -qO- "$API_URL")

# default TCP client config
DEFAULT_CONFIG="[[Beleth RNS Hub]]\n  type = TCPClientInterface\n  enabled = yes\n  target_host = rns.beleth.net\n  target_port = 4242"

# check if API is available
if [ -z "$JSON_DATA" ]; then
    echo "API unavailable, falling back to default TCP interface"
    SELECTED_CONFIG=$DEFAULT_CONFIG
else
    # Parse clearnet interfaces
    PARSED_INTERFACES=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])['data']
    clearnet = [i for i in data if i.get('network') == 'clearnet']
    for i, item in enumerate(clearnet):
        print(f\"{i}|{item['name']}|{item['config']}\")
except:
    pass
" "$JSON_DATA")

    if [ -z "$PARSED_INTERFACES" ]; then
        echo "no clearnet interfaces found, falling back to default TCP interface"
        SELECTED_CONFIG=$DEFAULT_CONFIG
    elif [ -t 0 ]; then
        # Interactive Mode
        echo "\n--- available TCP interfaces ---"
        echo "$PARSED_INTERFACES" | awk -F'|' '{print $1") "$2}'
        printf "\nselect an interface number [default: 0]: "
        read -r CHOICE
        [ -z "$CHOICE" ] && CHOICE=0
        SELECTED_CONFIG=$(echo "$PARSED_INTERFACES" | grep "^$CHOICE|" | cut -d'|' -f3-)
    else
        # Non-interactive Mode (Pick first available)
        SELECTED_CONFIG=$(echo "$PARSED_INTERFACES" | head -n 1 | cut -d'|' -f3-)
    fi
fi

echo "saving interface to reticulum config file:\n$SELECTED_CONFIG"

# remove default interface and save TCP interface to reticulum config file
sed -i '/\[\[Default Interface\]\]/,$d' ~/.reticulum/config
echo -e "$SELECTED_CONFIG" >> ~/.reticulum/config

echo "reticulum has been configured. run nomadnet to begin browsing"
