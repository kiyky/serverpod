import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:serverpod/serverpod.dart';
import 'package:serverpod/src/server/features.dart';
import 'package:serverpod/src/server/log_manager/log_manager.dart';
import 'package:serverpod/src/server/log_manager/log_writer.dart';
import 'package:serverpod/src/server/log_manager/session_log_cache.dart';
import 'package:serverpod/src/server/serverpod.dart';
import '../cache/caches.dart';
import '../database/database.dart';

/// When a call is made to the [Server] a [Session] object is created. It
/// contains all data associated with the current connection and provides
/// easy access to the database.
abstract class Session {
  /// The id of the session.
  final UuidValue sessionId;

  /// The [Server] that created the session.
  final Server server;

  /// The [Serverpod] this session is running on.
  Serverpod get serverpod => server.serverpod;

  late DateTime _startTime;

  /// The time the session object was created.
  DateTime get startTime => _startTime;

  /// Log messages saved during the session.
  @internal
  late final SessionLogEntryCache sessionLogs;

  int? _messageId;

  AuthenticationInfo? _authenticated;

  /// Updates the authentication information for the session.
  /// This is typically done by the [Server] when the user is authenticated.
  /// Using this method modifies the authenticated user for this session.
  void updateAuthenticated(AuthenticationInfo? info) {
    _initialized = true;
    _authenticated = info;
  }

  /// The authentication information for the session.
  /// This will be null if the session is not authenticated.
  Future<AuthenticationInfo?> get authenticated async {
    if (!_initialized) await _initialize();
    return _authenticated;
  }

  /// Returns true if the user is signed in.
  Future<bool> get isUserSignedIn async {
    return (await authenticated) != null;
  }

  String? _authenticationKey;

  /// The authentication key used to authenticate the session.
  String? get authenticationKey => _authenticationKey;

  /// An custom object associated with this [Session]. This is especially
  /// useful for keeping track of the state in a [StreamingEndpoint].
  dynamic userObject;

  /// Access to the database.
  Database? _db;

  /// Access to the database.
  Database get db {
    var database = _db;
    if (database == null) {
      throw Exception('Database is not available in this session.');
    }
    return database;
  }

  /// Provides access to all caches used by the server.
  Caches get caches => server.caches;

  /// Map of passwords loaded from config/passwords.yaml
  Map<String, String> get passwords => server.passwords;

  /// Provides access to the cloud storages used by this [Serverpod].
  late final StorageAccess storage;

  /// Access to the [MessageCentral] for passing real time messages between
  /// web socket streams and other listeners.
  late MessageCentralAccess messages;

  bool _closed = false;

  /// True if logging is enabled for this session. Normally, logging should be
  /// enabled but it will be disabled for internal sessions used by Serverpod.
  final bool enableLogging;

  late final SessionLogManager? _logManager;

  /// Endpoint that triggered this session.
  final String endpointName;

  /// Method that triggered this session, if any.
  final String? methodName;

  /// Creates a new session. This is typically done internally by the [Server].
  Session({
    UuidValue? sessionId,
    required this.server,
    String? authenticationKey,
    HttpRequest? httpRequest,
    WebSocket? webSocket,
    required this.enableLogging,
    required this.endpointName,
    int? messageId,
    this.methodName,
  })  : _authenticationKey = authenticationKey,
        _messageId = messageId,
        sessionId = sessionId ?? const Uuid().v4obj() {
    _startTime = DateTime.now();

    storage = StorageAccess._(this);
    messages = MessageCentralAccess._(this);

    if (Features.enableDatabase) {
      _db = server.createDatabase(this);
    }

    if (enableLogging) {
      var logWriter = Features.enablePersistentLogging
          ? DatabaseLogWriter()
          : StdOutLogWriter();
      _logManager = SessionLogManager(
        logWriter,
        settingsForSession: (Session session) => server
            .serverpod.logSettingsManager
            .getLogSettingsForSession(session),
        serverId: server.serverId,
      );
    } else {
      _logManager = null;
    }

    sessionLogs = server.serverpod.logManager.initializeSessionLog(this);
  }

