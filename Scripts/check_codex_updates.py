#!/usr/bin/python3
"""Daily local reminder. No model calls, compatibility tests, or Codex messages."""
import datetime
import fcntl
import hashlib
import html
import json
import os
import pathlib
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET


PROJECT = pathlib.Path(__file__).resolve().parents[1]
STATE = pathlib.Path.home() / "Library/Application Support/CodexKeeper/update-reminder/state.json"
FEED = "https://github.com/openai/codex/releases.atom"
IMPACT = {
    "服务/通信": r"\b(?:app[- ]server|daemon|background server|ipc|stdio|websocket)\b",
    "额度": r"\b(?:quota|rate[- ]limits?|usage[- ]limits?)\b",
    "账户/认证": r"\b(?:auth(?:entication)?|login|sign[- ]in|oauth|keyring)\b",
    "模型": r"\bmodels?\b",
    "任务/记录": r"\b(?:rollout|sessions?|threads?|task[- ]complete)\b",
    "配置/权限": r"\b(?:config(?:uration)?|feature flags?|sandbox|approval)\b",
    "交互启动": r"\b(?:tui|terminal|onboarding|interactive|trust)\b",
}


def local_identity():
    result = subprocess.run([str(PROJECT / "Probes/check-cli-compatibility.sh"), "--identity"],
                            check=True, capture_output=True, text=True, timeout=60)
    identity = json.loads(result.stdout)["identity"]
    if not all(identity.get(key) for key in ("binary", "version", "sha256")):
        raise ValueError("incomplete CLI identity")
    if ".app/Contents/" in identity["binary"]:
        app = pathlib.Path(identity["binary"].split("/Contents/", 1)[0])
        with (app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        identity["desktop"] = {"path": str(app), "version": info.get("CFBundleShortVersionString"),
                               "build": info.get("CFBundleVersion")}
    return identity


def fetch_releases(etag):
    # Use macOS curl's TLS support; conditional requests avoid downloading unchanged notes.
    with tempfile.TemporaryDirectory(prefix="keeper-release-feed-") as directory:
        headers, body = pathlib.Path(directory) / "headers", pathlib.Path(directory) / "body"
        command = ["/usr/bin/curl", "--silent", "--show-error", "--location", "--max-time", "15",
                   "--connect-timeout", "5", "--max-filesize", "1048576", "--dump-header", str(headers),
                   "--output", str(body), "--write-out", "%{http_code}", "--user-agent", "CodexKeeper-UpdateReminder"]
        if not any(os.environ.get(key) for key in ("https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY")):
            system = subprocess.run(["/usr/sbin/scutil", "--proxy"], check=True,
                                    capture_output=True, text=True, timeout=5).stdout
            proxy = dict(re.findall(r"^  (HTTPS(?:Enable|Proxy|Port)) : (\S+)$", system, re.MULTILINE))
            if proxy.get("HTTPSEnable") == "1" and proxy.get("HTTPSProxy") and proxy.get("HTTPSPort"):
                command += ["--proxy", "http://%s:%s" % (proxy["HTTPSProxy"], proxy["HTTPSPort"])]
        if etag:
            command += ["--header", "If-None-Match: " + etag]
        command.append(FEED)
        response = subprocess.run(command, check=True, capture_output=True, text=True, timeout=20)
        current_etag = next((line.split(":", 1)[1].strip() for line in reversed(headers.read_text().splitlines())
                             if line.lower().startswith("etag:")), None)
        if response.stdout == "304":
            return None, current_etag or etag
        if response.stdout != "200":
            raise OSError("release feed HTTP " + response.stdout)
        data = body.read_bytes()
        if len(data) > 1048576:
            raise ValueError("release feed too large")
    namespace = {"a": "http://www.w3.org/2005/Atom"}
    entries = []
    for entry in ET.fromstring(data).findall("a:entry", namespace):
        link = next(link.attrib["href"] for link in entry.findall("a:link", namespace)
                    if link.attrib.get("rel", "alternate") == "alternate")
        text = entry.findtext("a:content", "", namespace)
        entries.append({"id": entry.findtext("a:id", namespaces=namespace),
                        "title": entry.findtext("a:title", namespaces=namespace), "url": link,
                        "text": html.unescape(re.sub(r"<[^>]*>", " ", text))})
    if not entries:
        raise ValueError("empty release feed")
    return entries, current_etag


def notify(message):
    script = 'on run argv\n display notification (item 1 of argv) with title "Codex Keeper 更新提醒" subtitle "请自行检查兼容性"\nend run'
    subprocess.run(["/usr/bin/osascript", "-e", script, message], check=True, capture_output=True, timeout=10)


def run(state_path=STATE, now=None):
    now = now or datetime.datetime.now().astimezone()
    today = now.date().isoformat()
    state_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with state_path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        old = json.loads(state_path.read_text()) if state_path.exists() else {}
        if old and now.hour < 9:
            return "waiting for 09:00"
        if (old.get("lastCheckDate") == today and
                datetime.datetime.fromisoformat(old["checkedAt"]).hour >= 9):
            return "already checked today"
        state, changes = dict(old), []
        try:
            identity = local_identity()
            previous = old.get("identity")
            if previous:
                keys = ("binary", "resolvedBinary", "version", "sha256")
                if any(previous.get(key) != identity.get(key) for key in keys):
                    changes.append("本机 CLI 已变化：%s → %s（路径或二进制也可能变化）。" %
                                   (previous["version"], identity["version"]))
                if previous.get("desktop") != identity.get("desktop"):
                    changes.append("本机 Codex 桌面应用版本/构建已变化，可能影响 Keeper 的任务接入。")
            state["identity"], state["localError"] = identity, None
        except Exception as error:
            state["localError"] = type(error).__name__
            if old.get("identity") and not old.get("localError"):
                changes.append("本机 CLI 检查未完成，请手动核对 Keeper；详细状态见提醒记录。")
        try:
            releases, etag = fetch_releases(old.get("etag"))
            if releases is not None:
                known = dict(old.get("releaseHashes", {}))
                for release in releases:
                    digest = hashlib.sha256((release["title"] + "\n" + release["text"]).encode()).hexdigest()
                    if "releaseHashes" in old and known.get(release["id"]) != digest:
                        text = release["text"].lower().replace("_", " ")
                        impacts = [name for name, pattern in IMPACT.items() if re.search(pattern, text)]
                        if impacts:
                            changes.append("官方 %s 发布说明涉及 %s（可能影响 Keeper）：\n%s" %
                                           (release["title"], "、".join(impacts), release["url"]))
                    known[release["id"]] = digest
                state["releaseHashes"] = known
            state["etag"], state["releaseError"] = etag, None
        except Exception as error:
            # A feed outage is not evidence of a CLI change; retain the previous baseline.
            state["releaseError"] = type(error).__name__
        state["lastCheckDate"] = today
        state["checkedAt"] = now.isoformat()
        if changes:
            report = ("# Codex Keeper 更新提醒\n\n%s\n\n%s\n\n请自行检查；脚本没有运行兼容测试或发送 Codex 消息。\n" %
                      (state["checkedAt"], "\n\n".join(changes)))
            (state_path.parent / "last-change.md").write_text(report)
            try:
                notify("\n".join(changes)[:220])
                state["notificationError"] = None
            except Exception as error:
                state["notificationError"] = type(error).__name__
            state["lastChangeAt"] = state["checkedAt"]
        temporary = state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
        temporary.chmod(0o600)
        temporary.replace(state_path)
        return "checked; %d change(s); CLI=%s; releases=%s" % (
            len(changes), state.get("localError") or "OK", state.get("releaseError") or "OK")


if __name__ == "__main__":
    result = run()
    print(datetime.datetime.now().astimezone().isoformat() + " " + result)
