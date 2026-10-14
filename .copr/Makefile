# COPR's "make srpm" source method runs, as root in a fresh Fedora chroot with network access:
#   make -f .copr/Makefile srpm outdir=OUTDIR spec=SPEC
# (spec is unused: build-srpm.sh generates the spec with linux-surface's build-linux-surface.py.)
# The packages are what build-linux-surface.py's SRPM step needs: git, python3, and kernel-ark's
# `make dist-srpm`: rpm-build and the tools its scripts call, plus a host compiler and the kernel's
# own build tools, because it checks the generated configs with the kernel's Kconfig (dist-configs-check).
srpm:
	dnf -y install git-core python3 make rpm-build perl-interpreter findutils xz tar gawk sed diffutils \
		gcc bison flex bc openssl-devel elfutils-libelf-devel dwarves hostname
	bash ./build-srpm.sh "$(outdir)"
