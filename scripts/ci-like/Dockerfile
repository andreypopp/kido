# Built and run by scripts/ci-like.sh, which supplies TMUX_REVISION only to
# tag the image (a submodule bump then gets a new tag, not a stale reused
# one); the build itself reads the fork's source from the submodule below.
FROM golang:1.27-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
		bash zsh git curl ca-certificates gnupg \
		build-essential bison autoconf automake pkg-config \
		libevent-dev libncurses-dev libutf8proc-dev \
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

# cmd/kido's shell-integration tests ask for en_US.UTF-8 by name; glibc
# falls back to C silently if it is missing, which reads as a truncation
# bug rather than a missing locale.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends locales \
	&& sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
	&& locale-gen en_US.UTF-8 \
	&& rm -rf /var/lib/apt/lists/*

# Debian's /etc/profile assigns PATH outright, unlike Ubuntu's, which leaves
# an inherited one alone; tmux runs a pane's shell as a login shell, so every
# pane here would otherwise lose the PATH the server started with.
RUN sed -i 's|^  PATH="|  PATH="${PATH:+$PATH:}|' /etc/profile \
	&& grep -q 'PATH:+' /etc/profile

# ci-like.sh runs as the repo's owner, a uid not known at build time, so
# the caches it writes have to be writable by any uid.
ENV GOCACHE=/gocache
ENV GOMODCACHE=/go/pkg/mod
RUN mkdir -p /gocache /go/pkg/mod /home/ci && chmod 0777 /gocache /go/pkg/mod /home/ci

WORKDIR /repo
