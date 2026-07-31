FROM nim:2.2.10 AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates gcc git libc6-dev librabbitmq-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY fediwatch.nimble config.nims ./
RUN nimble install -y --depsOnly

COPY src ./src
RUN nimble buildRelease

FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates librabbitmq4 libssl3t64 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/src/fediWatch /usr/local/bin/fediwatch
USER nobody
ENTRYPOINT ["/usr/local/bin/fediwatch"]
