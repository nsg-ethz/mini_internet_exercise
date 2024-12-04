FROM alpine:3.20

# Install and configure packages which are required in every container
# and make bash the default shell.
RUN apk add --no-cache tini bash bash-completion util-linux coreutils \
    binutils findutils grep vim nano tzdata \
    iputils net-tools bind-tools iperf3 tcptraceroute tcpdump nmap nmap-nping \
    && echo "export PS1=\"\[\033[38;5;2m\]\u@\h \[\033[38;5;75m\]\w\e[m> \"" > /root/.bashrc \
    && sed -i -e "s/bin\/ash/bin\/bash/" /etc/passwd

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV TZ="Europe/Paris"