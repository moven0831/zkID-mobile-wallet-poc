import 'dart:async';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:uuid/uuid.dart';

import 'background_service.dart';
import 'models/proof_task.dart';
import 'models/proof_result.dart';

/// Manages communication with the background proof service
/// Provides a simple API for the UI to submit tasks and receive results
class ProofServiceManager {
  final FlutterBackgroundService _service = FlutterBackgroundService();
  final _uuid = const Uuid();

  // Stream controllers for different event types
  final _taskQueuedController = StreamController<ProofTask>.broadcast();
  final _taskStartedController = StreamController<ProofTask>.broadcast();
  final _taskCompletedController = StreamController<ProofResult>.broadcast();
  final _taskFailedController = StreamController<ProofResult>.broadcast();
  final _serviceReadyController = StreamController<bool>.broadcast();
  final _serviceErrorController = StreamController<String>.broadcast();

  bool _isInitialized = false;
  bool _isServiceRunning = false;
  Completer<void>? _serviceReadyCompleter;

  // Public stream getters
  Stream<ProofTask> get onTaskQueued => _taskQueuedController.stream;
  Stream<ProofTask> get onTaskStarted => _taskStartedController.stream;
  Stream<ProofResult> get onTaskCompleted => _taskCompletedController.stream;
  Stream<ProofResult> get onTaskFailed => _taskFailedController.stream;
  Stream<bool> get onServiceReady => _serviceReadyController.stream;
  Stream<String> get onServiceError => _serviceErrorController.stream;

  bool get isInitialized => _isInitialized;
  bool get isServiceRunning => _isServiceRunning;

  /// Initialize and start the background service
  Future<bool> initialize() async {
    if (_isInitialized) {
      return true;
    }

    try {
      await _service.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: onBackgroundStart,
          autoStart: false,
          isForegroundMode: true,
          notificationChannelId: 'openac_completion',
          initialNotificationTitle: 'OpenAC',
          initialNotificationContent: 'Initializing...',
          foregroundServiceNotificationId: 888,
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: onBackgroundStart,
          onBackground: onBackgroundStart,
        ),
      );

      _setupEventListeners();
      _isInitialized = true;

      // Check if service is already running
      _isServiceRunning = await _service.isRunning();

      return true;
    } catch (e) {
      _serviceErrorController.add('Failed to initialize service: $e');
      return false;
    }
  }

  /// Start the background service if not already running
  Future<bool> startService() async {
    if (!_isInitialized) {
      final initialized = await initialize();
      if (!initialized) return false;
    }

    if (_isServiceRunning) {
      return true;
    }

    try {
      // Create a completer to wait for service ready
      _serviceReadyCompleter = Completer<void>();

      final started = await _service.startService();
      _isServiceRunning = started;

      if (started) {
        print('   Waiting for service to be fully ready...');
        // Wait for the service to signal it's ready (with timeout)
        await _serviceReadyCompleter!.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            print('   ⚠️  Service ready timeout - proceeding anyway');
          },
        );
        print('   Service is fully ready!');
      }

      return started;
    } catch (e) {
      _serviceErrorController.add('Failed to start service: $e');
      return false;
    }
  }

  /// Stop the background service
  Future<void> stopService() async {
    if (!_isServiceRunning) return;

    _service.invoke('stopService');
    _isServiceRunning = false;
  }

  /// Submit a proof task to the background service
  Future<String> submitTask({
    required ProofTaskType type,
    required String documentsPath,
  }) async {
    print('📝 ProofServiceManager: Submitting task ${type.name}');
    print('   Service running: $_isServiceRunning');
    print('   Service initialized: $_isInitialized');

    // Ensure service is running
    if (!_isServiceRunning) {
      print('   Starting background service...');
      final started = await startService();
      print('   Service started: $started');
      if (!started) {
        throw Exception('Failed to start background service');
      }
    }

    final taskId = _uuid.v4();
    final task = ProofTask(
      id: taskId,
      type: type,
      params: {
        'documentsPath': documentsPath,
      },
    );

    print('   Invoking submitTask with taskId: $taskId');
    _service.invoke('submitTask', task.toJson());
    print('   Task submitted successfully');
    return taskId;
  }

  /// Cancel a pending task
  void cancelTask(String taskId) {
    _service.invoke('cancelTask', {'taskId': taskId});
  }

  /// Set up event listeners for service messages
  void _setupEventListeners() {
    // Service ready event
    _service.on('serviceReady').listen((event) {
      print('📢 Service ready event received');
      _serviceReadyController.add(true);
      // Complete the ready completer if it exists
      if (_serviceReadyCompleter != null && !_serviceReadyCompleter!.isCompleted) {
        _serviceReadyCompleter!.complete();
      }
    });

    // Task queued event
    _service.on('taskQueued').listen((event) {
      if (event != null) {
        try {
          final taskData = Map<String, dynamic>.from(event);
          // Create a minimal task object for queue notification
          final task = ProofTask(
            id: taskData['taskId'] as String,
            type: ProofTaskType.values.firstWhere(
              (e) => e.name == taskData['type'],
            ),
            params: {},
            status: TaskStatus.queued,
          );
          _taskQueuedController.add(task);
        } catch (e) {
          _serviceErrorController.add('Error parsing taskQueued event: $e');
        }
      }
    });

    // Task started event
    _service.on('taskStarted').listen((event) {
      if (event != null) {
        try {
          final task = ProofTask.fromJson(Map<String, dynamic>.from(event));
          _taskStartedController.add(task);
        } catch (e) {
          _serviceErrorController.add('Error parsing taskStarted event: $e');
        }
      }
    });

    // Task completed event
    _service.on('taskCompleted').listen((event) {
      if (event != null) {
        try {
          final result = ProofResult.fromJson(Map<String, dynamic>.from(event));
          _taskCompletedController.add(result);
        } catch (e) {
          _serviceErrorController.add('Error parsing taskCompleted event: $e');
        }
      }
    });

    // Task failed event
    _service.on('taskFailed').listen((event) {
      if (event != null) {
        try {
          final result = ProofResult.fromJson(Map<String, dynamic>.from(event));
          _taskFailedController.add(result);
        } catch (e) {
          _serviceErrorController.add('Error parsing taskFailed event: $e');
        }
      }
    });

    // Service error event
    _service.on('serviceError').listen((event) {
      if (event != null && event['error'] != null) {
        _serviceErrorController.add(event['error'] as String);
      }
    });
  }

  /// Clean up resources
  void dispose() {
    _taskQueuedController.close();
    _taskStartedController.close();
    _taskCompletedController.close();
    _taskFailedController.close();
    _serviceReadyController.close();
    _serviceErrorController.close();
  }
}
