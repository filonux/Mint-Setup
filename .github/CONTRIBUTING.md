# Contributing to Mint-Setup

Thanks for your interest. This guide covers what you need so a contribution can be reviewed and merged quickly.

## Before you start

- For a large change, or one that alters current behavior, open an issue first (use the feature request template) so the approach can be agreed before you invest time.
- For a small fix or an improvement that is clearly scoped, go straight to a pull request.
- Security problems are not reported publicly; see [SECURITY.md](SECURITY.md).

## Project layout

| Path | Contents |
|---|---|
| `script/mint-setup.sh` | The whole program: one Bash script |
| `tests/` | Test suites, the runner (`run.sh`), the static-analysis gate (`lint.sh`) and shared helpers (`lib.sh`) |
| `assets/` | Icons and screenshots |
| `.github/` | Workflows, issue and pull request templates, and these policies |

## Development setup

You need Bash 4.4 or newer. `tests/run.sh` also needs Python 3 and the `en_US.UTF-8` and `es_ES.UTF-8` locales; the suites that use them fail when they are missing. Check with `locale -a`; on Debian-based systems, enable the missing ones in `/etc/locale.gen` and run `sudo locale-gen`. To run the same checks as CI:

```bash
pip install --break-system-packages shellcheck-py==0.11.0.1   # ShellCheck 0.11.0, the pinned version
sudo apt install python3-yaml                                  # YAML syntax check in lint.sh
sudo apt install cryptsetup-bin desktop-file-utils             # real-LUKS checks; launcher check in test-install
```

Without `cryptsetup-bin` or `desktop-file-utils` the checks that use them print a SKIP line instead of running. `TEST_STRICT=1` (set in CI) counts any SKIP as a failure, and root ignores file permissions, so run the suites as an unprivileged user.

The native GUI suite (`tests/test-native-zenity.sh`) also needs `zenity xvfb xdotool x11-utils imagemagick tesseract-ocr tesseract-ocr-spa dbus-x11`; on Ubuntu and Mint, `language-pack-gnome-es-base` adds the Spanish Zenity catalog that its English-on-Spanish run needs (without it that run prints a SKIP line). It is the only suite skipped as a whole (SKIP) when its requirements are missing; with Docker or Podman installed, `bash tests/test-native-zenity.sh --container` runs it in a container instead.

## Checks before opening a pull request

```bash
LINT_STRICT=1 bash tests/lint.sh   # bash -n, ShellCheck, file hygiene and modes, YAML
bash tests/run.sh                  # every test suite
```

`bash tests/run.sh --list` shows the suites and `bash tests/run.sh --only NAME` runs one of them. Each suite runs in an isolated `HOME` with no display and no D-Bus session, so tests never touch your real environment. See the [Tests section of the README](../README.md#tests) for what each suite covers.

## Code conventions

- **Every message a user can see exists in English and Spanish.** Source strings are written in Spanish and passed through `T`, or through `T_FMT` when they contain `%s` data or `\n` line breaks (plain `T` leaves a literal `\n` in message dialogs). Add the English text with `add_exact "<Spanish>" "<English>"` in the translation catalog, keeping the same number of `%s` placeholders. `tests/test-localization.sh` fails on a missing entry, a placeholder mismatch, a duplicate key or a message dialog with a literal `\n`.
- **Write user data atomically.** Use the `atomic_*` helpers and `ms_commit` instead of writing straight onto an existing file, so an interruption never leaves half-written data.
- **Keep the security guards intact.** `tests/test-security.sh` enforces them: no `eval`, no `sudo` (privileged operations go through `pkexec`), no fixed `/tmp` paths or PID-based names (use `mktemp`), `umask 077`, and backups with modes `700` and `600`.
- **Treat names and paths as data.** Pass them as arguments or through `T_FMT`, never splice them into code or into a format string.
- **Comments explain why, not what.** Write code comments in English.

## Tests

A change in behavior needs a test. Suites build their sandbox with `tests/lib.sh` (`ms_init`, `ms_app`, `ms_lib`, `ms_stub`): reuse it rather than touching the real system. Name a regression test after the symptom it prevents, and check that it fails when the fix is removed.

## Pull requests

- Keep each pull request to one logical change.
- Fill in the pull request template, including how and on which system you tested.
- Update `README.md` and `README-es.md` together when the change affects usage, requirements or tests.
- Do not include generated files, temporary files or credentials.

## Reporting bugs and ideas

Use the issue templates; they open automatically when you create an issue. More context (distribution and version, `zenity --version`, `mint-setup.sh --version`, exact steps) means faster diagnosis.
