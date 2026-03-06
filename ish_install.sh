#!/bin/sh

# update apk index
apk update
# add python3 pip and cryptography dependencies
apk add python3 python3-dev py3-cryptography py3-pip wget
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

MAX_WAIT=30
WAIT_COUNT=0
while [ ! -f ~/.reticulum/config ]; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo "Error: Config generation timed out after ${MAX_WAIT}s"
        kill $RNS_PID
        exit 1
    fi
    echo "waiting for config file to be created... (${WAIT_COUNT}s)"
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

sleep 1
kill $RNS_PID

python3 - <<EOF
import sys
import json
import urllib.request
import urwid
import os

CONFIG_PATH = os.path.expanduser("~/.reticulum/config")
BELETH_FALLBACK = "[[Beleth RNS Hub]]\n  type = TCPClientInterface\n  enabled = yes\n  target_host = rns.beleth.net\n  target_port = 4242"

def fetch_interfaces():
    url = "https://directory.rns.recipes/api/directory/submitted?search=&type=tcp&status=online"
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read().decode())['data']
            return [i for i in data if i.get('network') == 'clearnet']
    except:
        return []

def run_ui(choices):
    result = {"config": ""}
    def item_chosen(button, config):
        result["config"] = config
        raise urwid.ExitMainLoop()
    def exit_on_q(key):
        if key in ('q', 'Q'): raise urwid.ExitMainLoop()

    body = [urwid.Text("Select RNS Interface (Q to quit)"), urwid.Divider()]
    for item in choices:
        button = urwid.Button(item['name'])
        urwid.connect_signal(button, 'click', item_chosen, item['config'])
        body.append(urwid.AttrMap(button, None, focus_map='reversed'))

    view = urwid.Frame(urwid.AttrMap(urwid.ListBox(urwid.SimpleFocusListWalker(body)), 'normal'))
    loop = urwid.MainLoop(view, palette=[('reversed', 'black', 'white')], unhandled_input=exit_on_q)
    loop.run()
    return result["config"]

# --- Main Execution Flow ---
clearnet_interfaces = fetch_interfaces()

# Determine selected config
if not clearnet_interfaces:
    selected_config = BELETH_FALLBACK
elif sys.stdin.isatty():
    selected_config = run_ui(clearnet_interfaces)
    if not selected_config: selected_config = clearnet_interfaces[0]['config']
else:
    selected_config = clearnet_interfaces[0]['config']

# --- File Manipulation ---
if not os.path.exists(CONFIG_PATH):
    print(f"Error: {CONFIG_PATH} not found.")
    sys.exit(1)

with open(CONFIG_PATH, 'r') as f:
    lines = f.readlines()

# Check for existence of Default Interface
target_marker = "[[Default Interface]]"
marker_index = -1
for i, line in enumerate(lines):
    if target_marker in line:
        marker_index = i
        break

if marker_index != -1:
    print(f"Found {target_marker}, replacing with selected interface...")
    # Keep everything up to the marker, then append the new config
    new_content = lines[:marker_index]
    with open(CONFIG_PATH, 'w') as f:
        f.writelines(new_content)
        f.write("\n" + selected_config + "\n")
    print("Config updated successfully.")
else:
    print("Default Interface section does not exist. No changes made to config.")

EOF

echo "reticulum has been configured. run nomadnet to begin browsing"
