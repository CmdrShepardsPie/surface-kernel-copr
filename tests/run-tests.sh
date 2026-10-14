#!/usr/bin/env bash
# tests/run-tests.sh: hermetic tests of build-srpm.sh (no network). The patch repository, the
# packaging-patch repository and kernel-ark are small local git repositories served over file://,
# with the same layout the script relies on; build-linux-surface.py is a stand-in that records what
# it was given and writes one fake .src.rpm.
#
# Not modelled: the real build-linux-surface.py/build-ark.py (patch application, kernel-ark's
# Makefile), network failures, and GitHub's or GitLab's own fetch rules (here the stand-ins allow
# fetching any commit by hash, as GitHub does).
set -euo pipefail
shopt -s inherit_errexit nullglob
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
export HOME="${T}/home"; mkdir -p "${HOME}"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t
git config --global init.defaultBranch main
git config --global uploadpack.allowAnySHA1InWant true
git config --global protocol.file.allow always

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
has() { local t; if grep -q -- "$2" <<<"$3"; then ok "$1"; else t="$(tail -n 3 <<<"$3")"; bad "$1: no '$2' in: ${t//$'\n'/|}"; fi; }
count() { local f=("$1"/*.src.rpm); echo "${#f[@]}"; }   # COUNT DIR: how many source packages DIR holds
run() { local o r=0; o="$("$@" 2>&1)" || r=$?; OUT="${o}"; RC="${r}"; }

# --- stand-in repositories ---------------------------------------------------------------------
# contrib: pkg/fedora/kernel-surface with a recording build-linux-surface.py, patches/, files.
C="${T}/contrib"; mkdir -p "${C}/pkg/fedora/kernel-surface/patches" "${C}/pkg/fedora/kernel-surface/secureboot" "${C}/patches/6.18"
cat > "${C}/pkg/fedora/kernel-surface/build-linux-surface.py" <<'PY'
#!/usr/bin/env python3
import argparse, pathlib, subprocess
PACKAGE_TAG = "kernel-6.19.8-0"
PACKAGE_RELEASE = "3"
p = argparse.ArgumentParser(); p.add_argument("--mode"); p.add_argument("--ark-dir"); p.add_argument("--outdir")
a = p.parse_args()
here = pathlib.Path(__file__).resolve().parent
ver = PACKAGE_TAG.split("-")[1]
subprocess.run(["git", "-C", a.ark_dir, "checkout", "-q", PACKAGE_TAG], check=True)   # as build-ark.py does
head = subprocess.run(["git", "-C", a.ark_dir, "describe", "--tags", "--exact-match", "HEAD"], capture_output=True, text=True).stdout.strip()
log = [f"mode={a.mode}", f"tag={PACKAGE_TAG}", f"release={PACKAGE_RELEASE}", f"ark_head={head}",
       "pkg_patches=" + ",".join(sorted(x.name for x in (here / "patches").glob("*.patch"))),
       "sb=" + (here / "secureboot" / "0001-secureboot.patch").read_text().strip(),
       "cam=" + (here / ".." / ".." / ".." / "patches" / "6.18" / "0013-cameras.patch").read_text().strip()]
out = pathlib.Path(a.outdir); out.mkdir(parents=True, exist_ok=True)
(out / f"kernel-surface-{ver}-{PACKAGE_RELEASE}.surface.fc44.src.rpm").write_text("\n".join(log) + "\n")
PY
echo fork-0001 > "${C}/pkg/fedora/kernel-surface/patches/0001-fork.patch"
echo fork-sb > "${C}/pkg/fedora/kernel-surface/secureboot/0001-secureboot.patch"
echo vanilla-cameras > "${C}/patches/6.18/0013-cameras.patch"
git -C "${C}" init -q; git -C "${C}" add -A; git -C "${C}" commit -q -m contrib
C1="$(git -C "${C}" rev-parse HEAD)"
echo moved > "${C}/moved"; git -C "${C}" add -A; git -C "${C}" commit -q -m moved   # the branch moves on

# pkgsrc: linux-surface's own history with 6.18-era packaging patches.
P="${T}/pkgsrc"; mkdir -p "${P}/pkg/fedora/kernel-surface/patches" "${P}/pkg/fedora/kernel-surface/secureboot"
printf 'era-0001\n' > "${P}/pkg/fedora/kernel-surface/patches/0001-iptsd.patch"
printf 'era-0002\n' > "${P}/pkg/fedora/kernel-surface/patches/0002-name.patch"
echo era-sb > "${P}/pkg/fedora/kernel-surface/secureboot/0001-secureboot.patch"
git -C "${P}" init -q; git -C "${P}" add -A; git -C "${P}" commit -q -m pkg
P1="$(git -C "${P}" rev-parse HEAD)"

# ark: linux-6.18.y with v6.18.54..56, and kernel-6.18.56-0 = v6.18.56 + a Fedora commit.
A="${T}/ark"; git -C "${T}" init -q ark
for v in 54 55 56; do echo "${v}" > "${A}/Makefile"; git -C "${A}" add -A; git -C "${A}" commit -q -m "Linux 6.18.${v}"; git -C "${A}" tag -a -m "Linux 6.18.${v}" "v6.18.${v}"; done   # annotated, as kernel.org's are (git describe needs that)
git -C "${A}" branch -m linux-6.18.y
git -C "${A}" checkout -q -b ark; mkdir "${A}/redhat"; echo spec > "${A}/redhat/spec"; git -C "${A}" add -A; git -C "${A}" commit -q -m redhat
git -C "${A}" tag kernel-6.18.56-0; git -C "${A}" checkout -q linux-6.18.y

# recipe NAME: a copy of the recipe in ${T}/NAME with pins pointing at the stand-ins.
recipe() {
  local d="${T}/$1"; rm -rf "${d}"; cp -a "${HERE}" "${d}"; rm -rf "${d}/fixups"; mkdir "${d}/fixups"
  cat > "${d}/pins.conf" <<EOF
CONTRIB_URL="file://${C}"
CONTRIB_COMMIT="${C1}"
ARK_URL="file://${A}"
PACKAGE_TAG="kernel-6.18.56-0"
PACKAGE_RELEASE="1"
PKG_PATCHES_URL="file://${P}"
PKG_PATCHES_COMMIT="${P1}"
EOF
  R="${d}"
}
pin() { sed -i "s|^$1=.*|$1=\"$2\"|" "${R}/pins.conf"; }

echo "== a full run"
recipe r1; run bash "${R}/build-srpm.sh" "${T}/out1"; [[ "${RC}" -eq 0 ]] || printf "%s\n" "${OUT}" | tail -n 8
eq "exit 0" 0 "${RC}"
srpms=("${T}"/out1/*.src.rpm); eq "one source package" 1 "${#srpms[@]}"
s="$(cat "${srpms[0]}")"
eq "...named for the pinned kernel and release" "kernel-surface-6.18.56-1.surface.fc44.src.rpm" "${srpms[0]##*/}"
has "srpm mode" '^mode=srpm$' "${s}"; has "PACKAGE_TAG written" '^tag=kernel-6.18.56-0$' "${s}"; has "PACKAGE_RELEASE written" '^release=1$' "${s}"
has "kernel-ark checked out at the tag" '^ark_head=kernel-6.18.56-0$' "${s}"
has "the 6.18-era packaging patches replace the fork's" '^pkg_patches=0001-iptsd.patch,0002-name.patch$' "${s}"
has "...and its secureboot patch" '^sb=era-sb$' "${s}"
has "the pinned commit, not the branch's newer one" '^cam=vanilla-cameras$' "${s}"

echo "== without PKG_PATCHES_COMMIT: the fork's own packaging patches"
recipe r2; pin PKG_PATCHES_COMMIT ""; run bash "${R}/build-srpm.sh" "${T}/out2"
eq "exit 0" 0 "${RC}"; s="$(cat "${T}"/out2/*.src.rpm)"
has "fork's patches kept" '^pkg_patches=0001-fork.patch$' "${s}"; has "...and its secureboot patch" '^sb=fork-sb$' "${s}"

echo "== fixups"
recipe r3
printf 'Why: a test.\n---\ndiff --git a/patches/6.18/0013-cameras.patch b/patches/6.18/0013-cameras.patch\n--- a/patches/6.18/0013-cameras.patch\n+++ b/patches/6.18/0013-cameras.patch\n@@ -1 +1 @@\n-vanilla-cameras\n+fedora-cameras\n' > "${R}/fixups/0001-test.patch"
run bash "${R}/build-srpm.sh" "${T}/out3"; eq "a fixup: exit 0" 0 "${RC}"
s="$(cat "${T}"/out3/*.src.rpm)"; has "...applied" '^cam=fedora-cameras$' "${s}"
printf -- '--- a/nope\n+++ b/nope\n@@ -1 +1 @@\n-x\n+y\n' > "${R}/fixups/0002-stale.patch"
run bash "${R}/build-srpm.sh" "${T}/out3b"; eq "a fixup that doesn't apply: exit 1" 1 "${RC}"; has "...naming it" "fixup 0002-stale.patch doesn't apply" "${OUT}"
n="$(count "${T}/out3b")"; eq "...no source package" 0 "${n}"

echo "== pins are checked before anything is fetched"
for case in "CONTRIB_COMMIT:${C1:0:12}:full 40-digit" "PKG_PATCHES_COMMIT:abc:full commit hash" "PACKAGE_TAG:v6.18.56:look like kernel-" \
            "PACKAGE_TAG:kernel-6.18.0-0:no previous point release" "PACKAGE_RELEASE:0:positive number" "ARK_URL::ARK_URL is empty"; do
  IFS=: read -r k v msg <<<"${case}"; recipe rp; pin "${k}" "${v}"
  run bash "${R}/build-srpm.sh" "${T}/outp"; eq "${k}=${v:-''}: refused" 1 "${RC}"; has "...saying why" "${msg}" "${OUT}"
done
recipe ru; run bash "${R}/build-srpm.sh"; eq "no OUTDIR: usage" 1 "${RC}"; has "...usage" 'usage:' "${OUT}"

echo "== the fetched commit must be the pinned one"
recipe rc; pin CONTRIB_COMMIT "$(printf '%040d' 1)"
run bash "${R}/build-srpm.sh" "${T}/outc"; eq "a commit the repository doesn't have: fails" 1 "${RC}"; has "...saying so" "couldn't fetch commit" "${OUT}"
n="$(count "${T}/outc")"; eq "...no source package" 0 "${n}"

echo "== kernel-ark: the tag must sit on vX.Y.Z of linux-X.Y.y"
git -C "${A}" tag -f kernel-6.18.56-0 v6.18.55 >/dev/null   # a tag on the wrong base
recipe ra; run bash "${R}/build-srpm.sh" "${T}/outa"; eq "tag not based on v6.18.56: refused" 1 "${RC}"
has "...saying so" "error: kernel-ark: .*\(isn't based on v6.18.56\|no common base\)" "${OUT}"
# ...or on a later point release (the branch moved on, and the tag sits on v6.18.57).
git -C "${A}" checkout -q linux-6.18.y; echo 57 > "${A}/Makefile"; git -C "${A}" commit -q -am "Linux 6.18.57"; git -C "${A}" tag -a -m "Linux 6.18.57" v6.18.57
git -C "${A}" checkout -q -b ark57; echo spec57 > "${A}/redhat-spec"; git -C "${A}" add -A; git -C "${A}" commit -q -m redhat57
git -C "${A}" tag -f kernel-6.18.56-0 ark57 >/dev/null; git -C "${A}" checkout -q linux-6.18.y
recipe ra2; run bash "${R}/build-srpm.sh" "${T}/outa2"; eq "tag based on v6.18.57: refused" 1 "${RC}"
has "...saying so" "isn't based on v6.18.56" "${OUT}"
git -C "${A}" tag -f kernel-6.18.56-0 ark >/dev/null

echo "== more than one source package is an error"
recipe rm2; sed -i 's|^(out / f"kernel-surface|(out / "extra.src.rpm").write_text("x")\n(out / f"kernel-surface|' "${C}/pkg/fedora/kernel-surface/build-linux-surface.py"
git -C "${C}" commit -q -am two; C2="$(git -C "${C}" rev-parse HEAD)"; pin CONTRIB_COMMIT "${C2}"
run bash "${R}/build-srpm.sh" "${T}/outm"; eq "two source packages: refused" 1 "${RC}"; has "...saying so" "expected one source package, got 2" "${OUT}"

echo
echo "copr-recipe: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
