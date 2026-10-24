#!/usr/bin/env bash
# build-srpm.sh OUTDIR: build the kernel source package (SRPM, kernel-PACKAGE_NAME) that pins.conf describes, into
# OUTDIR. COPR runs it through .copr/Makefile ("make srpm"); it runs the same way in any Fedora
# container (see README.md).
#
# Steps, all pinned (nothing floats):
#   1. linux-surface's patches and Fedora packaging: CONTRIB_URL at the full commit CONTRIB_COMMIT
#      (fetched by hash, and checked to be that commit);
#   2. optionally, the Fedora packaging patches from PKG_PATCHES_URL at PKG_PATCHES_COMMIT, when
#      CONTRIB's don't fit this kernel's spec;
#   3. PACKAGE_TAG and PACKAGE_RELEASE written into build-linux-surface.py, and this repository's own
#      package name (PACKAGE_NAME) and release suffix (RELEASE_SUFFIX) into it and build-ark.py, so the
#      packages never carry linux-surface's names;
#   4. fixups/*.patch (if any) applied to that tree with `git apply`, in name order (for a change the
#      Fedora build needs, or a fix not yet in the patch repository; each says why in its header);
#   5. Fedora's kernel tree (kernel-ark) at PACKAGE_TAG, which must point to ARK_COMMIT, fetched shallow with just the history
#      kernel-ark's Makefile needs: the tag, vX.Y.Z, and the linux-X.Y.y branch, back to the previous
#      point release. A point release's tag is kernel-X.Y.Z-0 (Fedora's stable branch); a .0 release,
#      before Fedora has a kernel-X.Y.1-0, can use kernel-ark's os-build tag kernel-X.Y.0-N, which sits
#      on vX.Y (upstream's name for X.Y.0), with history back to vX.Y-rc1;
#   6. DIST (the Fedora release suffix) from rpmbuild, for kernel-ark;
#   7. linux-surface's own build-linux-surface.py --mode srpm (Red Hat's test key: the kernel is signed
#      with the owner's MOK on the machine it's installed on, never here).
#
# Exit status: 0 with exactly one *.src.rpm in OUTDIR; non-zero (with a message) otherwise.
set -euo pipefail
shopt -s inherit_errexit nullglob
export LC_ALL=C

