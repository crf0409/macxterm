FROM ubuntu:24.04
ARG TEST_UID=501
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server python3 ca-certificates && rm -rf /var/lib/apt/lists/* \
    && useradd --uid ${TEST_UID} --create-home --shell /bin/bash macxterm \
    && echo 'macxterm:fixture-password-only' | chpasswd \
    && mkdir -p /run/sshd
# The public fixture password is only for an isolated, loopback-published test container.
# Test keys and configuration are generated at runtime and mounted, never baked into the image.
EXPOSE 22337 22340
COPY echo_server.py /opt/echo_server.py
COPY entrypoint.sh /opt/entrypoint.sh
ENTRYPOINT ["/bin/bash", "/opt/entrypoint.sh"]
