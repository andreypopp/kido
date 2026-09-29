# Built and run by scripts/ci-like.sh, which supplies TMUX_REVISION only to
# tag the image (a submodule bump then gets a new tag, not a stale reused
# one); the build itself reads the fork's source from the submodule below.
# Go is only the e2e suite's.
FROM golang:1.27-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
		bash zsh git curl ca-certificates gnupg \
		build-essential bison autoconf automake pkg-config \
		libevent-dev libncurses-dev libutf8proc-dev \
		unzip bubblewrap rsync \
	&& curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
	&& apt-get install -y --no-install-recommends nodejs \
	&& rm -rf /var/lib/apt/lists/*

# The build context is the kido repo root (see ci-like.sh).
ARG TMUX_REVISION
COPY scripts/install-tmux-fork.sh /tmp/build-tmux/scripts/install-tmux-fork.sh
COPY third_party/tmux /tmp/build-tmux/third_party/tmux
RUN test -n "$TMUX_REVISION" \
	&& /tmp/build-tmux/scripts/install-tmux-fork.sh /usr/local/tmux-side \
	&& /usr/local/tmux-side/bin/kido-tmux -V \
	&& rm -rf /tmp/build-tmux

ENV KIDO_TMUX=/usr/local/tmux-side/bin/kido-tmux
ENV PATH=/usr/local/tmux-side/bin:$PATH

# The base image defaults to the C locale, under which zsh's ${var:0:1024}
# counts bytes rather than runes and tmux draws the ASCII glyph fallback,
# failing truncation and e2e row assertions for the environment, not the code.
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Debian's /etc/profile assigns PATH outright, unlike Ubuntu's, which leaves
# an inherited one alone; tmux runs a pane's shell as a login shell, so every
# pane here would otherwise lose the PATH the server started with.
RUN sed -i 's|^  PATH="|  PATH="${PATH:+$PATH:}|' /etc/profile \
	&& grep -q 'PATH:+' /etc/profile

# dune is built from its release tarball with Debian's OCaml rather than
# taken from the binary distribution, which ships no aarch64 Linux build
# and podman on Apple silicon runs an arm64 VM; dune's own bootstrap needs
# only an OCaml >= 4.08. Debian's dune is too old for package management.
ARG DUNE_VERSION=3.24.2
RUN apt-get update && apt-get install -y --no-install-recommends ocaml \
	&& curl -fsSL "https://github.com/ocaml/dune/releases/download/$DUNE_VERSION/dune-$DUNE_VERSION.tbz" | tar xj -C /tmp \
	&& make -C "/tmp/dune-$DUNE_VERSION" release \
	&& make -C "/tmp/dune-$DUNE_VERSION" PREFIX=/usr/local install \
	&& rm -rf "/tmp/dune-$DUNE_VERSION" && apt-get purge -y ocaml && apt-get autoremove -y \
	&& rm -rf /var/lib/apt/lists/* && dune --version

# The dependencies are built as root at image build time and only read at
# run time: ci-like.sh runs as the repo's owner, a uid not known here. A
# project root with just dune-project, dune-workspace and dune.lock is
# enough for the @pkg-install alias; what it builds survives in dune's
# shared cache (dune-workspace enables it for lock packages too), from
# which the run-time build restores every package in seconds. Copies, not
# hardlinks: the cache is root's, the build dir the repo owner's.
ENV DUNE_CACHE_ROOT=/dune-cache
ENV DUNE_CACHE_STORAGE_MODE=copy
ENV XDG_CACHE_HOME=/dune-cache/xdg
COPY dune-project dune-workspace /tmp/kido-deps/
COPY dune.lock /tmp/kido-deps/dune.lock
RUN cd /tmp/kido-deps && dune build @pkg-install \
	&& rm -rf /tmp/kido-deps && chmod -R a+rwX /dune-cache

# dune's build directory is a sibling of the host's _build inside the
# bind-mounted checkout, so a Linux build never overwrites it. Relative on
# purpose: dune 3.24.2's package management dies with "Unexpected external
# path" on an absolute DUNE_BUILD_DIR.
ENV DUNE_BUILD_DIR=_build-ci-like
ENV GOCACHE=/gocache
ENV GOMODCACHE=/go/pkg/mod
RUN mkdir -p /gocache /go/pkg/mod /home/ci && chmod 0777 /gocache /go/pkg/mod /home/ci

WORKDIR /repo
