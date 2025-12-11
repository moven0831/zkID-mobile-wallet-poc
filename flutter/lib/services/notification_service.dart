import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';

/// Service for managing local notifications
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Initialize the notification service
  Future<bool> initialize() async {
    if (_initialized) return true;

    try {
      // Android initialization settings
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

      // iOS initialization settings
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      final initialized = await _notifications.initialize(
        initSettings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      if (initialized == true) {
        await _createNotificationChannels();
        _initialized = true;
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('Error initializing notifications: $e');
      return false;
    }
  }

  /// Create notification channels for Android
  Future<void> _createNotificationChannels() async {
    // Channel for completion notifications
    const completionChannel = AndroidNotificationChannel(
      'openac_completion',
      'OpenAC Proof Generation',
      description: 'Notifications when proof generation operations complete',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(completionChannel);
  }

  /// Handle notification tap
  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('Notification tapped: ${response.id}');
    // Could navigate to specific screen here if needed
  }

  /// Request notification permissions (iOS)
  Future<bool> requestPermissions() async {
    if (!_initialized) {
      await initialize();
    }

    final iosImplementation = _notifications
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();

    if (iosImplementation != null) {
      final granted = await iosImplementation.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted ?? false;
    }

    // Android doesn't need runtime permission request for notifications
    // (POST_NOTIFICATIONS permission is declared in manifest)
    return true;
  }

  /// Show individual task completion notification
  Future<void> showTaskCompletionNotification({
    required String taskName,
    required int durationMs,
    Map<String, int>? detailedTimings,
  }) async {
    if (!_initialized) return;

    try {
      final durationSeconds = (durationMs / 1000).toStringAsFixed(1);

      // Simple notification showing only total time for this task
      final bodyText = 'Completed in ${durationSeconds}s';

      // Android notification details
      const androidDetails = AndroidNotificationDetails(
        'openac_completion',
        'OpenAC Proof Generation',
        channelDescription: 'Notifications when proof generation operations complete',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        icon: '@mipmap/ic_launcher',
      );

      // iOS notification details
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      const notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      // Use incrementing IDs for individual task notifications (starting from 100)
      final notificationId = 100 + DateTime.now().millisecondsSinceEpoch % 100;

      await _notifications.show(
        notificationId,
        '$taskName Complete',
        bodyText,
        notificationDetails,
      );

      debugPrint('Task completion notification shown: $taskName - $bodyText');
    } catch (e) {
      debugPrint('Error showing task completion notification: $e');
    }
  }

  /// Show batch completion notification with timing summary
  Future<void> showCompletionNotification({
    required Map<String, int> timings,
    required int totalTimeSeconds,
  }) async {
    if (!_initialized) {
      debugPrint('Notification service not initialized');
      return;
    }

    try {
      // Format timing summary
      final timingText = _formatTimingSummary(timings);

      // Android notification details
      const androidDetails = AndroidNotificationDetails(
        'openac_completion',
        'OpenAC Proof Generation',
        channelDescription: 'Notifications when proof generation operations complete',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        icon: '@mipmap/ic_launcher',
      );

      // iOS notification details
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      const notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notifications.show(
        1, // Notification ID
        'All Tasks Complete',
        'Completed in ${totalTimeSeconds}s\n$timingText',
        notificationDetails,
      );

      debugPrint('Batch completion notification shown: $timingText');
    } catch (e) {
      debugPrint('Error showing completion notification: $e');
    }
  }

  /// Format timing summary for notification
  String _formatTimingSummary(Map<String, int> timings) {
    final parts = <String>[];

    if (timings.containsKey('Setup Prepare Keys')) {
      final seconds = (timings['Setup Prepare Keys']! / 1000).toStringAsFixed(1);
      parts.add('Setup Prepare: ${seconds}s');
    }

    if (timings.containsKey('Setup Show Keys')) {
      final seconds = (timings['Setup Show Keys']! / 1000).toStringAsFixed(1);
      parts.add('Setup Show: ${seconds}s');
    }

    if (timings.containsKey('Prove Prepare Circuit')) {
      final seconds = (timings['Prove Prepare Circuit']! / 1000).toStringAsFixed(1);
      parts.add('Prove: ${seconds}s');
    }

    return parts.join(' | ');
  }

  /// Cancel all notifications
  Future<void> cancelAll() async {
    await _notifications.cancelAll();
  }

  /// Cancel specific notification
  Future<void> cancel(int id) async {
    await _notifications.cancel(id);
  }
}
