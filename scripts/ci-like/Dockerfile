# Built and run by scripts/ci-like.sh. Not meant to be built by hand: the
# script supplies TMUX_REVISION (third_party/tmux's pinned commit, read
# from the gitlink) as a build-arg purely to tag the resulting image with
# it, so a submodule bump produces a new tag rather than a stale reused
# one; the build itself reads the fork's source from the submodule copied
# in below, not from this argument.
FROM golang:1.27-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
		bash zsh git curl ca-certificates gnupg \
		build-essential bison autoconf automake pkg-config \
		libevent-dev libncurses-dev libutf8proc-dev \
	&& curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
	&& apt-get install -y --no-install-recommends nodejs \
	&& rm -rf /var/lib/apt/lists/*

# Built from the vendored submodule, not a clone: the build context is the
# kido repo root (see ci-like.sh), so both the script and third_party/tmux
# are available at the same relative layout the script expects.
ARG TMUX_REVISION
COPY scripts/install-tmux-fork.sh /tmp/build-tmux/scripts/install-tmux-fork.sh
COPY third_party/tmux /tmp/build-tmux/third_party/tmux
RUN test -n "$TMUX_REVISION" \
	&& /tmp/build-tmux/scripts/install-tmux-fork.sh /usr/local/tmux-side \
	&& /usr/local/tmux-side/bin/kido-tmux -V \
	&& rm -rf /tmp/build-tmux

ENV KIDO_TMUX=/usr/local/tmux-side/bin/kido-tmux
ENV PATH=/usr/local/tmux-side/bin:$PATH

# A GitHub runner's Ubuntu image comes up under a UTF-8 locale; this one's
# default is C, under which zsh's ${var:0:1024} counts bytes rather than
# runes and tmux draws the ASCII fallback for kido's box-drawing glyphs -
# so the truncation tests and every e2e assertion on a rendered row fail
# for the environment rather than for the code. C.UTF-8 is built into
# bookworm's glibc, so no locale needs generating.
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# en_US.UTF-8 on top of that, because a GitHub Ubuntu runner has it
# generated and cmd/kido's shell-integration tests ask for it by name to
# get a shell that indexes strings by character. glibc falls back to C for
# a locale it cannot find, silently, so its absence reads as a truncation
# bug rather than a missing locale. Its own layer, after the tmux build,
# so adding it does not invalidate the cached compile.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends locales \
	&& sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
	&& locale-gen en_US.UTF-8 \
	&& rm -rf /var/lib/apt/lists/*

# Debian's /etc/profile assigns PATH outright, where Ubuntu's - what CI
# runs - leaves an inherited one alone. tmux runs a pane's shell as a login
# shell, so on this image every pane lost whatever PATH the server was
# started with: the e2e harness puts a directory holding a fake `pi` ahead
# of the inner server's PATH (startPathPrefix), that pane could not resolve
# the name, and the window died before `kido spawn_subagent` could mark it.
# Keeping the inherited PATH in front restores the runner's behaviour.
RUN sed -i 's|^  PATH="|  PATH="${PATH:+$PATH:}|' /etc/profile \
	&& grep -q 'PATH:+' /etc/profile

# ci-like.sh runs as the repo's owner (a non-root uid), matching the
# runner's `runner` user - a test that chmods a file to 000 and expects it
# unreadable only holds for a uid root ignores. That uid is the host's and
# is not known at build time, so the caches it writes have to be writable
# by any uid.
ENV GOCACHE=/gocache
ENV GOMODCACHE=/go/pkg/mod
RUN mkdir -p /gocache /go/pkg/mod /home/ci && chmod 0777 /gocache /go/pkg/mod /home/ci

WORKDIR /repo
