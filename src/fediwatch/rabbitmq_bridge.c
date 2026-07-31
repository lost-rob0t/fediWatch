#if defined(__has_include)
#  if __has_include(<rabbitmq-c/amqp.h>)
#    include <rabbitmq-c/amqp.h>
#    include <rabbitmq-c/ssl_socket.h>
#    include <rabbitmq-c/tcp_socket.h>
#  else
#    include <amqp.h>
#    include <amqp_ssl_socket.h>
#    include <amqp_tcp_socket.h>
#  endif
#else
#  include <amqp.h>
#  include <amqp_ssl_socket.h>
#  include <amqp_tcp_socket.h>
#endif

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#define FW_CHANNEL 1
#define FW_FRAME_MAX 131072
#define FW_HEARTBEAT 30
#define FW_CONFIRM_TIMEOUT_SECONDS 10

typedef struct fw_rabbit_handle {
  amqp_connection_state_t connection;
  char *exchange;
} fw_rabbit_handle;

static void fw_error(char *buffer, size_t length, const char *message) {
  if (buffer == NULL || length == 0) {
    return;
  }
  snprintf(buffer, length, "%s", message == NULL ? "unknown RabbitMQ error" : message);
}

static int fw_rpc_ok(amqp_rpc_reply_t reply, char *error, size_t error_length) {
  switch (reply.reply_type) {
  case AMQP_RESPONSE_NORMAL:
    return 1;
  case AMQP_RESPONSE_NONE:
    fw_error(error, error_length, "RabbitMQ returned no RPC reply");
    return 0;
  case AMQP_RESPONSE_LIBRARY_EXCEPTION:
    fw_error(error, error_length, amqp_error_string2(reply.library_error));
    return 0;
  case AMQP_RESPONSE_SERVER_EXCEPTION:
    if (error != NULL && error_length > 0) {
      snprintf(error, error_length, "RabbitMQ server exception method 0x%08X",
               reply.reply.id);
    }
    return 0;
  default:
    fw_error(error, error_length, "unknown RabbitMQ RPC reply type");
    return 0;
  }
}

void *fw_rabbit_connect(const char *host, int port, int use_tls,
                        const char *ca_cert, const char *username,
                        const char *password, const char *vhost,
                        const char *exchange, char *error,
                        size_t error_length) {
  fw_rabbit_handle *handle = NULL;
  amqp_socket_t *socket = NULL;
  int status;

  if (host == NULL || username == NULL || password == NULL || vhost == NULL ||
      exchange == NULL) {
    fw_error(error, error_length, "RabbitMQ connection arguments cannot be null");
    return NULL;
  }

  handle = calloc(1, sizeof(*handle));
  if (handle == NULL) {
    fw_error(error, error_length, "out of memory allocating RabbitMQ handle");
    return NULL;
  }

  handle->exchange = strdup(exchange);
  if (handle->exchange == NULL) {
    fw_error(error, error_length, "out of memory copying RabbitMQ exchange");
    free(handle);
    return NULL;
  }

  handle->connection = amqp_new_connection();
  if (handle->connection == NULL) {
    fw_error(error, error_length, "could not allocate RabbitMQ connection");
    free(handle->exchange);
    free(handle);
    return NULL;
  }

  if (use_tls) {
    socket = amqp_ssl_socket_new(handle->connection);
    if (socket == NULL) {
      fw_error(error, error_length, "could not allocate RabbitMQ TLS socket");
      goto fail;
    }
    if (ca_cert == NULL || ca_cert[0] == '\0') {
      fw_error(error, error_length, "RabbitMQ TLS CA certificate path is empty");
      goto fail;
    }
    status = amqp_ssl_socket_set_cacert(socket, ca_cert);
    if (status != AMQP_STATUS_OK) {
      fw_error(error, error_length, amqp_error_string2(status));
      goto fail;
    }
    amqp_ssl_socket_set_verify_peer(socket, 1);
    amqp_ssl_socket_set_verify_hostname(socket, 1);
  } else {
    socket = amqp_tcp_socket_new(handle->connection);
    if (socket == NULL) {
      fw_error(error, error_length, "could not allocate RabbitMQ TCP socket");
      goto fail;
    }
  }

  status = amqp_socket_open(socket, host, port);
  if (status != AMQP_STATUS_OK) {
    fw_error(error, error_length, amqp_error_string2(status));
    goto fail;
  }

  if (!fw_rpc_ok(amqp_login(handle->connection, vhost, 0, FW_FRAME_MAX,
                            FW_HEARTBEAT, AMQP_SASL_METHOD_PLAIN, username,
                            password),
                 error, error_length)) {
    goto fail;
  }

  amqp_channel_open(handle->connection, FW_CHANNEL);
  if (!fw_rpc_ok(amqp_get_rpc_reply(handle->connection), error, error_length)) {
    goto fail;
  }

  amqp_exchange_declare(handle->connection, FW_CHANNEL,
                        amqp_cstring_bytes(handle->exchange),
                        amqp_cstring_bytes("topic"), 0, 1, 0, 0,
                        amqp_empty_table);
  if (!fw_rpc_ok(amqp_get_rpc_reply(handle->connection), error, error_length)) {
    goto fail;
  }

  amqp_confirm_select(handle->connection, FW_CHANNEL);
  if (!fw_rpc_ok(amqp_get_rpc_reply(handle->connection), error, error_length)) {
    goto fail;
  }

  return handle;

fail:
  if (handle->connection != NULL) {
    amqp_destroy_connection(handle->connection);
  }
  free(handle->exchange);
  free(handle);
  return NULL;
}

