import 'package:shared_preferences/shared_preferences.dart';

/// Manages persistent state for the application
/// Tracks setup completion and other app state across app restarts
class StatePersistenceService {
  static const String _keySetupPrepareCompleted = 'setup_prepare_completed';
  static const String _keySetupShowCompleted = 'setup_show_completed';
  static const String _keyPrepareProvingCompleted = 'prepare_proving_completed';

  final SharedPreferences _prefs;

  StatePersistenceService(this._prefs);

  /// Initialize and get the service instance
  static Future<StatePersistenceService> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    return StatePersistenceService(prefs);
  }

  /// Check if setup prepare keys are completed
  bool get isSetupPrepareCompleted =>
      _prefs.getBool(_keySetupPrepareCompleted) ?? false;

  /// Check if setup show keys are completed
  bool get isSetupShowCompleted =>
      _prefs.getBool(_keySetupShowCompleted) ?? false;

  /// Check if both setup tasks are completed
  bool get isSetupCompleted =>
      isSetupPrepareCompleted && isSetupShowCompleted;

  /// Check if prepare proving is completed
  bool get isPrepareProvingCompleted =>
      _prefs.getBool(_keyPrepareProvingCompleted) ?? false;

  /// Count of completed setup tasks (0-2)
  int get setupTasksCompleted {
    int count = 0;
    if (isSetupPrepareCompleted) count++;
    if (isSetupShowCompleted) count++;
    return count;
  }

  /// Mark setup prepare as completed
  Future<void> setSetupPrepareCompleted(bool completed) async {
    await _prefs.setBool(_keySetupPrepareCompleted, completed);
  }

  /// Mark setup show as completed
  Future<void> setSetupShowCompleted(bool completed) async {
    await _prefs.setBool(_keySetupShowCompleted, completed);
  }

  /// Mark prepare proving as completed
  Future<void> setPrepareProvingCompleted(bool completed) async {
    await _prefs.setBool(_keyPrepareProvingCompleted, completed);
  }

  /// Reset all state (useful for testing or "start over")
  Future<void> resetAll() async {
    await _prefs.setBool(_keySetupPrepareCompleted, false);
    await _prefs.setBool(_keySetupShowCompleted, false);
    await _prefs.setBool(_keyPrepareProvingCompleted, false);
  }

  /// Reset only setup state (keep prepare proving state)
  Future<void> resetSetupState() async {
    await _prefs.setBool(_keySetupPrepareCompleted, false);
    await _prefs.setBool(_keySetupShowCompleted, false);
  }

  /// Reset only prepare proving state (keep setup state)
  Future<void> resetPrepareProvingState() async {
    await _prefs.setBool(_keyPrepareProvingCompleted, false);
  }
}
