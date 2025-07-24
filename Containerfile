FROM alpine:latest

RUN apk add --no-cache \
  apprise \
  bash \
  coreutils \
  docker-cli \
  docker-cli-compose \
  git \
  rsync \
  yq

COPY goc.sh /usr/local/bin/goc.sh

RUN chmod +x /usr/local/bin/goc.sh

ENTRYPOINT ["/usr/local/bin/goc.sh"]
