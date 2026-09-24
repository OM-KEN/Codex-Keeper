# Codex Keeper

[简体中文](README.md)

A quiet Codex companion in your Mac menu bar.

- **Keep active:** Try to start a new 5-hour quota window at scheduled times.
- **Auto-resume:** When a task stops because its quota is exhausted, try to resume it after the quota resets if it is still paused.
- **View quota:** See the remaining 5-hour and weekly quota and the next scheduled action.

## Requirements

An Apple Silicon Mac running macOS 13 or later. Install Codex and sign in with a ChatGPT account first.

This is a beta for local Codex tasks. Keep-alive requires access to `gpt-5.6-luna`. Keeper does not increase your quota or bypass quota limits.

## Getting started

1. Open the disk image, drag **CodexKeeper** to **Applications**, and launch it.
2. In the first-run guide, choose a daily start time and select **Get Started**. For example, the schedule preview for `08:00` shows `08:00 · 13:00 · 18:00 · 23:00`.
3. Keep-alive and auto-resume are enabled by default. Adjust or disable them in the menu bar settings.
4. When tasks are waiting to resume, click a task name in the menu to choose tasks and edit the message to send.

The Codex desktop app may be closed, but Keeper must keep running and your Mac must be awake and online. Keeper skips keep-alive when a valid quota window is already active. Disabling Keeper pauses automatic actions.

The interface supports Simplified Chinese and English and follows the macOS language setting for the app. Changing languages does not overwrite a message you customized for auto-resume.
In Settings, choose the language-aware default “Continue” or edit a custom message in a dialog.
If project files changed or cannot be checked, Keeper adds a separate check reminder before the resume message by default; you can turn it off in Settings.

The disk image is not notarized. If macOS blocks the first launch, verify the download source and follow [Apple's instructions for opening the app](https://support.apple.com/en-us/102445).

If quota sync fails, click the refresh button beside the main time. If it keeps failing, check your network, Codex sign-in, and version.

---

This is an independent project and is not affiliated with OpenAI. No public download is available yet. Developers can build it using the [development guide](docs/DEVELOPMENT.md), which is currently in Chinese.
