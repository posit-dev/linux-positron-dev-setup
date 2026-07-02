# linux-positron-dev-setup

Scripts to configure a fresh Linux machine for [Positron](https://positron.posit.co)
development.

Supports the Debian family (Debian, Ubuntu, Mint, Pop!_OS, …)
and the Fedora family (Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux, …).

## Quick start

Run the setup script using `wget` or `curl`.

For `wget` run:

```sh
bash -c "$(wget -qO- https://raw.githubusercontent.com/posit-dev/linux-positron-dev-setup/main/setup.sh)"
```

For `curl` run:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/posit-dev/linux-positron-dev-setup/main/setup.sh)"
```

This downloads each script in full before running it, so a dropped connection can't
leave you executing a half-downloaded script.

That single command detects your distro and installs everything you need for Positron
development on Linux. The things it asks you are personal (your name and email, for
git) plus a one-time GitHub sign-in via the `gh` CLI (in your browser or with a device
code). The scripts are idempotent, so re-running is safe.

## What it does

- Refreshes the apt package index.
- Optionally upgrades installed packages within the current release (keeping the
  box on the same Debian/Ubuntu version).
- Installs all package dependencies.
- Optionally switches your login shell to Zsh (the default shell on macOS), and,
  if you do, optionally installs [oh-my-zsh](https://ohmyz.sh) on top of it.
- Installs Node.js via [fnm](https://github.com/Schniz/fnm) and sets it as the
  default.
- Installs Python via [pyenv](https://github.com/pyenv/pyenv) and sets it as the
  global version.
- Configures your git identity, prompting for your name and email (pre-filling
  anything that's already set).
- Installs the [GitHub CLI](https://cli.github.com) (`gh`).
- Sets up GitHub access: generates an ed25519 SSH key (if you don't already have
  one), authenticates `gh` (browser or device code), and registers the key on
  your account. Falls back to showing the key for manual registration if the
  upload can't be done automatically.
- Clones Positron over SSH into a folder you choose under `~/` (skipped if it's
  already there). If you have push access to `posit-dev/positron` it clones that
  directly; otherwise it forks it to your account and clones the fork, with an
  `upstream` remote pointing back at `posit-dev/positron`.
- Optionally installs Visual Studio Code.
- Optionally installs and enables the OpenSSH server so the machine accepts
  incoming SSH connections (e.g. for VS Code Remote - SSH).
- If you're using Zsh with oh-my-zsh, sets a custom shell prompt.

> **Note:** setting up GitHub access signs you in to the `gh` CLI, which is a
> one-time interactive step — `gh` opens your browser (or shows a device code)
> for you to authorize. This is also how the script decides whether to clone
> `posit-dev/positron` directly or fork it: it checks your actual push access.
> If you already have `gh` authenticated, this step is skipped.

## Configuration

Override these with environment variables if you need to:

| Variable           | Default                                                              | What it controls                          |
| ------------------ | ------------------------------------------------------------------- | ----------------------------------------- |
| `SETUP_BASE_URL`   | `…/posit-dev/linux-positron-dev-setup/main`                      | Where `setup.sh` fetches sibling scripts. |
| `SETUP_REPO_URL`   | `https://github.com/posit-dev/linux-positron-dev-setup.git`      | Repo cloned by the setup.                 |
| `SETUP_CLONE_DIR`  | `~/linux-positron-dev-setup`                                         | Where the repo is cloned.                 |
| `SETUP_POSITRON_REPO` | `posit-dev/positron`                                             | Positron repo checked for access / forked. |
| `SETUP_POSITRON_URL`  | `git@github.com:posit-dev/positron.git`                          | SSH URL used for the direct clone.        |
