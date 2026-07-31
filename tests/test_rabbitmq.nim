import std/os

import fediwatch/rabbitmq_bridge


proc main() =
  const routingKey = "documents.ingest.user"
  let publisher = newRabbitPublisher(
    parseRabbitAddress(getEnv(
      "TEST_RABBITMQ_URL",
      "amqp://guest:guest@127.0.0.1/"
    )),
    "fediwatch-ci"
  )
  defer:
    publisher.close()

  publisher.bindQueue("fediwatch-ci-confirm", routingKey)
  publisher.publish(
    routingKey = routingKey,
    body = "{\"_id\":\"rabbitmq-ci\",\"dtype\":\"user\"}",
    messageId = "rabbitmq-ci",
    documentType = "user"
  )

  echo "RabbitMQ routed publisher confirm passed"


main()
