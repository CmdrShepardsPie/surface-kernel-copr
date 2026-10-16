# surface-kernel-copr

The build recipe for a COPR repository of self-built [linux-surface](https://github.com/linux-surface/linux-surface)
kernels for Fedora: linux-surface's patches on a long-term or stable kernel, packaged with
linux-surface's own Fedora packaging (`pkg/fedora/kernel-surface`), on Fedora's kernel tree
([kernel-ark](https://gitlab.com/cki-project/kernel-ark)). Where linux-surface's spec patches don't fit
the kernel-ark release, they come from elsewhere, named in `pins.conf` (for 7.2: orthogonaleety's
`f44-7.2.10-0` branch). For 7.2, the pinned patches also carry fixes and backports not yet in
linux-surface (see `pins.conf`).

The packages are named `kernel-surface-cmdrshepardspie` (with `-core`, `-modules` and so on), and their
release ends in `.cmdrshepardspie` (`uname -r`: `7.2.11-1.cmdrshepardspie.fc43.x86_64`). They install beside
linux-surface's own `kernel-surface` packages and never replace or remove them (`PACKAGE_NAME` and
`RELEASE_SUFFIX` in `pins.conf`; `fixups/0003` drops the packaging lines that would act on linux-surface's
package, and its default-kernel watchdog; `build-srpm.sh` refuses any packaging patch that still names them).

These are **not** official linux-surface builds. They exist to run a kernel series that
linux-surface doesn't publish for Fedora (today: 7.2, the latest stable), until it does.

## What's here

| File | What it is |
|---|---|
| `pins.conf` | Everything the build depends on, pinned: the patch repository and its full commit hash, the kernel-ark tag and the full commit hash it must point to, the package release, this repository's own package name and release suffix, and (if needed) where the Fedora packaging patches come from. |
| `build-srpm.sh` | Builds the source package (SRPM) from `pins.conf`. Each step is described at the top of the script. |
| `.copr/Makefile` | COPR's "make srpm" entry point: installs what `build-srpm.sh` needs, then runs it. |
| `fixups/*.patch` | Changes the Fedora build needs that the patch repository doesn't carry, applied in name order. Each one says why in its header. |
| `tests/run-tests.sh`, `tests/mutations.txt` | Hermetic tests of `build-srpm.sh` and `.copr/Makefile` against local stand-in repositories (no network), and the mutations they must catch (`FILE@@SED-EXPRESSION@@WHAT IT BREAKS`). |

## How it's built

COPR builds the package for each enabled Fedora release whenever this repository changes
(a GitHub webhook). For each build:

1. COPR's source step runs `make -f .copr/Makefile srpm` in a fresh Fedora chroot. That
   fetches the pinned sources and runs linux-surface's `build-linux-surface.py --mode srpm`.
2. COPR builds the binary RPMs from that SRPM in each chroot, and signs the packages with
   the COPR project's own GPG key.

**Secure Boot:** the kernel image is signed only with Red Hat's test key, which Secure
Boot doesn't trust. It's meant to be signed on the machine it's installed on, with that
machine's own Machine Owner Key (MOK). No private key is ever in this repository or in COPR.

## Updating to a new point release

1. Find the commit with linux-surface's patches for the new point release (upstream, or a pull
   request there) and its full hash. Name it `copr/X.Y.Z-patches` (a tag, or a branch where
   tags can't be pushed) in the repository `CONTRIB_URL` points to (a fork in the same network;
   here CmdrShepardsPie/linux-surface-contrib, which only its owner can push to), so the commit
   stays fetchable even if its branch moves.
2. In `pins.conf`, set `CONTRIB_COMMIT` to that hash, set `PACKAGE_TAG` to kernel-ark's
   tag for the release (`kernel-X.Y.Z-0`) and `ARK_COMMIT` to the commit it points to (the
   `^{}` line of `git ls-remote https://gitlab.com/cki-project/kernel-ark 'refs/tags/kernel-X.Y.Z-0*'`;
   the other line is the tag object), and set `PACKAGE_RELEASE` back to `1`. If
   `PKG_PATCHES_COMMIT` is set, check that its patches still apply to the new spec, and
   re-pin it if not (name it `copr/X.Y.Z-fedora-pkg` the same way).
3. Check whether each file in `fixups/` is still needed (see its header), then run the
   checks below.
4. Push. COPR rebuilds.

To rebuild the same kernel (for example, after a packaging fix), increase `PACKAGE_RELEASE` instead.

## Running it yourself

In any Fedora container, with network access:

```
dnf -y install make
make -f .copr/Makefile srpm outdir=/tmp/out
```

The SRPM lands in `/tmp/out`. Building it takes a few minutes, mostly to compress the
kernel source. Building the binary RPMs from it (`rpmbuild --rebuild`) takes hours on a
small machine.

Tests (no network; needs `git`, `bash`, GNU `make` and coreutils 8.28 or later):

```
bash tests/run-tests.sh
```
