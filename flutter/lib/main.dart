import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'package:mopro_flutter_bindings/src/rust/third_party/spartan2_hyrax_mopro.dart';
import 'package:mopro_flutter_bindings/src/rust/frb_generated.dart';

import 'services/proof_service_manager.dart';
import 'services/models/proof_task.dart';
import 'services/models/proof_result.dart';
import 'services/notification_service.dart';
import 'services/state_persistence_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await _copyAssetsToDocuments();
  runApp(const MyApp());
}

/// Copy circuit R1CS files and input data from Flutter assets to documents directory
/// This allows Rust code to access them at runtime
/// Compressed .gz files are automatically decompressed during copying
Future<void> _copyAssetsToDocuments() async {
  try {
    final documentsDir = await getApplicationDocumentsDirectory();
    final circomDir = Directory('${documentsDir.path}/circom');

    // Create circom directory if it doesn't exist
    if (!await circomDir.exists()) {
      await circomDir.create(recursive: true);
    }

    // Compressed assets (will be decompressed during copy)
    final compressedAssets = {
      'assets/circom/jwt.r1cs.gz': 'jwt.r1cs',
      'assets/circom/show.r1cs.gz': 'show.r1cs',
    };

    // Regular assets (copied as-is)
    final regularAssets = [
      'assets/circom/jwt_input.json',
      'assets/circom/show_input.json',
    ];

    // Decompress and copy compressed assets
    for (final entry in compressedAssets.entries) {
      final assetPath = entry.key;
      final fileName = entry.value;
      final targetFile = File('${circomDir.path}/$fileName');

      // Only copy if file doesn't exist (avoid overwriting on every startup)
      if (!await targetFile.exists()) {
        debugPrint('Decompressing asset: $assetPath -> ${targetFile.path}');
        try {
          final data = await rootBundle.load(assetPath);
          final compressed = data.buffer.asUint8List();

          // Decompress using gzip
          final decompressed = gzip.decode(compressed);
          await targetFile.writeAsBytes(decompressed);

          final compressedMB = (compressed.length / 1024 / 1024).toStringAsFixed(2);
          final decompressedMB = (decompressed.length / 1024 / 1024).toStringAsFixed(2);
          debugPrint('Decompressed $fileName: ${compressedMB}MB -> ${decompressedMB}MB');
        } catch (e) {
          debugPrint('Failed to decompress $assetPath: $e');
          rethrow;
        }
      }
    }

    // Copy regular assets (no decompression needed)
    for (final assetPath in regularAssets) {
      final fileName = assetPath.split('/').last;
      final targetFile = File('${circomDir.path}/$fileName');

      if (!await targetFile.exists()) {
        debugPrint('Copying asset: $assetPath -> ${targetFile.path}');
        final data = await rootBundle.load(assetPath);
        final bytes = data.buffer.asUint8List();
        await targetFile.writeAsBytes(bytes);
        debugPrint('Copied $fileName (${bytes.length} bytes)');
      }
    }
  } catch (e) {
    debugPrint('Error copying assets: $e');
    // Don't throw - allow app to start even if asset copying fails
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0891B2), // Teal accent
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          color: Colors.white,
        ),
        useMaterial3: true,
      ),
      home: const OpenACScreen(),
    );
  }
}

// Application state enum
enum AppState {
  welcome,          // Initial welcome state - needs to get started
  initializing,     // Keys being set up
  ready,            // Ready to receive VC
  vcReceived,       // Processing VC (prepare proving)
  proofReady,       // Ready to generate show proof
  proofGenerated,   // Show proof generated, display metrics
  error             // Error state
}

class OpenACScreen extends StatefulWidget {
  const OpenACScreen({super.key});

  @override
  State<OpenACScreen> createState() => _OpenACScreenState();
}

class _OpenACScreenState extends State<OpenACScreen> {
  AppState _currentState = AppState.welcome;
  String? _errorMessage;
  bool _expandTechnicalDetails = false;
  int _setupTasksCompleted = 0;

  // Proof metrics
  Map<String, int>? _proofTimings;
  int? _proofSize;
  String? _fullResult;

  // Background service manager
  final ProofServiceManager _serviceManager = ProofServiceManager();
  bool _serviceInitialized = false;

