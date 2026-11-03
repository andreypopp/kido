# Built and run by scripts/ci-like.sh; the build context is the repo root.
FROM debian:trixie

RUN printf 'Acquire::Retries "3";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' > /etc/apt/apt.conf.d/80-timeouts
RUN apt-get update && apt-get install -y --no-install-recommends \
		bash zsh git curl ca-certificates gnupg \
		build-essential python3 openssh-client unzip \
		xz-utils less procps strace \
	&& curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
	&& apt-get install -y --no-install-recommends nodejs \
	&& rm -rf /var/lib/apt/lists/*

# The base image defaults to the C locale, under which zsh's ${var:0:1024}
# counts bytes rather than runes, failing truncation and e2e row assertions
# for the environment, not the code.
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Debian's /etc/profile assigns PATH outright, unlike Ubuntu's, which leaves
# an inherited one alone; ko runs a pane's shell as a login shell, so every
# pane here would otherwise lose the PATH the server started with.
RUN sed -i 's|^  PATH="|  PATH="${PATH:+$PATH:}|' /etc/profile \
	&& grep -q 'PATH:+' /etc/profile

# rustup, pinned like the zig release, installs the toolchain
# that rust-toolchain.toml names (`rustup toolchain install` reads it from
# 1.28 on; Debian's rustup is older), and zig builds libghostty-vt for
# ko_vt_sys/build.rs. Root installs both; the run-time user only reads them,
# except for the cargo registry.
ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV PATH=/usr/local/cargo/bin:/usr/local/zig:$PATH
ARG RUSTUP_VERSION=1.29.0
COPY rust-toolchain.toml /tmp/rust-toolchain/rust-toolchain.toml
COPY scripts/install-zig.sh /tmp/install-zig/install-zig.sh
RUN case "$(uname -m)" in \
		aarch64) triple=aarch64-unknown-linux-gnu sum=9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792 ;; \
		x86_64) triple=x86_64-unknown-linux-gnu sum=4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10 ;; \
	esac \
	&& curl -fsSL --connect-timeout 15 --max-time 300 "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/$triple/rustup-init" -o /tmp/rustup-init \
	&& echo "$sum  /tmp/rustup-init" | sha256sum -c - \
	&& chmod +x /tmp/rustup-init \
	&& /tmp/rustup-init -y --profile minimal --default-toolchain none --no-modify-path \
	&& rm /tmp/rustup-init \
	&& cd /tmp/rust-toolchain && rustup toolchain install \
	&& cd / && rm -rf /tmp/rust-toolchain \
	&& chmod -R a+rwX /usr/local/cargo /usr/local/rustup \
	&& bash /tmp/install-zig/install-zig.sh /usr/local/zig && rm -rf /tmp/install-zig

# cargo's target directory and the build/ outputs (the ko install layout and the Verus
# archive) are volumes over the bind mount, so a Linux build never
# overwrites the host's macOS ones.
RUN mkdir -p /repo/target /repo/build /home/ci \
	&& chmod -R 0777 /repo/target /repo/build /home/ci

WORKDIR /repo
