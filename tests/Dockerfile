FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        bats \
        shellcheck \
        jq \
        curl \
        openssh-client \
        util-linux \
        lsb-release \
        procps \
        coreutils \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

# Source tree is mounted at /work via -v from run-in-docker.sh.
CMD ["bash", "tests/run.sh"]