  // State persistence service
  StatePersistenceService? _stateService;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  @override
  void dispose() {
    _serviceManager.dispose();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    try {
      await initApp();

      // Initialize state persistence service
      _stateService = await StatePersistenceService.initialize();

      // Restore persisted state
      await _restorePersistedState();

      // Initialize and request notification permissions
      final notificationService = NotificationService();
      await notificationService.initialize();
      await notificationService.requestPermissions();

      // Initialize background service (but don't start key setup yet)
      await _initializeBackgroundService();
    } catch (e) {
      setState(() {
        _currentState = AppState.error;
        _errorMessage = 'Initialization failed: $e';
      });
    }
  }

  Future<void> _restorePersistedState() async {
    if (_stateService == null) return;

    setState(() {
      // Restore setup completion state
      _setupTasksCompleted = _stateService!.setupTasksCompleted;

      // Determine the appropriate app state based on persisted data
      if (_stateService!.isSetupCompleted) {
        // Both setup tasks completed
        if (_stateService!.isPrepareProvingCompleted) {
          // Prepare proving also completed → ready to generate show proof
          _currentState = AppState.proofReady;
        } else {
          // Just setup completed → ready to receive credentials
          _currentState = AppState.ready;
        }
      } else if (_setupTasksCompleted > 0) {
        // Partial setup completed → still initializing
        _currentState = AppState.initializing;
      }
      // else: stay in welcome state (default)
    });

    debugPrint('State restored: $_currentState, setup tasks: $_setupTasksCompleted');
  }

  Future<void> _initializeBackgroundService() async {
    try {
      final initialized = await _serviceManager.initialize();
      setState(() {
        _serviceInitialized = initialized;
      });

      if (!initialized) {
        debugPrint('Failed to initialize background service');
        return;
      }

      // Set up event listeners for background service
      _serviceManager.onTaskStarted.listen((task) {
        debugPrint('Task started: ${task.type.name}');
      });

      _serviceManager.onTaskCompleted.listen((result) {
        debugPrint('Task completed: ${result.taskType.name}');

        setState(() {
          // Track setup completion
          if (result.taskType == ProofTaskType.setupPrepare ||
              result.taskType == ProofTaskType.setupShow) {
            _setupTasksCompleted++;

            // Both setup tasks complete → Ready state
            if (_setupTasksCompleted >= 2) {
              _currentState = AppState.ready;
            }
          }

          // Prepare proving complete → Proof Ready state
          if (result.taskType == ProofTaskType.provePrepare) {
            _currentState = AppState.proofReady;
            // Store timings for technical details
            if (result.timings != null) {
              _proofTimings = {
                'prepare': result.timings!.totalMs,
              };
            }
          }
        });
      });

      _serviceManager.onTaskFailed.listen((result) {
        setState(() {
          _currentState = AppState.error;
          _errorMessage = 'Task failed: ${result.error}';
        });
        debugPrint('Task failed: ${result.taskType.name} - ${result.error}');
      });

      _serviceManager.onServiceError.listen((error) {
        setState(() {
          _currentState = AppState.error;
          _errorMessage = 'Service error: $error';
        });
        debugPrint('Service error: $error');
      });
    } catch (e) {
      debugPrint('Error initializing background service: $e');
      setState(() {
        _serviceInitialized = false;
        _currentState = AppState.error;
        _errorMessage = 'Failed to initialize background service: $e';
      });
    }
  }

  Future<void> _onGetStarted() async {
    if (!_serviceInitialized) {
      setState(() {
        _currentState = AppState.error;
        _errorMessage = 'Background service not initialized';
      });
      return;
    }

    setState(() {
      _currentState = AppState.initializing;
    });

    try {
      final documentsPath = await _getDocumentsPath();

      // Submit setup tasks sequentially
      await _serviceManager.submitTask(
        type: ProofTaskType.setupPrepare,
        documentsPath: documentsPath,
      );

      await _serviceManager.submitTask(
        type: ProofTaskType.setupShow,
        documentsPath: documentsPath,
      );

      debugPrint('Key setup tasks submitted to background service');
    } catch (e) {
      setState(() {
        _currentState = AppState.error;
        _errorMessage = 'Failed to start key setup: $e';
      });
    }
  }

