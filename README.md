# Build the latest Engrampa packages for Ubuntu/Debian

This project builds the latest stable upstream Engrampa release into two installable Debian packages for systems where newer Engrampa versions are no longer provided:

- `engrampa` - the application executable and architecture-specific files;
- `engrampa-common` - shared resources and architecture-independent files.

## Why

The main reason is a bug with password-protected archives that is not fixed in the Engrampa versions shipped by older distributions. In [issue 522](https://github.com/mate-desktop/engrampa/issues/522) Engrampa crashes when a password-protected `.zip` or `.7z` archive is extracted from the application window after the password is entered. It is fixed upstream by [commit 4e0906a](https://github.com/mate-desktop/engrampa/commit/4e0906a4dd0dfd0703ac688551bdcac5ff00a368) ("Fix extract of encrypted archives"), which first appears in release 1.28.2. Ubuntu 24.04 still ships 1.26.2-4 without it.

## Requirements

- Bash and a local Docker Engine that can run containers;
- Ubuntu, Debian, or a derivative that reports `UBUNTU_CODENAME` or `DEBIAN_CODENAME` in `/etc/os-release`;
- network access to GitHub and Debian repositories;
- enough free disk space for the build container, source files, and build dependencies.

Nothing else is installed on the host. Tested on Ubuntu 24.04 (noble), amd64; other bases are expected to work the same way but have not been tested. Very old or end-of-life distributions may no longer have usable repositories or compatible build dependencies.

## Build

Run the script from the directory where you want the `.deb` files to appear. The project files can be stored elsewhere:

```bash
bash /path/to/engrampa-builder/build-engrampa.sh
```

On every run the script asks GitHub for the latest stable upstream release; no version is hard-coded. The build happens in a disposable container of your distribution base (the same Ubuntu or Debian codename as the host, with Ubuntu `universe` enabled inside the container only). The container sees your current directory and receives only the two finished `.deb` files; sources and intermediate files stay inside it and disappear with it. If the base image was not on the host before, it is removed afterwards too, so nothing is left behind. No `sudo` is needed to build.

Upstream releases do not contain the description needed to make `.deb` packages (package names, dependencies, file split, build rules). It is maintained by Debian in the `debian/` directory of its source package, so the script downloads the current one from Debian unstable and applies it to the latest upstream release. The result is two ordinary packages that APT installs over the older version and can downgrade again.

If Debian's packaging does not fit the newest upstream release yet (patches do not apply or dependencies cannot be resolved), the script stops and names both versions.

## Install

The script prints the exact command when it finishes:

```bash
sudo apt install ./engrampa_<version>_<arch>.deb ./engrampa-common_<version>_all.deb
```

Review APT's proposed changes before confirming. Do not install packages built for another distribution base or CPU architecture. On Ubuntu, keep the `universe` repository enabled on the host as well, because APT may need to install runtime dependencies from it.

## Files

- `build-engrampa.sh` - runs on the host: selects the base image, starts the disposable container, and removes the base image afterwards if it had to be downloaded.
- `build-in-container.sh` - runs inside the container: downloads the latest upstream release and Debian's packaging recipe, builds both packages, and copies them to the current directory.

## Limitations and rollback

- Engrampa is a graphical front end; archive backends such as `7zip`, `unzip`, `unar`, and `unrar` remain separate system packages.
- Some older distributions call the 7-Zip backend package `p7zip-full` instead of `7zip`; the build adjusts that runtime dependency only when `7zip` is unavailable and `p7zip-full` exists.
- The script does not change the host's APT sources or install the generated packages.
- To check the repository versions available for rollback:

  ```bash
  apt-cache policy engrampa engrampa-common
  ```

  Then downgrade both packages to the same available repository version:

  ```bash
  sudo apt install --allow-downgrades "engrampa=<repository-version>" "engrampa-common=<repository-version>"
  ```
