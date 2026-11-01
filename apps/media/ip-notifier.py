import json
import os
import time
import urllib.request

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID")
CHECK_INTERVAL = int(os.getenv("CHECK_INTERVAL", 300))
# Without a timeout a stalled request (e.g. tunnel reconnecting) would hang the loop.
HTTP_TIMEOUT = 30

last_ip = None

def get_public_ip():
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=HTTP_TIMEOUT) as resp:
            return resp.read().decode().strip()
    except Exception as e:
        print(f"Error getting IP: {e}")
        return None

def send_telegram(msg):
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        print("Telegram credentials missing")
        return

    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    payload = {"chat_id": TELEGRAM_CHAT_ID, "text": msg}
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )

    try:
        urllib.request.urlopen(req, timeout=HTTP_TIMEOUT).close()
    except Exception as e:
        print(f"Error sending Telegram message: {e}")

def check_ip():
    global last_ip
    current_ip = get_public_ip()

    if current_ip is None:
        return

    if last_ip is None:
        last_ip = current_ip
        send_telegram(f"Public IP Notifier started.\nCurrent IP: {current_ip}")
        print(f"Initial IP: {current_ip}")
        return

    if current_ip != last_ip:
        send_telegram(f"Public IP changed!\nOld: {last_ip}\nNew: {current_ip}")
        print(f"IP changed: {last_ip} -> {current_ip}")
        last_ip = current_ip
    else:
        print(f"No change. IP is still {current_ip}")

print("Public IP Notifier started")

while True:
    check_ip()
    time.sleep(CHECK_INTERVAL)