  Future<void> _onReceiveCredential() async {
    if (!_serviceInitialized) return;

    setState(() {
      _currentState = AppState.vcReceived;
    });

    try {
      final documentsPath = await _getDocumentsPath();

      // Submit prepare proving task
      await _serviceManager.submitTask(
        type: ProofTaskType.provePrepare,
        documentsPath: documentsPath,
      );

      debugPrint('Prepare proving task submitted');
    } catch (e) {
      setState(() {
        _currentState = AppState.error;
        _errorMessage = 'Failed to process credential: $e';
      });
    }
  }

  Future<void> _onGenerateProof() async {
    setState(() {
      _currentState = AppState.initializing; // Show progress
    });

    try {
      final documentsPath = await _getDocumentsPath();

      // Run show circuit proving (fast, synchronous)
      final result = await proveShowCircuit(documentsPath: documentsPath);

      // Parse timings and proof size
      final timings = _parseDetailedTimings(result);

      setState(() {
        _currentState = AppState.proofGenerated;
        _fullResult = result;
        _proofTimings = timings;
        _proofSize = timings?['proofSize'];
        _expandTechnicalDetails = true; // Auto-expand on success
      });
    } catch (e) {
      setState(() {
        _currentState = AppState.error;
        _errorMessage = 'Failed to generate proof: $e';
      });
    }
  }

  Future<void> _onStartOver() async {
    // Reset prepare proving state but keep setup state
    await _stateService?.resetPrepareProvingState();

    setState(() {
      _currentState = AppState.ready;
      _errorMessage = null;
      _proofTimings = null;
      _proofSize = null;
      _fullResult = null;
      _expandTechnicalDetails = false;
    });
  }

  Future<void> _onRetry() async {
    // Reset all persisted state on retry
    await _stateService?.resetAll();

    setState(() {
      _currentState = AppState.welcome;
      _errorMessage = null;
      _setupTasksCompleted = 0;
    });
  }

