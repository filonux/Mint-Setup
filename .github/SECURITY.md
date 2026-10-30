# Security policy

Mint-Setup runs locally and handles configuration that can contain credentials (Wi-Fi passwords, pairing keys, browser and mail profiles). If you find a real vulnerability, report it privately instead of opening a public issue.

## Supported versions

Only the latest release receives security fixes.

## How to report

Email **filonux@proton.me**. If the repository has **Security → Report a vulnerability** enabled, you can use that instead.

Please include:

- What the problem is and which module or command is affected.
- The Mint-Setup version (`mint-setup.sh --version`) and your distribution.
- Steps to reproduce it and, if you can, its impact.

## What to expect

You will get an acknowledgement and an assessment as soon as the maintainer is able; this is a spare-time project, so please allow some days. Once a fix is available, the report can be disclosed publicly, with credit if you want it.

## Scope

In scope: ways the script could expose or overwrite data it should not (permissions on backups, unsafe temporary files, command or path injection through names, unintended privilege use).

Out of scope: the fact that a backup contains credentials by design (the script warns about it before saving sensitive modules and the backup is not an encryption layer), and vulnerabilities in third-party tools such as Zenity or PolicyKit.
