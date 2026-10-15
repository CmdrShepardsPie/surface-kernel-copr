# COPR's "make srpm" source method runs, as root in a fresh Fedora chroot with network access:
#   make -f .copr/Makefile srpm outdir=OUTDIR spec=SPEC
# (spec is unused: build-srpm.sh generates the spec with linux-surface's build-linux-surface.py.)
# The packages: git and python3 for build-srpm.sh, then exactly what linux-surface's own Fedora build
# installs before its SRPM step (.github/scripts/package/fedora.sh setup-builddeps): rpm development
# tools and Fedora kernel's build dependencies. kernel-ark's `make dist-srpm` needs more than packaging
# tools (a compiler and Kconfig for its config check, python3-pyyaml for its sanity checks).
# dnf5's builddep is a plugin (dnf5-plugins), which COPR's minimal chroot doesn't have (Docker's
# fedora images do). Given a package name, it enables the source repositories itself.
srpm:
	dnf -y install git-core python3 make 'dnf5-command(builddep)'
	dnf -y install @rpm-development-tools
	dnf -y builddep kernel
	bash ./build-srpm.sh "$(outdir)"
