#!/usr/bin/env bash
# build-srpm.sh OUTDIR: build the kernel-surface source package (SRPM) that pins.conf describes, into
# OUTDIR. COPR runs it through .copr/Makefile ("make srpm"); it runs the same way in any Fedora
# container (see README.md).
#
# Steps, all pinned (nothing floats):
#   1. linux-surface's patches and Fedora packaging: CONTRIB_URL at the full commit CONTRIB_COMMIT
#      (fetched by hash, and checked to be that commit);
#   2. optionally, the Fedora packaging patches from PKG_PATCHES_URL at PKG_PATCHES_COMMIT, when the
#      fork's don't fit this kernel's spec;
#   3. PACKAGE_TAG and PACKAGE_RELEASE written into build-linux-surface.py;
#   4. fixups/*.patch (if any) applied to that tree with `git apply`, in name order (for a change the
#      Fedora build needs and the fork doesn't carry; each says why in its header);
#   5. Fedora's kernel tree (kernel-ark) at PACKAGE_TAG, which must point to ARK_COMMIT, fetched shallow with just the history
#      kernel-ark's Makefile needs: the tag, vX.Y.Z, and the linux-X.Y.y branch, back to the previous
#      point release;
#   6. linux-surface's own build-linux-surface.py --mode srpm (Red Hat's test key: the kernel is signed
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

CONTRIB_URL="" CONTRIB_COMMIT="" PACKAGE_TAG="" PACKAGE_RELEASE="" PKG_PATCHES_URL="" PKG_PATCHES_COMMIT="" ARK_URL="" ARK_COMMIT=""
# shellcheck source=pins.conf
. "${HERE}/pins.conf"
[[ "${CONTRIB_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "CONTRIB_COMMIT must be a full 40-digit commit hash"
[[ -z "${PKG_PATCHES_COMMIT}" || "${PKG_PATCHES_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || die "PKG_PATCHES_COMMIT must be empty or a full commit hash"
[[ "${PACKAGE_TAG}" =~ ^kernel-([0-9]+)\.([0-9]+)\.([0-9]+)-0$ ]] || die "PACKAGE_TAG must look like kernel-6.18.56-0"
MAJ="${BASH_REMATCH[1]}" MIN="${BASH_REMATCH[2]}" PATCH="${BASH_REMATCH[3]}"
[[ "${PATCH}" -ge 1 ]] || die "PACKAGE_TAG: a .0 release has no previous point release to cut the history at"
[[ "${PACKAGE_RELEASE}" =~ ^[1-9][0-9]*$ ]] || die "PACKAGE_RELEASE must be a positive number"
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
fi

echo "== ${PACKAGE_TAG}, release ${PACKAGE_RELEASE}"
py="${PKG}/build-linux-surface.py"
sed -i -E "s/^PACKAGE_TAG = \".*\"$/PACKAGE_TAG = \"${PACKAGE_TAG}\"/; s/^PACKAGE_RELEASE = \".*\"$/PACKAGE_RELEASE = \"${PACKAGE_RELEASE}\"/" "${py}"
if ! grep -q -x "PACKAGE_TAG = \"${PACKAGE_TAG}\"" "${py}" || ! grep -q -x "PACKAGE_RELEASE = \"${PACKAGE_RELEASE}\"" "${py}"; then
  die "couldn't set PACKAGE_TAG/PACKAGE_RELEASE in build-linux-surface.py (its format changed?)"
fi

for f in "${HERE}"/fixups/*.patch; do
  echo "== fixup: ${f##*/}"
  git -C "${WORK}/ls" apply --index "${f}" || die "fixup ${f##*/} doesn't apply"
done

echo "== kernel-ark: ${PACKAGE_TAG}, v${MAJ}.${MIN}.${PATCH}, linux-${MAJ}.${MIN}.y (history from v${MAJ}.${MIN}.$((PATCH - 1)))"
ARK_MIRROR="${WORK}/ark.git"
git init -q --bare "${ARK_MIRROR}"
git -C "${ARK_MIRROR}" fetch -q --shallow-exclude="v${MAJ}.${MIN}.$((PATCH - 1))" "${ARK_URL}" \
  "refs/tags/${PACKAGE_TAG}:refs/tags/${PACKAGE_TAG}" "refs/tags/v${MAJ}.${MIN}.${PATCH}:refs/tags/v${MAJ}.${MIN}.${PATCH}" \
  "refs/heads/linux-${MAJ}.${MIN}.y:refs/heads/linux-${MAJ}.${MIN}.y" || die "kernel-ark: couldn't fetch ${PACKAGE_TAG}, v${MAJ}.${MIN}.${PATCH} and linux-${MAJ}.${MIN}.y"
tagged="$(git -C "${ARK_MIRROR}" rev-parse "${PACKAGE_TAG}^{commit}")" || tagged=""
[[ "${tagged}" == "${ARK_COMMIT}" ]] || die "kernel-ark: ${PACKAGE_TAG} points to ${tagged:-nothing}, not the pinned ${ARK_COMMIT} (moved tag?)"
base="$(git -C "${ARK_MIRROR}" merge-base "${PACKAGE_TAG}" "linux-${MAJ}.${MIN}.y")" || die "kernel-ark: no common base of ${PACKAGE_TAG} and linux-${MAJ}.${MIN}.y"
described="$(git -C "${ARK_MIRROR}" describe "${base}")" || described=""
[[ "${described}" == "v${MAJ}.${MIN}.${PATCH}" ]] \
  || die "kernel-ark: ${PACKAGE_TAG} isn't based on v${MAJ}.${MIN}.${PATCH} on linux-${MAJ}.${MIN}.y (has the branch moved past it?)"
git clone -q "${ARK_MIRROR}" "${PKG}/kernel-ark"

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
