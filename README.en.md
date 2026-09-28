# Codex Keeper

[简体中文](README.md)

**Start quota windows on your schedule. Resume tasks when quota resets.**

A small Codex utility in your Mac menu bar:

- **Start the quota timer early:** Start a 5-hour quota window before you use Codex, following your daily schedule, so it is easier to plan around your routine.
- **Resume after quota resets:** When a task pauses because quota runs out, automatically continue it once normal quota recovery is confirmed.
- **Check quota anytime:** See your remaining 5-hour and weekly quota and the next keep-alive or resume time in the menu bar.

## Requirements

An Apple Silicon Mac running macOS 13 or later. Install Codex and sign in with a ChatGPT account first.

This is a beta for local Codex tasks. Scheduled keep-alives require access to `gpt-5.6-luna`; Keeper does not increase your quota or bypass quota limits.

## Getting started

1. [Download the installer](https://github.com/OM-KEN/Codex-Keeper/releases/latest), drag Codex Keeper to **Applications**, and open it.
2. Set a daily start time and select **Get Started**.

Keep-alive and auto-resume are enabled by default. Click the menu bar icon to view quota, tasks, and settings.

Keep Keeper running and your Mac awake and online while using it.

## Common questions

<details>
<summary>When does a paused task resume automatically?</summary>

Tasks paused because quota runs out resume once normal quota recovery is confirmed. If recovery is early or uncertain, Keeper asks you to choose.

Select **Review task** in the reminder at the top of the menu, or use the system notification to choose:

- **Continue now:** Try to resume after checking quota and task state.
- **Continue as scheduled:** Try to resume at the next feasible scheduled time, after checking quota and task state again.
- **Cancel this time:** Skip this continuation and preserve the task and its history.

If you do not choose, the reminder stays and the task does not resume automatically. Scheduled keep-alives continue.

</details>

<details>
<summary>Can I change the message sent when a task resumes?</summary>

Click a task name in the menu to select tasks and edit the message. You can also use the text saved in that task's Codex input box.

In Settings, choose the default “Continue” or edit a custom message. The interface supports Simplified Chinese and English and follows the macOS language setting for the app. The default message follows the language; custom messages stay as written.

If project files changed or cannot be checked, Keeper adds a reminder before the resume message asking Codex to check the project and progress first. You can turn it off in Settings.

</details>

<details>
<summary>What if the app won't open or quota sync fails?</summary>

The disk image is not notarized. If macOS blocks the first launch, verify the download source and follow [Apple's instructions for opening the app](https://support.apple.com/en-us/102445).

If quota sync fails, click the refresh button beside the time. If it keeps failing, check your network, Codex sign-in, and version.

If the official Codex CLI cannot be found, click the error message in the menu, enter or choose its executable file, then select **Save and Retry**. Paths with `~/` or spaces are supported. You only need to enter a path if automatic discovery fails.

</details>

## License

This project is open source under the [MIT License](LICENSE). You may use, modify, and distribute it, including for commercial use, provided you retain the copyright and license notice. See the [third-party notices](assets/NOTICE.md) for reused assets.

---

This is an independent project and is not affiliated with OpenAI. Developers can build it using the [development guide](docs/DEVELOPMENT.md), which is currently in Chinese.