  bool _initialized = false;

  Future<void> _initialize() async {
    if (server.authenticationHandler == null) {
      stderr.write(
        'No authentication handler is set, authentication is disabled, '
        'all requests to protected endpoints will be rejected.',
      );
    }

    if (server.authenticationHandler != null && _authenticationKey != null) {
      _authenticated =
          await server.authenticationHandler!(this, _authenticationKey!);
    }

    _initialized = true;
  }

  /// Returns the duration this session has been open.
  Duration get duration => DateTime.now().difference(_startTime);

  /// Closes the session. This method should only be called if you have
  /// manually created a the [Session] e.g. by calling [createSession] on
  /// [Serverpod]. Closing the session finalizes and writes logs to the
  /// database. After a session has been closed, you should not call any
  /// more methods on it. Optionally pass in an [error]/exception and
  /// [stackTrace] if the session ended with an error and it should be written
  /// to the logs. Returns the session id, if the session has been logged to the
  /// database.
  Future<int?> close({
    dynamic error,
    StackTrace? stackTrace,
  }) async {
    if (_closed) return null;
    _closed = true;

    try {
      if (_logManager == null && error != null) {
        serverpod.logVerbose(error);
        if (stackTrace != null) {
          serverpod.logVerbose(stackTrace.toString());
        }
      }

      server.messageCentral.removeListenersForSession(this);
      return await _logManager?.finalizeSessionLog(
        this,
        exception: error == null ? null : '$error',
        stackTrace: stackTrace,
        authenticatedUserId: _authenticated?.userId,
      );
    } catch (e, stackTrace) {
      stderr.writeln('Failed to close session: $e');
      stderr.writeln('$stackTrace');
    }
    return null;
  }

  /// Logs a message. Default [LogLevel] is [LogLevel.info]. The log is written
  /// to the database when the session is closed.
  void log(
    String message, {
    LogLevel? level,
    dynamic exception,
    StackTrace? stackTrace,
  }) {
    if (_closed) {
      throw StateError(
        'Session is closed, and logging can no longer be performed.',
      );
    }

    _logManager?.logEntry(
      this,
      message: message,
      level: level ?? LogLevel.info,
      error: exception?.toString(),
      stackTrace: stackTrace,
    );
  }
}

/// A Session used internally in the [ServerPod]. Typically used to access
/// the database and do logging for events that are not triggered from a call,
/// or a stream.
class InternalSession extends Session {
  /// Creates a new [InternalSession]. Consider using the createSession
  /// method of [ServerPod] to create a new session.
  InternalSession({
    required super.server,
    super.enableLogging = true,
  }) : super(endpointName: 'InternalSession');
}

/// When a call is made to the [Server] a [MethodCallSession] object is created.
/// It contains all data associated with the current connection and provides
/// easy access to the database.
class MethodCallSession extends Session {
  /// The uri that was used to call the server.
  final Uri uri;

  /// The body of the server call.
  final String body;

  /// Query parameters of the server call.
  final Map<String, dynamic> queryParameters;

  final String _methodName;

  /// The name of the method that is being called.
  @override
  String get methodName => _methodName;

  /// The [HttpRequest] associated with the call.
  final HttpRequest httpRequest;

  /// Creates a new [Session] for a method call to an endpoint.
  MethodCallSession({
    required super.server,
    required this.uri,
    required this.body,
    required String path,
    required this.httpRequest,
    required super.endpointName,
    required String methodName,
    required this.queryParameters,
    required super.authenticationKey,
    super.enableLogging = true,
  })  : _methodName = methodName,
        super(methodName: methodName);
}

/// When a request is made to the web server a [WebCallSession] object is
/// created. It contains all data associated with the current connection and
/// provides easy access to the database.
class WebCallSession extends Session {
  /// Creates a new [Session] for a method call to an endpoint.
  WebCallSession({
    required super.server,
    required super.endpointName,
    required super.authenticationKey,
    super.enableLogging = true,
  });
}

