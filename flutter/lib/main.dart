import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'package:mopro_flutter_bindings/src/rust/frb_generated.dart';
import 'package:mopro_flutter_bindings/src/rust/third_party/spartan2_hyrax_mopro.dart'
    show
        BenchmarkResults,
        ProofResult,
        generateSharedBlinds,
        provePrepare,
        proveShow,
        reblindPrepare,
        reblindShow,
        runCompleteBenchmark,
        setupPrepareKeys,
        setupShowKeys,
        verifyPrepare,
        verifyShow;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await _copyAssetsToDocuments();
  runApp(const MyApp());
}

/// Copy circuit R1CS files and input data from Flutter assets to documents directory
Future<void> _copyAssetsToDocuments() async {
  try {
    final documentsDir = await getApplicationDocumentsDirectory();
    final circomDir = Directory('${documentsDir.path}/circom');

    if (!await circomDir.exists()) {
      await circomDir.create(recursive: true);
    }

    // Create subdirectories matching Rust circuit expectations
    final jwtBuildDir = Directory('${circomDir.path}/build/jwt/jwt_js');
    final showBuildDir = Directory('${circomDir.path}/build/show/show_js');

    if (!await jwtBuildDir.exists()) {
      await jwtBuildDir.create(recursive: true);
    }
    if (!await showBuildDir.exists()) {
      await showBuildDir.create(recursive: true);
    }

    final compressedAssets = {
      'assets/circom/jwt.r1cs.gz': 'build/jwt/jwt_js/jwt.r1cs',
      'assets/circom/show.r1cs.gz': 'build/show/show_js/show.r1cs',
    };

    final regularAssets = [
      'assets/circom/jwt_input.json',
      'assets/circom/show_input.json',
    ];

    for (final entry in compressedAssets.entries) {
      final targetFile = File('${circomDir.path}/${entry.value}');
      if (!await targetFile.exists()) {
        debugPrint('Decompressing: ${entry.key}');
        final data = await rootBundle.load(entry.key);
        final compressed = data.buffer.asUint8List();
        final decompressed = gzip.decode(compressed);
        await targetFile.writeAsBytes(decompressed);
        debugPrint(
            'Decompressed ${entry.value}: ${(compressed.length / 1024 / 1024).toStringAsFixed(2)}MB → ${(decompressed.length / 1024 / 1024).toStringAsFixed(2)}MB');
      }
    }

    for (final assetPath in regularAssets) {
      final fileName = assetPath.split('/').last;
      final targetFile = File('${circomDir.path}/$fileName');
      if (!await targetFile.exists()) {
        debugPrint('Copying: $assetPath');
        final data = await rootBundle.load(assetPath);
        await targetFile.writeAsBytes(data.buffer.asUint8List());
      }
    }
  } catch (e) {
    debugPrint('Error copying assets: $e');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const E2EProofWorkflowScreen(),
    );
  }
}

class E2EProofWorkflowScreen extends StatefulWidget {
  const E2EProofWorkflowScreen({super.key});

  @override
  State<E2EProofWorkflowScreen> createState() =>
      _E2EProofWorkflowScreenState();
}

enum ProofTaskType {
  setupPrepare,
  setupShow,
  generateBlinds,
  provePrepare,
  proveShow,
  reblindPrepare,
  reblindShow,
  verifyPrepare,
  verifyShow,
}

class TaskResult {
  final ProofTaskType taskType;
  final bool success;
  final String? error;
  final ProofResult? proofResult;
  final String? message;
  final bool? verifyResult;
  final int? clientTimingMs;

  TaskResult({
    required this.taskType,
    required this.success,
    this.error,
    this.proofResult,
    this.message,
    this.verifyResult,
    this.clientTimingMs,
  });

  BigInt? get totalMs => proofResult?.totalMs ?? (clientTimingMs != null ? BigInt.from(clientTimingMs!) : null);
  BigInt? get proofSizeBytes => proofResult?.proofSizeBytes;
  String? get commWShared => proofResult?.commWShared;
}

