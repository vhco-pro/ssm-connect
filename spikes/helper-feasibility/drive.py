#!/usr/bin/env python3
"""Drives the feasibility helper through the T5 live scenario and prints a transcript.

Usage: drive.py <helper> <plugin> <profile.json> [local-port]

profile.json holds startUrl, ssoRegion, accountId, roleName, region, tagKey and tagValue
(keep it outside the repository). The scenario: sign in with SSO device authorization
(the verification URL is printed for a person to approve), read the caller identity, find
the workstation by tag, open a port-forward tunnel through the Session Manager plugin,
refresh the SSO token, stop the tunnel, open it again and quit with it open. After each
stop and the quit it checks that the plugin process the helper started is gone.

It changes nothing in AWS beyond the SSM sessions it opens: no instance is started or
stopped. Credentials never reach this script; the helper keeps them.
"""
import json
import os
import subprocess
import sys
import time


def alive(pid):
    if os.name == "nt":
        out = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/NH"], capture_output=True, text=True).stdout
        return str(pid) in out
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def main():
    helper, plugin, profile_path = sys.argv[1:4]
    local_port = int(sys.argv[4]) if len(sys.argv) > 4 else 18443
    profile = json.load(open(profile_path))
    proc = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)

    def say(text):
        print(f"{time.strftime('%H:%M:%S')} {text}", flush=True)

    def send(command):
        proc.stdin.write(json.dumps(command) + "\n")
        proc.stdin.flush()

    def wait(cid, done_events, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = proc.stdout.readline()
            if not line:
                raise SystemExit("helper exited")
            event = json.loads(line)
            if event.get("id") not in (cid, None):
                continue
            shown = {k: v for k, v in event.items() if k != "id"}
            say(f"[{cid}] {json.dumps(shown, sort_keys=True)}")
            if event["event"] == "verify":
                say(f"APPROVE IN A BROWSER: {event['url']}  (code {event['userCode']})")
            if event["event"] in done_events or event["event"] == "failed":
                return event
        raise SystemExit(f"timed out waiting for {cid}")

    say(f"helper {helper}, plugin {plugin}, local port {local_port}")
    say(f"[start] {proc.stdout.readline().strip()}")

    send({"id": "signin", "cmd": "signIn", **{k: profile[k] for k in ("startUrl", "ssoRegion", "accountId", "roleName", "region")}})
    if wait("signin", {"signedIn"}, 700)["event"] != "signedIn":
        raise SystemExit("sign-in failed")

    send({"id": "identity", "cmd": "identity"})
    wait("identity", {"identity"}, 60)

    send({"id": "describe", "cmd": "describe", "tagKey": profile["tagKey"], "tagValue": profile["tagValue"]})
    found = wait("describe", {"instances"}, 60)
    running = [i for i in found.get("instances", []) if i["state"] == "running"]
    if not running:
        raise SystemExit("no running workstation; the scenario does not start instances")
    instance = running[0]["instanceId"]

    tunnel = {"cmd": "tunnel", "instanceId": instance, "remotePort": profile.get("remotePort", 8443),
              "localPort": local_port, "pluginPath": plugin}
    send({"id": "tunnel1", **tunnel})
    started = None
    deadline = time.time() + 90
    while time.time() < deadline:
        event = wait("tunnel1", {"pluginStarted", "tunnelReady"}, 90)
        if event["event"] == "pluginStarted":
            started = event["pid"]
            continue
        break
    if event["event"] != "tunnelReady":
        raise SystemExit("tunnel failed")
    say(f"plugin pid {started} alive: {alive(started)}")

    send({"id": "refresh", "cmd": "refresh"})
    wait("refresh", {"refreshed"}, 60)

    send({"id": "stop", "cmd": "stop"})
    wait("stop", {"stopped"}, 30)
    time.sleep(1)
    say(f"after stop, plugin pid {started} alive: {alive(started)}")

    send({"id": "tunnel2", **tunnel})
    second = None
    while True:
        event = wait("tunnel2", {"pluginStarted", "tunnelReady"}, 90)
        if event["event"] == "pluginStarted":
            second = event["pid"]
            continue
        break
    send({"id": "quit", "cmd": "quit"})
    wait("quit", {"bye"}, 30)
    proc.wait(timeout=30)
    time.sleep(1)
    say(f"after quit with the tunnel open, plugin pid {second} alive: {alive(second)}; helper exit {proc.returncode}")


if __name__ == "__main__":
    main()