  Future<String> _getDocumentsPath() async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  Map<String, int>? _parseDetailedTimings(String result) {
    final Map<String, int> timings = {};

    final setupMatch = RegExp(r'Setup: (\d+)ms').firstMatch(result);
    if (setupMatch != null) {
      timings['setup'] = int.parse(setupMatch.group(1)!);
    }

    final prepMatch = RegExp(r'Prep: (\d+)ms').firstMatch(result);
    if (prepMatch != null) {
      timings['prep'] = int.parse(prepMatch.group(1)!);
    }

    final proveMatch = RegExp(r'Prove: (\d+)ms').firstMatch(result);
    if (proveMatch != null) {
      timings['prove'] = int.parse(proveMatch.group(1)!);
    }

    final verifyMatch = RegExp(r'Verify: (\d+)ms').firstMatch(result);
    if (verifyMatch != null) {
      timings['verify'] = int.parse(verifyMatch.group(1)!);
    }

    final totalMatch = RegExp(r'Total: (\d+)ms').firstMatch(result);
    if (totalMatch != null) {
      timings['total'] = int.parse(totalMatch.group(1)!);
    }

    final proofMatch = RegExp(r'Proof: (\d+) bytes').firstMatch(result);
    if (proofMatch != null) {
      timings['proofSize'] = int.parse(proofMatch.group(1)!);
    }

    return timings.isNotEmpty ? timings : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text(
          'OpenAC',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusCard(),
            const SizedBox(height: 16),
            _buildActionCard(),
            const SizedBox(height: 16),
            _buildTechnicalDetails(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final (icon, title, subtitle, showProgress, color) = _getStatusInfo();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            if (showProgress)
              SizedBox(
                width: 64,
                height: 64,
                child: CircularProgressIndicator(
                  strokeWidth: 4,
                  color: color,
                ),
              )
            else
              Icon(
                icon,
                size: 64,
                color: color,
              ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1F2937),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 14,
                color: const Color(0xFF6B7280),
              ),
              textAlign: TextAlign.center,
            ),

            // Show proof metrics prominently when generated
            if (_currentState == AppState.proofGenerated && _proofTimings != null) ...[
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildMetricColumn(
                    'Proof Size',
                    _proofSize != null
                        ? '${(_proofSize! / 1024).toStringAsFixed(2)} KB'
                        : 'N/A',
                  ),
                  _buildMetricColumn(
                    'Proving Time',
                    _proofTimings!['prove'] != null
                        ? '${(_proofTimings!['prove']! / 1000).toStringAsFixed(2)}s'
                        : 'N/A',
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricColumn(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Color(0xFF0891B2),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF6B7280),
          ),
        ),
      ],
    );
  }

  (IconData, String, String, bool, Color) _getStatusInfo() {
    switch (_currentState) {
      case AppState.welcome:
        return (
          Icons.wb_sunny_outlined,
          'Welcome to OpenAC',
          'Anonymous Credentials made simple',
          false,
          const Color(0xFF0891B2),
        );

      case AppState.initializing:
        return (
          Icons.hourglass_empty,
          'System Initializing',
          'Setting up cryptographic keys...',
          true,
          const Color(0xFF0891B2),
        );

      case AppState.ready:
        return (
          Icons.check_circle,
          'System Ready',
          'Ready to receive credentials',
          false,
          const Color(0xFF10B981),
        );

      case AppState.vcReceived:
        return (
          Icons.hourglass_empty,
          'Credential Received',
          'Preparing proof...',
          true,
          const Color(0xFF0891B2),
        );

      case AppState.proofReady:
        return (
          Icons.shield_outlined,
          'Proof Ready',
          'Credential verified, ready to present',
          false,
          const Color(0xFF10B981),
        );

      case AppState.proofGenerated:
        return (
          Icons.verified,
          'Proof Generated Successfully',
          'Proof is ready to be shared with verifier',
          false,
          const Color(0xFF10B981),
        );

      case AppState.error:
        return (
          Icons.error_outline,
          'Error',
          _errorMessage ?? 'An error occurred',
          false,
          const Color(0xFFEF4444),
        );
    }
  }

  Widget _buildActionCard() {
    final (buttonText, onPressed, isEnabled) = _getActionInfo();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: isEnabled ? onPressed : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0891B2),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              elevation: isEnabled ? 2 : 0,
            ),
            child: Text(
              buttonText,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  (String, VoidCallback?, bool) _getActionInfo() {
    switch (_currentState) {
      case AppState.welcome:
        return ('Get Started', _onGetStarted, true);

      case AppState.initializing:
        return ('Please Wait...', null, false);

      case AppState.ready:
        return ('Receive Credential', _onReceiveCredential, true);

      case AppState.vcReceived:
        return ('Processing...', null, false);

      case AppState.proofReady:
        return ('Generate Proof for Verifier', _onGenerateProof, true);

      case AppState.proofGenerated:
        return ('Start Over', _onStartOver, true);

      case AppState.error:
        return ('Retry', _onRetry, true);
    }
  }

  Widget _buildTechnicalDetails() {
    // Don't show if no data yet
    if (_proofTimings == null && _fullResult == null) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: const Text(
            'Technical Details',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1F2937),
            ),
          ),
          initiallyExpanded: _expandTechnicalDetails,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_proofTimings != null) ...[
                    const Text(
                      'Timing Breakdown:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_proofTimings!.containsKey('setup'))
                      _buildTimingRow('Setup', _proofTimings!['setup']!),
                    if (_proofTimings!.containsKey('prep'))
                      _buildTimingRow('Preparation', _proofTimings!['prep']!),
                    if (_proofTimings!.containsKey('prove'))
                      _buildTimingRow('Proving', _proofTimings!['prove']!),
                    if (_proofTimings!.containsKey('verify'))
                      _buildTimingRow('Verification', _proofTimings!['verify']!),
                    if (_proofTimings!.containsKey('total')) ...[
                      const SizedBox(height: 8),
                      const Divider(),
                      const SizedBox(height: 8),
                      _buildTimingRow('Total', _proofTimings!['total']!, bold: true),
                    ],
                    if (_proofTimings!.containsKey('prepare')) ...[
                      _buildTimingRow('Prepare Proving', _proofTimings!['prepare']!),
                    ],
                  ],
                  if (_fullResult != null) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'Raw Output:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF9FAFB),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                      ),
                      child: Text(
                        _fullResult!,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Color(0xFF374151),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimingRow(String label, int ms, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: const Color(0xFF6B7280),
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          Text(
            '${ms}ms (${(ms / 1000).toStringAsFixed(2)}s)',
            style: TextStyle(
              fontSize: 12,
              color: const Color(0xFF1F2937),
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
