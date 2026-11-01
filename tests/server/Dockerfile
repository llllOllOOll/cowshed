# A throwaway server for the end-to-end tests: Docker and SSH, nothing of Cowshed's.
FROM docker:dind
RUN apk add --no-cache openssh-server curl && ssh-keygen -A && \
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && \
    passwd -u root || true
COPY start.sh /start.sh
ENTRYPOINT ["/bin/sh", "/start.sh"]
