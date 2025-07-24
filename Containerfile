FROM alpine:latest

RUN apk add --no-cache bash coreutils docker-cli docker-cli-compose git yq rsync

COPY goc.sh /usr/local/bin/goc.sh

RUN chmod +x /usr/local/bin/goc.sh

ENTRYPOINT ["/usr/local/bin/goc.sh"]
