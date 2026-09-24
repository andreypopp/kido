# Built and run by scripts/ci-like.sh. Not meant to be built by hand: the
# script supplies TMUX_REVISION (the Homebrew tap's pinned commit for the
# andreypopp/tmux fork) as a build-arg and tags the resulting image with it,
# so a tap bump produces a new tag rather than a stale reused one.
FROM golang:1.27-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
		bash zsh git curl ca-certificates gnupg \
		build-essential bison autoconf automake pkg-config \
		libevent-dev libncurses-dev libutf8proc-dev \
	&& curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
	&& apt-get install -y --no-install-recommends nodejs \
	&& rm -rf /var/lib/apt/lists/*

ARG TMUX_REVISION
COPY install-tmux-fork.sh /tmp/install-tmux-fork.sh
RUN test -n "$TMUX_REVISION" \
	&& /tmp/install-tmux-fork.sh /usr/local/tmux-side "$TMUX_REVISION" \
	&& /usr/local/tmux-side/bin/tmux -V \
	&& rm /tmp/install-tmux-fork.sh

ENV KIDO_TMUX=/usr/local/tmux-side/bin/tmux
ENV PATH=/usr/local/tmux-side/bin:$PATH

WORKDIR /repo
