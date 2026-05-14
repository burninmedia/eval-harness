# =============================================================================
# eval-harness orchestration image
# =============================================================================
# The harness runs in here so the bash version, grep flavor, jq, curl, etc.
# are pinned. Talks to the *host* Docker daemon via a mounted socket — so all
# child containers (test image, agent's compose stack) run on the host.
#
# Built once by run-eval.sh; layers are cached by Docker after the first run.
# =============================================================================
FROM docker:24-cli

RUN apk add --no-cache \
      bash \
      coreutils \
      findutils \
      grep \
      curl \
      jq \
      nodejs \
      npm \
      tar \
      docker-cli-compose

WORKDIR /opt/harness

COPY run-eval-container.sh ./
COPY checks/ ./checks/
COPY report/ ./report/
COPY templates/ ./templates/

RUN chmod +x run-eval-container.sh checks/*.sh report/*.sh

ENTRYPOINT ["/opt/harness/run-eval-container.sh"]
