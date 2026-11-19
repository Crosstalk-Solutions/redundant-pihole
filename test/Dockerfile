# Test image: bare Debian 13 with systemd as PID 1, roughly what a fresh VM looks like.
FROM debian:trixie
ENV container=docker
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv dbus \
      iproute2 curl ca-certificates procps sudo less && apt-get clean && \
    rm -f /lib/systemd/system/multi-user.target.wants/getty* /usr/sbin/policy-rc.d
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
