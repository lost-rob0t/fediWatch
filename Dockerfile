FROM nimlang/nim:2.2.10-alpine AS builder

RUN apk add --no-cache git gcc musl-dev openssl-dev
WORKDIR /build

COPY fediwatch.nimble config.nims ./
RUN nimble install -y --depsOnly

COPY src ./src
RUN nimble buildRelease

FROM alpine:3.22
RUN apk add --no-cache ca-certificates openssl
COPY --from=builder /build/src/fediWatch /usr/local/bin/fediwatch

USER nobody
ENTRYPOINT ["/usr/local/bin/fediwatch"]
