import std/os

import fediwatch/rabbitmq_bridge


let publisher = newRabbitPublisher(
  parseRabbitAddress(getEnv(
    "TEST_RABBITMQ_URL",
    "amqp://guest:guest@127.0.0.1/"
  )),
  "fediwatch-ci"
)

defer:
  publisher.close()

publisher.publish(
  routingKey = "documents.ingest.user",
  body = "{\"_id\":\"rabbitmq-ci\",\"dtype\":\"user\"}",
  messageId = "rabbitmq-ci",
  documentType = "user"
)

echo "RabbitMQ publish integration passed"
