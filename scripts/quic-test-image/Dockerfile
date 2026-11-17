FROM debian:trixie
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl supervisor \
 && curl --fail --silent --show-error https://dl.cloudsmith.io/public/caddy/stable/gpg.key > /usr/share/keyrings/caddy-stable-archive-keyring.asc \
 && curl --fail --silent --show-error https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | sed 's@/usr/share/keyrings/caddy-stable-archive-keyring.gpg@/usr/share/keyrings/caddy-stable-archive-keyring.asc@g' > /etc/apt/sources.list.d/caddy-stable.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends caddy \
 && version=$(caddy version | cut -d ' ' -f 1) \
 && dpkg --compare-versions "${version#v}" ge 2.11.4 \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/caddy /var/lib/ko \
 && chmod 700 /var/lib/ko
ENTRYPOINT ["/usr/bin/supervisord", "-n", "-c", "/fixtures/supervisord.conf"]
