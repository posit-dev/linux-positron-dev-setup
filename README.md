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
development on Linux. The only things it asks you are personal (your name and email,
for git). The scripts are idempotent, so re-running is safe.

## Undoing the setup

Each run records what it actually installed or created in a per-machine manifest
(`~/.local/state/linux-positron-dev-setup/manifest`), and `--undo` reverses exactly
that. Pass it through the same one-liner — note the extra `setup` word, which is a
placeholder that has to be there (with `bash -c`, the first word after the script
becomes `$0`, so `--undo` alone would be swallowed and a normal setup would run
instead):

For `wget` run:

```sh
bash -c "$(wget -qO- https://raw.githubusercontent.com/posit-dev/linux-positron-dev-setup/main/setup.sh)" setup --undo
```

For `curl` run:

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/posit-dev/linux-positron-dev-setup/main/setup.sh)" setup --undo
```

`--undo` only reverses things a run on *this* machine recorded; it never touches
packages or checkouts that were already there, and it does not revert
`apt-get`/`dnf` updates. Generated SSH keys (and any GitHub fork you created) are
deliberately left in place, since they may already be in use.

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
- Generates an ed25519 SSH key (if you don't already have one), shows it, copies
  it to your clipboard (if a clipboard tool is available), and points you at
  GitHub to register it.
- Configures your git identity, prompting for your name and email (pre-filling
  anything that's already set).
- Sets up Positron under a folder you choose under `~/`, asking whether you're a
  Positron core developer:
  - **Core developers** get a Y/n prompt to clone each of the core repos
    (`positron`, `positron-codicons`, `positron-builds`, `positron-website`,
    `positron-wiki`).
  - **Community contributors** are pointed to GitHub to fork Positron, then have
    their fork cloned with the canonical repo added as an `upstream` remote, and
    are shown links to [Positron](https://github.com/posit-dev/positron) and its
    [contributing guide](https://github.com/posit-dev/positron/blob/main/CONTRIBUTING.md)
    to get started.

  Existing checkouts are left alone.
- Optionally installs Visual Studio Code.
- Optionally installs and enables the OpenSSH server so the machine accepts
  incoming SSH connections (e.g. for VS Code Remote - SSH).
- If you're using Zsh with oh-my-zsh, sets a custom shell prompt.

## Configuration

Override these with environment variables if you need to:

| Variable           | Default                                                              | What it controls                          |
| ------------------ | ------------------------------------------------------------------- | ----------------------------------------- |
| `SETUP_BASE_URL`   | `…/posit-dev/linux-positron-dev-setup/main`                      | Where `setup.sh` fetches sibling scripts. |
| `SETUP_REPO_URL`   | `https://github.com/posit-dev/linux-positron-dev-setup.git`      | Repo cloned by the setup.                 |
| `SETUP_CLONE_DIR`  | `~/linux-positron-dev-setup`                                         | Where the repo is cloned.                 |