class _E2EProofWorkflowScreenState extends State<E2EProofWorkflowScreen> {
  // Operation state
  bool _isOperating = false;
  Exception? _error;

  // Step results
  Map<String, TaskResult> _results = {};
  Map<String, bool> _completedSteps = {};

  BenchmarkResults? _benchmarkResults;

  Future<String> _getDocumentsPath() async {
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}/circom';
  }

  String? _getInputPath(ProofTaskType taskType) {
    if (taskType == ProofTaskType.setupPrepare ||
        taskType == ProofTaskType.provePrepare) {
      return 'jwt_input.json';
    } else if (taskType == ProofTaskType.setupShow ||
        taskType == ProofTaskType.proveShow) {
      return 'show_input.json';
    }
    return null;
  }

  Future<void> _runOperation(ProofTaskType taskType) async {
    setState(() {
      _isOperating = true;
      _error = null;
    });

    try {
      final documentsPath = await _getDocumentsPath();
      final inputPath = _getInputPath(taskType);
      TaskResult result;

      switch (taskType) {
        case ProofTaskType.setupPrepare:
          final startTime = DateTime.now();
          final message = await setupPrepareKeys(
            documentsPath: documentsPath,
            inputPath: inputPath,
          );
          final elapsed = DateTime.now().difference(startTime).inMilliseconds;
          result = TaskResult(
            taskType: taskType,
            success: true,
            message: message,
            clientTimingMs: elapsed,
          );
          break;

        case ProofTaskType.setupShow:
          final startTime = DateTime.now();
          final message = await setupShowKeys(
            documentsPath: documentsPath,
            inputPath: inputPath,
          );
          final elapsed = DateTime.now().difference(startTime).inMilliseconds;
          result = TaskResult(
            taskType: taskType,
            success: true,
            message: message,
            clientTimingMs: elapsed,
          );
          break;

        case ProofTaskType.generateBlinds:
          final startTime = DateTime.now();
          final message = await generateSharedBlinds(
            documentsPath: documentsPath,
          );
          final elapsed = DateTime.now().difference(startTime).inMilliseconds;
          result = TaskResult(
            taskType: taskType,
            success: true,
            message: message,
            clientTimingMs: elapsed,
          );
          break;

        case ProofTaskType.provePrepare:
          final proofResult = await provePrepare(
            documentsPath: documentsPath,
            inputPath: inputPath,
          );
          result = TaskResult(
            taskType: taskType,
            success: true,
            proofResult: proofResult,
          );
          break;

        case ProofTaskType.proveShow:
          final proofResult = await proveShow(
            documentsPath: documentsPath,
            inputPath: inputPath,
          );
          result = TaskResult(
            taskType: taskType,
            success: true,
            proofResult: proofResult,
          );
          break;

        case ProofTaskType.reblindPrepare:
          final proofResult = await reblindPrepare(
            documentsPath: documentsPath,
          );
          result = TaskResult(
            taskType: taskType,
            success: true,
            proofResult: proofResult,
          );
          break;

        case ProofTaskType.reblindShow:
          final proofResult = await reblindShow(
            documentsPath: documentsPath,
          );
          result = TaskResult(
            taskType: taskType,
            success: true,
            proofResult: proofResult,
          );
          break;

        case ProofTaskType.verifyPrepare:
          final startTime = DateTime.now();
          final verifyResult = await verifyPrepare(
            documentsPath: documentsPath,
          );
          final elapsed = DateTime.now().difference(startTime).inMilliseconds;
          result = TaskResult(
            taskType: taskType,
            success: verifyResult,
            verifyResult: verifyResult,
            clientTimingMs: elapsed,
          );
          break;

        case ProofTaskType.verifyShow:
          final startTime = DateTime.now();
          final verifyResult = await verifyShow(
            documentsPath: documentsPath,
          );
          final elapsed = DateTime.now().difference(startTime).inMilliseconds;
          result = TaskResult(
            taskType: taskType,
            success: verifyResult,
            verifyResult: verifyResult,
            clientTimingMs: elapsed,
          );
          break;
      }

      setState(() {
        _results[taskType.name] = result;
        _completedSteps[taskType.name] = result.success;
        _isOperating = false;
      });
    } catch (e) {
      setState(() {
        final result = TaskResult(
          taskType: taskType,
          success: false,
          error: e.toString(),
        );
        _results[taskType.name] = result;
        _completedSteps[taskType.name] = false;
        _error = Exception('${_taskTypeToDisplayName(taskType)} failed: $e');
        _isOperating = false;
      });
    }
  }

  Future<void> _runBenchmark() async {
    setState(() {
      _isOperating = true;
      _error = null;
      _benchmarkResults = null;
    });

    try {
      final documentsPath = await _getDocumentsPath();
      final startTime = DateTime.now();

      final results = await runCompleteBenchmark(
        documentsPath: documentsPath,
        inputPath: null,
      );

      final clientTimingMs =
          DateTime.now().difference(startTime).inMilliseconds;

      setState(() {
        _benchmarkResults = results;
        _isOperating = false;
      });

      print('Benchmark completed in ${clientTimingMs}ms');
    } catch (e) {
      setState(() {
        _error = Exception('Benchmark failed: $e');
        _isOperating = false;
      });
    }
  }

  void _reset() {
    setState(() {
      _results = {};
      _completedSteps = {};
      _error = null;
      _isOperating = false;
      _benchmarkResults = null;
    });
  }

  String _taskTypeToDisplayName(ProofTaskType type) {
    return switch (type) {
      ProofTaskType.setupPrepare => 'Setup Prepare Keys',
      ProofTaskType.setupShow => 'Setup Show Keys',
      ProofTaskType.generateBlinds => 'Generate Shared Blinds',
      ProofTaskType.provePrepare => 'Prove Prepare',
      ProofTaskType.proveShow => 'Prove Show',
      ProofTaskType.reblindPrepare => 'Reblind Prepare',
      ProofTaskType.reblindShow => 'Reblind Show',
      ProofTaskType.verifyPrepare => 'Verify Prepare',
      ProofTaskType.verifyShow => 'Verify Show',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenAC E2E Proof Workflow'),
        actions: [
          if (_results.isNotEmpty && !_isOperating)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _reset,
              tooltip: 'Reset',
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Card(
                color: Colors.red.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.error, color: Colors.red.shade700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error.toString(),
                          style: TextStyle(color: Colors.red.shade900),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _error = null),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 16),

            // Benchmark Section
            Card(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.speed, color: Colors.deepPurple),
                        const SizedBox(width: 8),
                        const Text(
                          'Complete Benchmark',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Run comprehensive benchmark including setup, prove, reblind, and verify for both circuits. Results include timing and artifact sizes.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isOperating ? null : _runBenchmark,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepPurple,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.all(16),
                        ),
                        icon: _isOperating
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white),
                                ),
                              )
                            : const Icon(Icons.speed),
                        label: Text(_isOperating
                            ? 'Running Benchmark...'
                            : 'Run Complete Benchmark'),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            if (_benchmarkResults != null) ...[
              const SizedBox(height: 16),
              _buildBenchmarkResults(),
            ],

            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),

            // Step 1: Key Setup
            _buildSectionHeader('Step 1: Key Setup', Icons.settings),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildOperationButton(
                    taskType: ProofTaskType.setupPrepare,
                    label: 'Setup Prepare',
                    icon: Icons.key,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildOperationButton(
                    taskType: ProofTaskType.setupShow,
                    label: 'Setup Show',
                    icon: Icons.key,
                    color: Colors.blue,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Step 2: Generate Shared Blinds
            _buildSectionHeader(
                'Step 2: Generate Shared Blinds', Icons.shuffle),
            const SizedBox(height: 12),
            _buildOperationButton(
              taskType: ProofTaskType.generateBlinds,
              label: 'Generate Shared Blinds',
              icon: Icons.shuffle,
              color: Colors.orange,
            ),

            const SizedBox(height: 24),

            // Step 3: Prepare (Prove + Reblind)
            _buildSectionHeader('Step 3: Prepare', Icons.assignment),
            const SizedBox(height: 8),
            Text(
              'Prove Prepare + Reblind Prepare',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade600,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildOperationButton(
                    taskType: ProofTaskType.provePrepare,
                    label: 'Prove Prepare',
                    icon: Icons.calculate,
                    color: Colors.green,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildOperationButton(
                    taskType: ProofTaskType.reblindPrepare,
                    label: 'Reblind Prepare',
                    icon: Icons.sync,
                    color: Colors.green,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Step 4: Show (Prove + Reblind)
            _buildSectionHeader('Step 4: Show', Icons.visibility),
            const SizedBox(height: 8),
            Text(
              'Prove Show + Reblind Show',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade600,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildOperationButton(
                    taskType: ProofTaskType.proveShow,
                    label: 'Prove Show',
                    icon: Icons.calculate,
                    color: Colors.deepPurple,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildOperationButton(
                    taskType: ProofTaskType.reblindShow,
                    label: 'Reblind Show',
                    icon: Icons.sync,
                    color: Colors.deepPurple,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Step 5: Verify Proofs
            _buildSectionHeader('Step 5: Verify Proofs', Icons.check_circle),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildOperationButton(
                    taskType: ProofTaskType.verifyPrepare,
                    label: 'Verify Prepare',
                    icon: Icons.check_circle,
                    color: Colors.teal,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildOperationButton(
                    taskType: ProofTaskType.verifyShow,
                    label: 'Verify Show',
                    icon: Icons.check_circle,
                    color: Colors.teal,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),

            // Results Display
            if (_results.isNotEmpty) ...[
              _buildSectionHeader('Results', Icons.assessment),
              const SizedBox(height: 12),
              ..._results.entries
                  .map((entry) => _buildResultCard(entry.key, entry.value)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: Colors.grey.shade700),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.grey.shade800,
          ),
        ),
      ],
    );
  }

  Widget _buildOperationButton({
    required ProofTaskType taskType,
    required String label,
    required IconData icon,
    required MaterialColor color,
  }) {
    final isCompleted = _completedSteps[taskType.name] == true;
    final result = _results[taskType.name];

    return ElevatedButton.icon(
      onPressed: _isOperating ? null : () => _runOperation(taskType),
      style: ElevatedButton.styleFrom(
        backgroundColor: isCompleted ? color.shade100 : color,
        foregroundColor: isCompleted ? color.shade900 : Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      ),
      icon:
          isCompleted ? Icon(Icons.check_circle, color: color.shade700) : Icon(icon),
      label: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (result?.totalMs != null)
            Text(
              '${result!.totalMs}ms',
              style: TextStyle(
                fontSize: 11,
                color: isCompleted ? color.shade700 : Colors.white70,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildResultCard(String taskName, TaskResult result) {
    final taskType =
        ProofTaskType.values.firstWhere((e) => e.name == taskName);
    final displayName = _taskTypeToDisplayName(taskType);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  result.success ? Icons.check_circle : Icons.error,
                  color: result.success ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    displayName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Error message
            if (result.error != null) ...[
              Text(
                'Error: ${result.error}',
                style: TextStyle(color: Colors.red.shade700),
              ),
              const SizedBox(height: 8),
            ],

            // Success message
            if (result.message != null) ...[
              Text(result.message!),
              const SizedBox(height: 8),
            ],

            // Timings
            if (result.totalMs != null) ...[
              const Text(
                'Timing:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text('• Total: ${result.totalMs}ms'),
              const SizedBox(height: 8),
            ],

            // Proof size
            if (result.proofSizeBytes != null) ...[
              Text(
                'Proof Size: ${(result.proofSizeBytes!.toInt() / 1024).toStringAsFixed(2)} KB',
                style: TextStyle(color: Colors.grey.shade700),
              ),
              const SizedBox(height: 8),
            ],

            // Shared commitment
            if (result.commWShared != null) ...[
              const Text(
                'Shared Commitment:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SelectableText(
                  result.commWShared!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.grey.shade800,
                  ),
                ),
              ),
            ],

            // Verification result
            if (result.verifyResult != null) ...[
              const SizedBox(height: 8),
              Text(
                result.verifyResult! ? 'Verification passed ✓' : 'Verification failed ✗',
                style: TextStyle(
                  color: result.verifyResult!
                      ? Colors.green.shade700
                      : Colors.red.shade700,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBenchmarkResults() {
    if (_benchmarkResults == null) return const SizedBox.shrink();

    final results = _benchmarkResults!;

    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.assessment, color: Colors.deepPurple),
                    SizedBox(width: 8),
                    Text(
                      'Benchmark Results',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    setState(() {
                      _benchmarkResults = null;
                    });
                  },
                  tooltip: 'Clear results',
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Timing Metrics Section
            const Text(
              'Timing Metrics',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.deepPurple,
              ),
            ),
            const SizedBox(height: 8),
            Table(
              border: TableBorder.all(color: Colors.grey.shade300),
              columnWidths: const {
                0: FlexColumnWidth(2),
                1: FlexColumnWidth(1),
              },
              children: [
                _buildTableHeader(['Operation', 'Time (ms)']),
                _buildTimingRow('Prepare Setup', results.prepareSetupMs),
                _buildTimingRow('Show Setup', results.showSetupMs),
                _buildTimingRow('Generate Blinds', results.generateBlindsMs),
                _buildTimingRow('Prove Prepare', results.provePrepareMs),
                _buildTimingRow('Reblind Prepare', results.reblindPrepareMs),
                _buildTimingRow('Prove Show', results.proveShowMs),
                _buildTimingRow('Reblind Show', results.reblindShowMs),
                _buildTimingRow('Verify Prepare', results.verifyPrepareMs),
                _buildTimingRow('Verify Show', results.verifyShowMs),
              ],
            ),

            const SizedBox(height: 24),

            // Size Metrics Section
            const Text(
              'Artifact Sizes',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.deepPurple,
              ),
            ),
            const SizedBox(height: 8),
            Table(
              border: TableBorder.all(color: Colors.grey.shade300),
              columnWidths: const {
                0: FlexColumnWidth(2),
                1: FlexColumnWidth(1),
              },
              children: [
                _buildTableHeader(['Artifact', 'Size']),
                _buildSizeRow(
                    'Prepare Proving Key', results.prepareProvingKeyBytes),
                _buildSizeRow('Prepare Verifying Key',
                    results.prepareVerifyingKeyBytes),
                _buildSizeRow('Show Proving Key', results.showProvingKeyBytes),
                _buildSizeRow(
                    'Show Verifying Key', results.showVerifyingKeyBytes),
                _buildSizeRow('Prepare Proof', results.prepareProofBytes),
                _buildSizeRow('Show Proof', results.showProofBytes),
                _buildSizeRow('Prepare Witness', results.prepareWitnessBytes),
                _buildSizeRow('Show Witness', results.showWitnessBytes),
              ],
            ),
          ],
        ),
      ),
    );
  }

  TableRow _buildTableHeader(List<String> headers) {
    return TableRow(
      decoration: BoxDecoration(color: Colors.grey.shade200),
      children: headers
          .map((header) => Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  header,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ))
          .toList(),
    );
  }

  TableRow _buildTimingRow(String operation, BigInt milliseconds) {
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(operation),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            milliseconds.toString(),
            style: const TextStyle(fontFamily: 'monospace'),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  TableRow _buildSizeRow(String artifact, BigInt bytes) {
    String formattedSize;
    final bytesInt = bytes.toInt();
    if (bytesInt < 1024) {
      formattedSize = '$bytesInt B';
    } else if (bytesInt < 1024 * 1024) {
      formattedSize = '${(bytesInt / 1024).toStringAsFixed(2)} KB';
    } else {
      formattedSize = '${(bytesInt / (1024 * 1024)).toStringAsFixed(2)} MB';
    }

    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(artifact),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            formattedSize,
            style: const TextStyle(fontFamily: 'monospace'),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}
