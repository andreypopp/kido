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

# The switch is built as root and only read at run time: ci-like.sh runs
# as the repo's owner, a uid not known at build time. kido.opam brings the
# Mosaic pin-depends; ci-like.sh tags the image with its digest too.
ENV OPAMROOT=/opt/opam OPAMYES=1 OPAMCONFIRMLEVEL=unsafe-yes
RUN curl -fsSL https://opam.ocaml.org/install.sh | sh -s -- --download-only \
	&& install -m 0755 opam-* /usr/local/bin/opam && rm opam-* \
	&& opam init --bare --disable-sandboxing --no-setup \
	&& opam switch create default 5.5.1
COPY kido.opam /tmp/kido-deps/kido.opam
RUN opam install --deps-only --with-test /tmp/kido-deps \
	&& opam clean -a -c -s --logs && rm -rf /tmp/kido-deps && chmod -R a+rX /opt/opam
ENV OPAM_SWITCH_PREFIX=/opt/opam/default
ENV CAML_LD_LIBRARY_PATH=/opt/opam/default/lib/stublibs:/opt/opam/default/lib/ocaml/stublibs:/opt/opam/default/lib/ocaml
ENV PATH=/opt/opam/default/bin:$PATH

# dune's build directory lives outside the bind-mounted checkout, so a
# Linux build never overwrites the host's _build.
ENV DUNE_BUILD_DIR=/dune-build
ENV GOCACHE=/gocache
ENV GOMODCACHE=/go/pkg/mod
RUN mkdir -p /dune-build /gocache /go/pkg/mod /home/ci && chmod 0777 /dune-build /gocache /go/pkg/mod /home/ci

WORKDIR /repo