/// When a connection is made to the [Server] to an endpoint method that uses a
/// stream [MethodStreamSession] object is created. It contains all data
/// associated with the current connection and provides easy access to the
/// database.
class MethodStreamSession extends Session {
  /// The connection id that uniquely identifies the stream.
  final UuidValue connectionId;

  final String _methodName;

  @override
  String get methodName => _methodName;

  /// Creates a new [MethodStreamSession].
  MethodStreamSession({
    required super.server,
    required super.enableLogging,
    required super.authenticationKey,
    required super.endpointName,
    required String methodName,
    required this.connectionId,
  })  : _methodName = methodName,
        super(methodName: methodName, messageId: 0);
}

/// When a web socket connection is opened to the [Server] a [StreamingSession]
/// object is created. It contains all data associated with the current
/// connection and provides easy access to the database.
class StreamingSession extends Session {
  /// The uri that was used to call the server.
  final Uri uri;

  /// Query parameters of the server call.
  late final Map<String, String> queryParameters;

  /// The [HttpRequest] associated with the call.
  final HttpRequest httpRequest;

  /// The underlying web socket that handles communication with the server.
  final WebSocket webSocket;

  /// Set if there is an open session log.
  int? sessionLogId;

  String _endpointName;

  /// The name of the endpoint that is being called.
  set endpointName(String endpointName) => _endpointName = endpointName;

  @override
  String get endpointName => _endpointName;

  /// Creates a new [Session] for the web socket stream.
  StreamingSession({
    required super.server,
    required this.uri,
    required this.httpRequest,
    required this.webSocket,
    super.endpointName = 'StreamingSession',
    super.enableLogging = true,
  })  : _endpointName = endpointName,
        super(messageId: 0) {
    // Read query parameters
    var queryParameters = <String, String>{};
    queryParameters.addAll(uri.queryParameters);
    this.queryParameters = queryParameters;

    // Get the the authentication key, if any
    _authenticationKey = queryParameters['auth'];
  }

  /// Updates the authentication key for the streaming session.
  @internal
  void updateAuthenticationKey(String? authenticationKey) {
    _authenticationKey = authenticationKey;
    _initialized = false;
  }
}

/// Created when a [FutureCall] is being made. It contains all data associated
/// with the current call and provides easy access to the database.
class FutureCallSession extends Session {
  /// Name of the [FutureCall].
  final String futureCallName;

  /// Creates a new [Session] for a [FutureCall].
  FutureCallSession({
    required super.server,
    required this.futureCallName,
    super.enableLogging = true,
  }) : super(endpointName: 'FutureCall', methodName: futureCallName);
}

/// Collects methods for accessing cloud storage.
class StorageAccess {
  final Session _session;

  StorageAccess._(this._session);

  /// Store a file in the cloud storage. [storageId] is typically 'public' or
  /// 'private'. The public storage can be accessed through a public URL. The
  /// file is stored at the [path] relative to the cloud storage root directory,
  /// if a file already exists it will be replaced.
  Future<void> storeFile({
    required String storageId,
    required String path,
    required ByteData byteData,
    DateTime? expiration,
  }) async {
    var storage = _session.server.serverpod.storage[storageId];
    if (storage == null) {
      throw CloudStorageException('Storage $storageId is not registered');
    }

    await storage.storeFile(session: _session, path: path, byteData: byteData);
  }

  /// Retrieve a file from cloud storage.
  Future<ByteData?> retrieveFile({
    required String storageId,
    required String path,
  }) async {
    var storage = _session.server.serverpod.storage[storageId];
    if (storage == null) {
      throw CloudStorageException('Storage $storageId is not registered');
    }

    return await storage.retrieveFile(session: _session, path: path);
  }

  /// Checks if a file exists in cloud storage.
  Future<bool> fileExists({
    required String storageId,
    required String path,
  }) async {
    var storage = _session.server.serverpod.storage[storageId];
    if (storage == null) {
      throw CloudStorageException('Storage $storageId is not registered');
    }

    return await storage.fileExists(session: _session, path: path);
  }

