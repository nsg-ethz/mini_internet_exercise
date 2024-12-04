# -- stage 1: build static routinator with musl libc for alpine
FROM d_base:latest AS build

# Specify what version of routinator should be built.
ARG ROUTINATOR_VERSION=0.14.0
ARG BUILD_THREADS=2

RUN apk add wget openssl-dev rust cargo

WORKDIR /tmp/routinator

RUN wget "https://github.com/NLnetLabs/routinator/archive/refs/tags/v${ROUTINATOR_VERSION}.tar.gz" -O - | tar -xz --strip-components=1

RUN CARGO_HTTP_MULTIPLEXING=false cargo install \
    --jobs ${BUILD_THREADS} \
    --features socks,native-tls \
    --locked \
    --path . \
    --root /tmp/out/

# -- stage 2: create image with the static routinator executable
FROM d_base_supervisor:latest
COPY --from=build /tmp/out/bin/* /usr/local/bin/

# Install rsync and ca-certificates as routinator depends on it
# Use Tini to ensure that Routinator responds to CTRL-C when run in the
# foreground without the Docker argument "--init" (which is actually another
# way of activating Tini, but cannot be enabled from inside the Docker image).
RUN apk add --no-cache curl rsync libgcc ca-certificates openssl openssh-server \
    && ssh-keygen -A \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config \
    && sed -i 's/#PrintMotd yes/PrintMotd no/g' /etc/ssh/sshd_config \
    # Unlocks the root user so that ssh login is allowed.
    && sed -i s/root:!/"root:*"/g /etc/shadow \
    && mkdir -p /var/run/sshd /root/.ssh \
    && chmod 0755 /var/run/sshd

# Create the repository and TAL directories
RUN mkdir -p /root/.rpki-cache/repository /root/.rpki-cache/tals

EXPOSE 3323/tcp
EXPOSE 9556/tcp
EXPOSE 22/tcp

COPY routinator.conf /root/.routinator.conf
COPY supervisord.conf /etc/supervisor/conf.d/processes.conf

# Add startup script and set it as entrypoint
COPY docker-start /docker-start
RUN chmod +x /docker-start

ENTRYPOINT [ "/docker-start" ]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