die() { echo "build-srpm.sh: error: $*" >&2; exit 1; }
[[ $# -eq 1 && -n "$1" ]] || die "usage: $0 OUTDIR"
mkdir -p "$1"; OUTDIR="$(cd "$1" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTRIB_URL="" CONTRIB_COMMIT="" PACKAGE_TAG="" PACKAGE_RELEASE="" PACKAGE_NAME="" RELEASE_SUFFIX="" PKG_PATCHES_URL="" PKG_PATCHES_COMMIT="" ARK_URL="" ARK_COMMIT=""
# shellcheck source=pins.conf
. "${HERE}/pins.conf"
[[ "${CONTRIB_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "CONTRIB_COMMIT must be a full 40-digit commit hash"
[[ -z "${PKG_PATCHES_COMMIT}" || "${PKG_PATCHES_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "PKG_PATCHES_COMMIT must be empty or a full commit hash"
[[ "${PACKAGE_TAG}" =~ ^kernel-([0-9]+)\.([0-9]+)\.([0-9]+)-([0-9]+)$ ]] || die "PACKAGE_TAG must look like kernel-7.2.10-0 (or kernel-7.3.0-65 for a .0 release)"
MAJ="${BASH_REMATCH[1]}" MIN="${BASH_REMATCH[2]}" PATCH="${BASH_REMATCH[3]}" ARK_BUILD="${BASH_REMATCH[4]}"
# UPSTREAM_TAG: the upstream release tag PACKAGE_TAG must sit on; CUT: where its fetched history starts.
if [[ "${PATCH}" -ge 1 ]]; then
  # A point release: Fedora's stable-branch tag, always kernel-X.Y.Z-0.
  [[ "${ARK_BUILD}" == 0 ]] || die "PACKAGE_TAG: a point release's tag is kernel-X.Y.Z-0"
  UPSTREAM_TAG="v${MAJ}.${MIN}.${PATCH}" CUT="v${MAJ}.${MIN}.$((PATCH - 1))"
else
  # A .0 release: kernel-ark's os-build release tag kernel-X.Y.0-N (N is ark's build number, never 0),
  # on upstream's vX.Y. There is no previous point release, so the history starts at vX.Y-rc1.
  [[ "${ARK_BUILD}" =~ ^[1-9][0-9]*$ ]] || die "PACKAGE_TAG: a .0 release's tag is kernel-X.Y.0-N, with N from 1"
  UPSTREAM_TAG="v${MAJ}.${MIN}" CUT="v${MAJ}.${MIN}-rc1"
fi
[[ "${PACKAGE_RELEASE}" =~ ^[1-9][0-9]*$ ]] || die "PACKAGE_RELEASE must be a positive number"
# kernel-${PACKAGE_NAME} is the package's name; RELEASE_SUFFIX goes into its release (no "-": rpm forbids it there).
[[ "${PACKAGE_NAME}" =~ ^surface-[a-z0-9]+$ ]] || die "PACKAGE_NAME must look like surface-NAME (not linux-surface's own \"surface\")"
[[ "${RELEASE_SUFFIX}" =~ ^\.[a-z0-9]+$ && "${RELEASE_SUFFIX}" != ".surface" ]] || die "RELEASE_SUFFIX must look like .name (not linux-surface's own \".surface\")"
[[ -n "${ARK_URL}" ]] || die "ARK_URL is empty"
[[ "${ARK_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "ARK_COMMIT must be the full 40-digit commit hash PACKAGE_TAG points to"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# fetch_commit URL COMMIT DIR: DIR := a checkout of exactly COMMIT (fetched by hash, depth 1).
fetch_commit() {
  git init -q "$3"
  git -C "$3" fetch -q --depth 1 "$1" "$2" || die "couldn't fetch commit $2 from $1"
  git -C "$3" checkout -q --detach FETCH_HEAD
  # (Fetching by hash gets exactly that object; this guards against a transport that doesn't.)
  local got; got="$(git -C "$3" rev-parse HEAD)"
  [[ "${got}" == "$2" ]] || die "fetched ${got} from $1, not $2"
}

echo "== linux-surface patches and packaging: ${CONTRIB_URL} @ ${CONTRIB_COMMIT}"
fetch_commit "${CONTRIB_URL}" "${CONTRIB_COMMIT}" "${WORK}/ls"
PKG="${WORK}/ls/pkg/fedora/kernel-surface"
[[ -f "${PKG}/build-linux-surface.py" ]] || die "no pkg/fedora/kernel-surface/build-linux-surface.py at that commit"

if [[ -n "${PKG_PATCHES_COMMIT}" ]]; then
  echo "== Fedora packaging patches: ${PKG_PATCHES_URL} @ ${PKG_PATCHES_COMMIT}"
  fetch_commit "${PKG_PATCHES_URL}" "${PKG_PATCHES_COMMIT}" "${WORK}/pkgsrc"
  src="${WORK}/pkgsrc/pkg/fedora/kernel-surface"
  files=("${src}"/patches/*.patch)
  [[ ${#files[@]} -gt 0 && -f "${src}/secureboot/0001-secureboot.patch" ]] || die "no Fedora packaging patches at ${PKG_PATCHES_COMMIT}"
  rm -f "${PKG}"/patches/*.patch
  cp "${files[@]}" "${PKG}/patches/"
  cp "${src}/secureboot/0001-secureboot.patch" "${PKG}/secureboot/"
  # Stage the swap, so the fixups below can change these patches too (`git apply --index`).
  git -C "${WORK}/ls" add -A "${PKG}/patches" "${PKG}/secureboot"
fi

echo "== ${PACKAGE_TAG}, release ${PACKAGE_RELEASE}"
py="${PKG}/build-linux-surface.py"
sed -i -E "s/^PACKAGE_TAG = \".*\"$/PACKAGE_TAG = \"${PACKAGE_TAG}\"/; s/^PACKAGE_RELEASE = \".*\"$/PACKAGE_RELEASE = \"${PACKAGE_RELEASE}\"/" "${py}"
if ! grep -q -x "PACKAGE_TAG = \"${PACKAGE_TAG}\"" "${py}" || ! grep -q -x "PACKAGE_RELEASE = \"${PACKAGE_RELEASE}\"" "${py}"; then
  die "couldn't set PACKAGE_TAG/PACKAGE_RELEASE in build-linux-surface.py (its format changed?)"
fi
echo "== package kernel-${PACKAGE_NAME}, release suffix ${RELEASE_SUFFIX}"
sed -i -E "s/^PACKAGE_NAME = \".*\"$/PACKAGE_NAME = \"${PACKAGE_NAME}\"/" "${py}"
grep -q -x "PACKAGE_NAME = \"${PACKAGE_NAME}\"" "${py}" || die "couldn't set PACKAGE_NAME in build-linux-surface.py (its format changed?)"
# build-ark.py makes the suffix from the package name (".surface"); this one has its own.
ark_py="${PKG}/build-ark.py"
old_suffix="cmd.append(\"DISTLOCALVERSION='.%s'\" % args.package_name)"
[[ "$(grep -c -x -F "${old_suffix}" "${ark_py}")" == 1 ]] || die "build-ark.py doesn't set DISTLOCALVERSION from the package name as expected (its format changed?)"
sed -i "s/^cmd\.append(\"DISTLOCALVERSION='\.%s'\" % args\.package_name)$/cmd.append(\"DISTLOCALVERSION='${RELEASE_SUFFIX}'\")/" "${ark_py}"
grep -q -x -F "cmd.append(\"DISTLOCALVERSION='${RELEASE_SUFFIX}'\")" "${ark_py}" || die "couldn't set DISTLOCALVERSION in build-ark.py"

for f in "${HERE}"/fixups/*.patch; do
  echo "== fixup: ${f##*/}"
  git -C "${WORK}/ls" apply --index "${f}" || die "fixup ${f##*/} doesn't apply"
done

# The packages must never act on linux-surface's own: no packaging patch may add a line naming its
# kernel-surface packages (only kernel-surface-NAME, or %{package_name}), or its default-kernel watchdog
# (see fixups/0003).
own="kernel-${PACKAGE_NAME}"
# (No `grep -q` at the end: it can stop early, and the SIGPIPE upstream would then fail the pipe.)
for f in "${PKG}"/patches/*.patch "${PKG}"/secureboot/*.patch; do
  if grep -E '^\+' "${f}" | grep -v '^+++ ' | sed "s/${own}//g" | grep -E 'kernel-surface|default-watchdog' >/dev/null; then
    die "packaging patch ${f##*/} adds a line naming linux-surface's kernel-surface packages or its watchdog"
  fi
done

echo "== kernel-ark: ${PACKAGE_TAG}, ${UPSTREAM_TAG}, linux-${MAJ}.${MIN}.y (history from ${CUT})"
ARK_MIRROR="${WORK}/ark.git"
git init -q --bare "${ARK_MIRROR}"
git -C "${ARK_MIRROR}" fetch -q --shallow-exclude="${CUT}" "${ARK_URL}" \
  "refs/tags/${PACKAGE_TAG}:refs/tags/${PACKAGE_TAG}" "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}" \
  "refs/heads/linux-${MAJ}.${MIN}.y:refs/heads/linux-${MAJ}.${MIN}.y" || die "kernel-ark: couldn't fetch ${PACKAGE_TAG}, ${UPSTREAM_TAG} and linux-${MAJ}.${MIN}.y"
tagged="$(git -C "${ARK_MIRROR}" rev-parse "${PACKAGE_TAG}^{commit}")" || tagged=""
[[ "${tagged}" == "${ARK_COMMIT}" ]] || die "kernel-ark: ${PACKAGE_TAG} points to ${tagged:-nothing}, not the pinned ${ARK_COMMIT} (moved tag?)"
base="$(git -C "${ARK_MIRROR}" merge-base "${PACKAGE_TAG}" "linux-${MAJ}.${MIN}.y")" || die "kernel-ark: no common base of ${PACKAGE_TAG} and linux-${MAJ}.${MIN}.y"
described="$(git -C "${ARK_MIRROR}" describe "${base}")" || described=""
[[ "${described}" == "${UPSTREAM_TAG}" ]] \
  || die "kernel-ark: ${PACKAGE_TAG} isn't based on ${UPSTREAM_TAG} on linux-${MAJ}.${MIN}.y (has the branch moved past it?)"
git clone -q "${ARK_MIRROR}" "${PKG}/kernel-ark"
# kernel-ark's Makefile versions the package from the branch its redhat/Makefile.variables names as
# upstream (UPSTREAM_BRANCH ?= ...): linux-X.Y.y on Fedora's stable branches, but "master" (Linus's
# tree, which moves on) at an os-build tag. Name the fetched linux-X.Y.y for both; on a stable tag
# that is its own default.
export UPSTREAM_BRANCH="linux-${MAJ}.${MIN}.y"

# kernel-ark's Makefile takes DIST (the release suffix, e.g. .fc44) from the environment, or else from
# `rpmbuild --eval '%{?dist}'`. COPR's SRPM chroot leaves %dist empty, and with an empty DIST rpmbuild
# refuses the spec ("Macro %dist has empty body") and kernel-ark would treat the build as RHEL. So name
# the Fedora release here, always from rpmbuild (a DIST already in the environment is replaced): %dist
# if it's set, else .fc%fedora. (COPR rebuilds the SRPM in each chroot with that chroot's own %dist, so
# this only names the source package.)
DIST="$(rpmbuild --eval '%{?dist}')"
if [[ -z "${DIST}" ]]; then
  fedora="$(rpmbuild --eval '%{?fedora}')"
  [[ "${fedora}" =~ ^[0-9]+$ ]] || die "rpmbuild defines neither %dist nor a numeric %fedora, so the Fedora release is unknown"
  DIST=".fc${fedora}"
fi
export DIST
echo "== DIST=${DIST}"

echo "== build-linux-surface.py --mode srpm"
# Never a private key in the public SRPM: with secureboot/MOK.key and MOK.crt present, linux-surface's
# packaging adds both to the source package (Source7001/7002). Neither pinned tree has them; this
# makes sure nothing (a fix-up, a packaging change) slips them in.
for f in MOK.key MOK.crt; do [[ ! -e "${PKG}/secureboot/${f}" ]] || die "secureboot/${f} exists: it would go into the public SRPM"; done
# build-ark.py commits in kernel-ark: give git an identity for this build only, never the user's config.
(cd "${PKG}" && GIT_AUTHOR_NAME="surface-kernel build" GIT_AUTHOR_EMAIL="surface-kernel-build" \
  GIT_COMMITTER_NAME="surface-kernel build" GIT_COMMITTER_EMAIL="surface-kernel-build" \
  python3 build-linux-surface.py --mode srpm --ark-dir kernel-ark --outdir "${WORK}/srpm" </dev/null)
srpms=("${WORK}"/srpm/*.src.rpm)
[[ ${#srpms[@]} -eq 1 ]] || die "expected one source package, got ${#srpms[@]}"
cp "${srpms[0]}" "${OUTDIR}/"
echo "== ${OUTDIR}/${srpms[0]##*/}"
