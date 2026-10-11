#!/bin/sh
exec docker run --init --rm --network=host \
  --env SSL_CERT_FILE=/run/test-ca.pem \
  --mount "type=bind,src=${SSL_CERT_FILE:?},dst=/run/test-ca.pem,readonly" \
  fediwatch:validation "$@"
