FROM d_base_supervisor:latest

RUN apk add --no-cache openssh-server openvswitch frr frr-rpki frr-pythontools \
    && ssh-keygen -A \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config \
    && sed -i 's/#PrintMotd yes/PrintMotd no/g' /etc/ssh/sshd_config \
    # Unlocks the root user so that ssh login is allowed.
    && sed -i s/root:!/"root:*"/g /etc/shadow \
    && mkdir -p /var/run/sshd /root/.ssh \
    && chmod 0755 /var/run/sshd

RUN install -m 755 -o frr -g frr -d /var/log/frr \
    && install -m 755 -o frr -g frr -d /var/run/frr \
    && install -m 775 -o frr -g frrvty -d /etc/frr \
    && install -m 640 -o frr -g frr /dev/null /etc/frr/zebra.conf \
    && install -m 640 -o frr -g frr /dev/null /etc/frr/bgpd.conf \
    && install -m 640 -o frr -g frr /dev/null /etc/frr/ospfd.conf \
    && install -m 640 -o frr -g frr /dev/null /etc/frr/ospf6d.conf \
    && install -m 640 -o frr -g frr /dev/null /etc/frr/isisd.conf \
    && install -m 640 -o frr -g frr /dev/null /etc/frr/ripd.conf \
    && install -m 640 -o frr -g frr /dev/null /etc/frr/ripngd.conf \
    && install -m 640 -o frr -g frr /dev/null /etc/frr/pimd.conf \
    && install -m 640 -o frr -g frr /dev/null /etc/frr/ldpd.conf \
    && install -m 640 -o frr -g frr /dev/null /etc/frr/nhrpd.conf \
    && install -m 640 -o frr -g frrvty /dev/null /etc/frr/vtysh.conf \
    && echo "export VTYSH_PAGER=more" >>  /etc/bash.bashrc \
    && echo "VTYSH_PAGER=more" >> /etc/environment

COPY looking_glass.sh /home/.looking_glass.sh

COPY supervisord.conf /etc/supervisor/conf.d/processes.conf
COPY run_frr.sh /usr/local/bin/run_frr
COPY run_ovs.sh /usr/local/bin/run_ovs

RUN chmod +x /usr/local/bin/run_frr /usr/local/bin/run_ovs
