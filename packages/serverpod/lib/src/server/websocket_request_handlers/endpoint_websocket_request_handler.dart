import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:serverpod/serverpod.dart';
import 'package:serverpod/src/server/session.dart';

/// This class is used by the [Server] to handle incoming websocket requests
/// to an endpoint. It is not intended to be used directly by the user.
abstract class EndpointWebsocketRequestHandler {
  /// Creates a new [StreamingSession] and handles incoming websocket requests.
  /// Returns a [Future] that completes when the websocket is closed.
  ///
  /// This method dispatches incoming messages to the correct endpoint and
  /// handles control messages such as 'ping' and 'auth'.
  static Future<void> handleWebsocket(
    Server server,
    WebSocket webSocket,
    HttpRequest request,
    void Function() onClosed,
  ) async {
    try {
      var session = StreamingSession(
        server: server,
        uri: request.uri,
        httpRequest: request,
        webSocket: webSocket,
      );

      for (var endpointConnector in server.endpoints.connectors.values) {
        await _callStreamOpened(session, endpointConnector.endpoint);
      }
      for (var module in server.endpoints.modules.values) {
        for (var endpointConnector in module.connectors.values) {
          await _callStreamOpened(session, endpointConnector.endpoint);
        }
      }

      dynamic error;
      StackTrace? stackTrace;

      try {
        await for (String jsonData in webSocket) {
          var data = jsonDecode(jsonData) as Map;

          // Handle control commands.
          var command = data['command'] as String?;
          if (command != null) {
            var args = data['args'] as Map;

            if (command == 'ping') {
              webSocket.add(
                SerializationManager.encodeForProtocol(
                  {'command': 'pong'},
                ),
              );
            } else if (command == 'auth') {
              var authKey = args['key'] as String?;
              session.updateAuthenticationKey(authKey);
            }
            continue;
          }

          // Handle messages passed to endpoints.
          var endpointName = data['endpoint'] as String;
          var serialization = data['object'] as Map<String, dynamic>;

          var endpointConnector =
              server.endpoints.getConnectorByName(endpointName);
          if (endpointConnector == null) {
            throw Exception('Endpoint not found: $endpointName');
          }

          var endpoint = endpointConnector.endpoint;
          var authFailed = await EndpointDispatch.canUserAccessEndpoint(
            () => session.authenticated,
            endpoint.requireLogin,
            endpoint.requiredScopes,
          );

          if (authFailed == null) {
            // Process the message.
            var startTime = DateTime.now();
            dynamic messageError;
            StackTrace? messageStackTrace;

            SerializableModel? message;
            try {
              session.endpointName = endpointName;

              message = server.serializationManager
                  .deserializeByClassName(serialization);

              if (message == null) throw Exception('Streamed message was null');

              await endpointConnector.endpoint
                  .handleStreamMessage(session, message);
            } catch (e, s) {
              messageError = e;
              messageStackTrace = s;
              stderr.writeln('${DateTime.now().toUtc()} Internal server error. '
                  'Uncaught exception in handleStreamMessage.');
              stderr.writeln('$e');
              stderr.writeln('$s');
            }

            var duration = DateTime.now().difference(startTime);
            unawaited(session.logManager?.logMessage(
              session,
              messageId: session.nextMessageId(),
              endpointName: endpointName,
              messageName: serialization['className'],
              duration: duration,
              error: messageError?.toString(),
              stackTrace: messageStackTrace,
            ));
          }
        }
      } catch (e, s) {
        error = e;
        stackTrace = s;
      }

      // TODO: Possibly keep a list of open streams instead
      for (var endpointConnector in server.endpoints.connectors.values) {
        await _callStreamClosed(session, endpointConnector.endpoint);
      }
      for (var module in server.endpoints.modules.values) {
        for (var endpointConnector in module.connectors.values) {
          await _callStreamClosed(session, endpointConnector.endpoint);
        }
      }
      await session.close(error: error, stackTrace: stackTrace);
    } catch (e, stackTrace) {
      stderr.writeln('$e');
      stderr.writeln('$stackTrace');
      return;
    } finally {
      onClosed();
    }
  }

  static Future<void> _callStreamOpened(
    StreamingSession session,
    Endpoint endpoint,
  ) async {
    try {
      session.endpointName = endpoint.name;
      var authFailed = await EndpointDispatch.canUserAccessEndpoint(
        () => session.authenticated,
        endpoint.requireLogin,
        endpoint.requiredScopes,
      );
      if (authFailed == null) await endpoint.streamOpened(session);
    } catch (e) {
      return;
    }
  }

  static Future<void> _callStreamClosed(
    StreamingSession session,
    Endpoint endpoint,
  ) async {
    try {
      session.endpointName = endpoint.name;
      var authFailed = await EndpointDispatch.canUserAccessEndpoint(
        () => session.authenticated,
        endpoint.requireLogin,
        endpoint.requiredScopes,
      );
      if (authFailed == null) await endpoint.streamClosed(session);
    } catch (e) {
      return;
    }
  }
}
