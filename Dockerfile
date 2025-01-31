FROM alpine
RUN apk add --no-cache curl bash jq
COPY ai.sh /ai.sh
ENV HOME=/ai
USER nobody
WORKDIR /ai
VOLUME /ai
ENTRYPOINT ["bash", "/ai.sh"]
