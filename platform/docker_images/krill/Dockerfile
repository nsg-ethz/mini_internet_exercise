# -- stage 1: build static krill with musl libc for alpine
FROM d_base:latest AS build

# Specify what version of krill should be built.
ARG KRILL_VERSION=0.14.5
ARG BUILD_THREADS=2

RUN apk add wget openssl-dev patch rust cargo

WORKDIR /tmp/krill

RUN wget "https://github.com/NLnetLabs/krill/archive/refs/tags/v${KRILL_VERSION}.tar.gz" -O - | tar -xz --strip-components=1
# Build krill based on the krill's docker image build instructions
RUN CARGO_HTTP_MULTIPLEXING=false cargo install \
  --jobs ${BUILD_THREADS} \
  --locked \
  --features multi-user \
  --path . \
  --root /tmp/out/

# -- stage 2: create image with the static krill executable
FROM d_base_supervisor:latest
COPY --from=build /tmp/out/bin/* /usr/local/bin/

RUN apk add --no-cache haproxy curl rsync libgcc ca-certificates openssl openssh-server \
    && ssh-keygen -A \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config \
    && sed -i 's/#PrintMotd yes/PrintMotd no/g' /etc/ssh/sshd_config \
    # Unlocks the root user so that ssh login is allowed.
    && sed -i s/root:!/"root:*"/g /etc/shadow \
    && mkdir -p /var/run/sshd /root/.ssh \
    && chmod 0755 /var/run/sshd \
    && mkdir -p /var/krill/data/ssl

RUN apk add iproute2-minimal iptables

COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY supervisord.conf /etc/supervisor/conf.d/processes.conf

COPY docker-start /docker-start
RUN chmod +x /docker-start

ENTRYPOINT [ "/docker-start" ]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