  /// Deletes a file from cloud storage.
  Future<void> deleteFile({
    required String storageId,
    required String path,
  }) async {
    var storage = _session.server.serverpod.storage[storageId];
    if (storage == null) {
      throw CloudStorageException('Storage $storageId is not registered');
    }

    await storage.deleteFile(session: _session, path: path);
  }

  /// Gets the public URL for a file, if the [storageId] is a public storage.
  Future<Uri?> getPublicUrl({
    required String storageId,
    required String path,
  }) async {
    var storage = _session.server.serverpod.storage[storageId];
    if (storage == null) {
      throw CloudStorageException('Storage $storageId is not registered');
    }

    return await storage.getPublicUrl(session: _session, path: path);
  }

  /// Bulk lookup of a list of public links to files given a list of paths in
  /// the storage. If any given file isn't public or if no such file exists,
  /// null is stored at the corresponding position in the output list. Saves
  /// on server roundtrips if a large number of public URLs must be fetched,
  /// relative to calling [getPublicUrl] via an endpoint for each one.
  Future<List<Uri?>> getPublicUrls({
    required String storageId,
    required List<String> paths,
  }) =>
      Future.wait(
          paths.map((path) => getPublicUrl(storageId: storageId, path: path)));

  /// Creates a new file upload description, that can be passed to the client's
  /// [FileUploader]. After the file has been uploaded, the
  /// [verifyDirectFileUpload] method should be called, or the file may be
  /// deleted.
  Future<String?> createDirectFileUploadDescription({
    required String storageId,
    required String path,
  }) async {
    var storage = _session.server.serverpod.storage[storageId];
    if (storage == null) {
      throw CloudStorageException('Storage $storageId is not registered');
    }

    return await storage.createDirectFileUploadDescription(
        session: _session, path: path);
  }

  /// Call this method after a file has been uploaded. It will return true
  /// if the file was successfully uploaded.
  Future<bool> verifyDirectFileUpload({
    required String storageId,
    required String path,
  }) async {
    var storage = _session.server.serverpod.storage[storageId];
    if (storage == null) {
      throw CloudStorageException('Storage $storageId is not registered');
    }

    return await storage.verifyDirectFileUpload(session: _session, path: path);
  }
}

/// Provides access to the Serverpod's [MessageCentral].
class MessageCentralAccess {
  final Session _session;

  MessageCentralAccess._(this._session);

  /// Adds a listener to a named channel. Whenever a message is posted using
  /// [postMessage], the [listener] will be notified.
  void addListener(
    String channelName,
    MessageCentralListenerCallback listener,
  ) {
    _session.server.messageCentral.addListener(
      _session,
      channelName,
      listener,
    );
  }

  /// Removes a listener from a named channel.
  void removeListener(
      String channelName, MessageCentralListenerCallback listener) {
    _session.server.messageCentral
        .removeListener(_session, channelName, listener);
  }

  /// Posts a [message] to a named channel. If [global] is set to true, the
  /// message will be posted to all servers in the cluster, otherwise it will
  /// only be posted locally on the current server. Returns true if the message
  /// was successfully posted.
  ///
  /// Returns true if the message was successfully posted.
  ///
  /// Throws a [StateError] if Redis is not enabled and [global] is set to true.
  Future<bool> postMessage(
    String channelName,
    SerializableModel message, {
    bool global = false,
  }) =>
      _session.server.messageCentral.postMessage(
        channelName,
        message,
        global: global,
      );
}

/// Internal methods for [Session].
/// This is used to provide access to internal methods that should not be
/// accessed from outside the library.
extension SessionInternalMethods on Session {
  /// Returns the [LogManager] for the session.
  SessionLogManager? get logManager => _logManager;

  /// Returns the next message id for the session.
  int? get messageId => _messageId;

  /// Returns the next message id for the session.
  int nextMessageId() {
    var id = _messageId ?? 0;
    _messageId = id + 1;

    return id;
  }
}