int fw_rabbit_bind_queue(void *opaque_handle, const char *queue,
                         const char *routing_key, char *error,
                         size_t error_length) {
  fw_rabbit_handle *handle = opaque_handle;

  if (handle == NULL || queue == NULL || routing_key == NULL) {
    fw_error(error, error_length, "RabbitMQ queue binding arguments cannot be null");
    return -1;
  }

  amqp_queue_declare(handle->connection, FW_CHANNEL, amqp_cstring_bytes(queue),
                     0, 0, 1, 1, amqp_empty_table);
  if (!fw_rpc_ok(amqp_get_rpc_reply(handle->connection), error, error_length)) {
    return -2;
  }

  amqp_queue_bind(handle->connection, FW_CHANNEL, amqp_cstring_bytes(queue),
                  amqp_cstring_bytes(handle->exchange),
                  amqp_cstring_bytes(routing_key), amqp_empty_table);
  if (!fw_rpc_ok(amqp_get_rpc_reply(handle->connection), error, error_length)) {
    return -3;
  }

  return AMQP_STATUS_OK;
}

static int fw_wait_for_confirm(fw_rabbit_handle *handle, char *error,
                               size_t error_length) {
  int returned = 0;

  for (;;) {
    amqp_frame_t frame;
    struct timeval timeout = {FW_CONFIRM_TIMEOUT_SECONDS, 0};
    int status = amqp_simple_wait_frame_noblock(handle->connection, &frame,
                                                 &timeout);
    if (status != AMQP_STATUS_OK) {
      fw_error(error, error_length, amqp_error_string2(status));
      return status;
    }

    if (frame.frame_type != AMQP_FRAME_METHOD || frame.channel != FW_CHANNEL) {
      continue;
    }

    switch (frame.payload.method.id) {
    case AMQP_BASIC_RETURN_METHOD: {
      amqp_message_t message;
      amqp_rpc_reply_t reply =
          amqp_read_message(handle->connection, FW_CHANNEL, &message, 0);
      if (!fw_rpc_ok(reply, error, error_length)) {
        return -4;
      }
      amqp_destroy_message(&message);
      returned = 1;
      break;
    }
    case AMQP_BASIC_ACK_METHOD:
      if (returned) {
        fw_error(error, error_length,
                 "RabbitMQ rejected the routing key as unroutable");
        return -5;
      }
      return AMQP_STATUS_OK;
    case AMQP_BASIC_NACK_METHOD:
      fw_error(error, error_length, "RabbitMQ negatively acknowledged the message");
      return -6;
    case AMQP_CHANNEL_CLOSE_METHOD:
      fw_error(error, error_length, "RabbitMQ closed the publishing channel");
      return -7;
    case AMQP_CONNECTION_CLOSE_METHOD:
      fw_error(error, error_length, "RabbitMQ closed the connection");
      return -8;
    default:
      break;
    }
  }
}

int fw_rabbit_publish(void *opaque_handle, const char *routing_key,
                      const char *body, const char *message_id,
                      const char *document_type, char *error,
                      size_t error_length) {
  fw_rabbit_handle *handle = opaque_handle;
  amqp_basic_properties_t properties;
  int status;

  if (handle == NULL || routing_key == NULL || body == NULL ||
      message_id == NULL || document_type == NULL) {
    fw_error(error, error_length, "RabbitMQ publish arguments cannot be null");
    return -1;
  }

  memset(&properties, 0, sizeof(properties));
  properties._flags = AMQP_BASIC_CONTENT_TYPE_FLAG |
                      AMQP_BASIC_CONTENT_ENCODING_FLAG |
                      AMQP_BASIC_DELIVERY_MODE_FLAG |
                      AMQP_BASIC_MESSAGE_ID_FLAG |
                      AMQP_BASIC_TYPE_FLAG | AMQP_BASIC_APP_ID_FLAG;
  properties.content_type = amqp_cstring_bytes("application/json");
  properties.content_encoding = amqp_cstring_bytes("utf-8");
  properties.delivery_mode = 2;
  properties.message_id = amqp_cstring_bytes(message_id);
  properties.type = amqp_cstring_bytes(document_type);
  properties.app_id = amqp_cstring_bytes("fediwatch");

  status = amqp_basic_publish(
      handle->connection, FW_CHANNEL, amqp_cstring_bytes(handle->exchange),
      amqp_cstring_bytes(routing_key), 1, 0, &properties,
      amqp_cstring_bytes(body));
  if (status != AMQP_STATUS_OK) {
    fw_error(error, error_length, amqp_error_string2(status));
    return status;
  }

  return fw_wait_for_confirm(handle, error, error_length);
}

void fw_rabbit_close(void *opaque_handle) {
  fw_rabbit_handle *handle = opaque_handle;
  if (handle == NULL) {
    return;
  }

  if (handle->connection != NULL) {
    amqp_channel_close(handle->connection, FW_CHANNEL, AMQP_REPLY_SUCCESS);
    amqp_connection_close(handle->connection, AMQP_REPLY_SUCCESS);
    amqp_destroy_connection(handle->connection);
  }

  free(handle->exchange);
  free(handle);
}
