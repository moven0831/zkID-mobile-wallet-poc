import 'dart:async';
import 'dart:collection';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:mopro_flutter_bindings/src/rust/third_party/spartan2_hyrax_mopro.dart';
import 'package:mopro_flutter_bindings/src/rust/frb_generated.dart';

import 'models/proof_task.dart';
import 'models/proof_result.dart';
import 'notification_service.dart';
import 'state_persistence_service.dart';

/// Entry point for the background service
/// This function runs in a separate isolate and persists even after app closure
@pragma('vm:entry-point')
Future<bool> onBackgroundStart(ServiceInstance service) async {
  // Required for Flutter plugins to work in background isolate
  DartPluginRegistrant.ensureInitialized();

  // Initialize Rust bridge once for all operations
  try {
    await RustLib.init();
  } catch (e) {
    service.invoke('serviceError', {
      'error': 'Failed to initialize Rust bridge: $e',
    });
    service.stopSelf();
    return false;
  }

  // Initialize notification service BEFORE setting up foreground service
  final notificationService = NotificationService();
  await notificationService.initialize();
  await notificationService.requestPermissions();

  // Initialize state persistence service
  final stateService = await StatePersistenceService.initialize();

  // Set up foreground notification on Android AFTER notification channels are created
  if (service is AndroidServiceInstance) {
    // Wait a bit to ensure notification channels are fully registered
    await Future.delayed(const Duration(milliseconds: 200));

    service.setAsForegroundService();

    // Configure notification to use our created channel
    await service.setForegroundNotificationInfo(
      title: 'OpenAC',
      content: 'Processing cryptographic operations',
    );
  }

  // Task queue and processing state
  final taskQueue = Queue<ProofTask>();
  bool isProcessing = false;

  // Notify UI that service is ready
  service.invoke('serviceReady', {
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  });

  // Listen for task submissions from UI
  service.on('submitTask').listen((event) {
    if (event == null) return;

    try {
      final task = ProofTask.fromJson(Map<String, dynamic>.from(event));
      taskQueue.add(task);

      service.invoke('taskQueued', {
        'taskId': task.id,
        'type': task.type.name,
        'queueLength': taskQueue.length,
      });

      // Start processing if not already running
      if (!isProcessing) {
        unawaited(_processQueue(
          service,
          taskQueue,
          () => isProcessing,
          (value) => isProcessing = value,
          notificationService,
          stateService,
        ));
      }
    } catch (e) {
      service.invoke('serviceError', {
        'error': 'Failed to queue task: $e',
      });
    }
  });

  // Listen for cancellation requests
  service.on('cancelTask').listen((event) {
    if (event == null) return;
    final taskId = event['taskId'] as String?;
    if (taskId != null) {
      taskQueue.removeWhere((task) => task.id == taskId);
      service.invoke('taskCancelled', {'taskId': taskId});
    }
  });

  // Listen for stop service command
  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  return true; // Service started successfully
}

/// Process tasks from the queue sequentially
Future<void> _processQueue(
  ServiceInstance service,
  Queue<ProofTask> queue,
  bool Function() isProcessingGetter,
  void Function(bool) isProcessingSetter,
  NotificationService notificationService,
  StatePersistenceService stateService,
) async {
  isProcessingSetter(true);

  final batchStartTime = DateTime.now();
  final Map<String, int> completedTaskTimings = {};
  final List<ProofTask> completedTasks = [];

  while (queue.isNotEmpty) {
    final task = queue.removeFirst();
    await _executeTask(service, task, notificationService, stateService);

    // Track completed task
    if (task.status == TaskStatus.completed && task.durationMs != null) {
      completedTasks.add(task);
      completedTaskTimings[_taskTypeToDisplayName(task.type)] = task.durationMs!;
    }
  }

  isProcessingSetter(false);

  // Calculate total batch time
  final totalBatchTime = DateTime.now().difference(batchStartTime);
  final totalSeconds = totalBatchTime.inSeconds;

  // Update notification when all tasks complete
  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'zkID Proof Generation',
      content: 'All tasks completed in ${totalSeconds}s',
    );
  }

  // Send completion notification if any tasks completed
  if (completedTasks.isNotEmpty) {
    await notificationService.showCompletionNotification(
      timings: completedTaskTimings,
      totalTimeSeconds: totalSeconds,
    );

    // Notify UI about batch completion
    service.invoke('batchCompleted', {
      'completedCount': completedTasks.length,
      'totalTimeSeconds': totalSeconds,
      'timings': completedTaskTimings,
    });
  }
}

/// Execute a single proof task
Future<void> _executeTask(
  ServiceInstance service,
  ProofTask task,
  NotificationService notificationService,
  StatePersistenceService stateService,
) async {
  task.status = TaskStatus.running;
  task.startedAt = DateTime.now();

  // Notify UI that task started
  service.invoke('taskStarted', task.toJson());

  try {
    String result;
    final documentsPath = task.params['documentsPath'] as String;

    // Update notification with current task
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'zkID Proof Generation',
        content: 'Running ${_taskTypeToDisplayName(task.type)}...',
      );
    }

    // Execute the appropriate Rust function based on task type
    switch (task.type) {
      case ProofTaskType.setupPrepare:
        result = await setupPrepareKeys(documentsPath: documentsPath);
      case ProofTaskType.setupShow:
        result = await setupShowKeys(documentsPath: documentsPath);
      case ProofTaskType.provePrepare:
        result = await provePrepareCircuit(documentsPath: documentsPath);
    }

    // Parse result and extract timings
    task.status = TaskStatus.completed;
    task.completedAt = DateTime.now();

    final proofResult = ProofResult.fromRustOutput(
      taskId: task.id,
      taskType: task.type,
      rustOutput: result,
    );

    // Persist task completion state
    switch (task.type) {
      case ProofTaskType.setupPrepare:
        await stateService.setSetupPrepareCompleted(true);
      case ProofTaskType.setupShow:
        await stateService.setSetupShowCompleted(true);
      case ProofTaskType.provePrepare:
        await stateService.setPrepareProvingCompleted(true);
    }

    // Send individual task completion notification with detailed timings
    if (task.durationMs != null) {
      // Convert timings to Map<String, int>
      Map<String, int>? timingsMap;
      if (proofResult.timings != null) {
        final jsonMap = proofResult.timings!.toJson();
        timingsMap = jsonMap.map((key, value) =>
          MapEntry(key, value as int? ?? 0)).cast<String, int>();
      }

      await notificationService.showTaskCompletionNotification(
        taskName: _taskTypeToDisplayName(task.type),
        durationMs: task.durationMs!,
        detailedTimings: timingsMap,
      );
    }

    // Notify UI of completion
    service.invoke('taskCompleted', {
      ...task.toJson(),
      ...proofResult.toJson(),
    });
  } catch (e, stackTrace) {
    task.status = TaskStatus.failed;
    task.completedAt = DateTime.now();

    final failedResult = ProofResult.failed(
      taskId: task.id,
      taskType: task.type,
      error: e.toString(),
    );

    // Notify UI of failure
    service.invoke('taskFailed', {
      ...task.toJson(),
      ...failedResult.toJson(),
      'stackTrace': stackTrace.toString(),
    });
  }
}

/// Convert task type to human-readable display name
String _taskTypeToDisplayName(ProofTaskType type) {
  return switch (type) {
    ProofTaskType.setupPrepare => 'Setup Prepare Keys',
    ProofTaskType.setupShow => 'Setup Show Keys',
    ProofTaskType.provePrepare => 'Prove Prepare Circuit',
  };
}
