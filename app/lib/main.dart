import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:io';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Production System',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        fontFamily: 'Inter',
      ),
      home: const ConnectionManager(),
    );
  }
}

/// Manages the initial synchronization between Frontend and Backend
class ConnectionManager extends StatefulWidget {
  const ConnectionManager({super.key});

  @override
  State<ConnectionManager> createState() => _ConnectionManagerState();
}

class _ConnectionManagerState extends State<ConnectionManager> {
  bool _isConnected = false;
  bool _hasError = false;
  int _retryCount = 0;
  final int _maxRetries = 15;
  String _port = "8383";

  @override
  void initState() {
    super.initState();
    _parseArguments();
    _startConnectionSequence();
  }

  void _parseArguments() {
    // Basic argument parsing for --port=XXXX
    for (var arg in Platform.executableArguments) {
      if (arg.startsWith('--port=')) {
        _port = arg.split('=')[1];
      }
    }
  }

  Future<void> _startConnectionSequence() async {
    final url = 'http://localhost:$_port/health';
    while (_retryCount < _maxRetries && !_isConnected) {
      try {
        final response = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 1));
        if (response.statusCode == 200) {
          if (mounted) {
            setState(() {
              _isConnected = true;
              _hasError = false;
            });
          }
          return;
        }
      } catch (_) {
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) {
          setState(() => _retryCount++);
        }
      }
    }

    if (!_isConnected && mounted) {
      setState(() => _hasError = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: _hasError
          ? _buildErrorScreen()
          : !_isConnected
              ? _buildLoadingScreen()
              : MyHomePage(port: _port),
    );
  }

  Widget _buildLoadingScreen() {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 40),
            const Text(
                'Initializing Service Layer',
                style: TextStyle(fontSize: 20, letterSpacing: 1.2, fontWeight: FontWeight.w300)
            ),
            const SizedBox(height: 12),
            Text(
              _retryCount > 3 ? 'Establishing stable connection...' : 'Synchronizing...',
              style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorScreen() {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(40.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cloud_off_rounded, size: 80, color: Colors.red.shade300),
              const SizedBox(height: 24),
              const Text(
                'Service Unavailable',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                'The backend orchestration layer failed to respond. Please ensure the launcher has sufficient permissions.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, height: 1.5),
              ),
              const SizedBox(height: 48),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _hasError = false;
                    _retryCount = 0;
                  });
                  _startConnectionSequence();
                },
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry Connection'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  final String port;
  const MyHomePage({super.key, required this.port});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String _message = "System Online";
  String _timestamp = "";
  int _randomValue = 0;
  bool _isLoading = false;

  Future<void> _fetchInfo() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('http://localhost:${widget.port}/info'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _message = data['message'];
          _timestamp = data['timestamp'];
          _randomValue = data['random_value'];
        });
      }
    } catch (e) {
      setState(() => _message = "Link Severed");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Service Dashboard', style: TextStyle(fontWeight: FontWeight.w600)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.5),
            radius: 1.5,
            colors: [
              Colors.indigo.withOpacity(0.1),
              Theme.of(context).colorScheme.surface,
            ],
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                _buildDataContainer(),
                const SizedBox(height: 60),
                FilledButton.tonalIcon(
                  onPressed: _isLoading ? null : _fetchInfo,
                  icon: _isLoading 
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) 
                      : const Icon(Icons.bolt_rounded),
                  label: Text(_isLoading ? 'Requesting...' : 'Sync Data'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDataContainer() {
    return Container(
      constraints: const BoxConstraints(maxWidth: 400),
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        children: [
          Text(
            _message,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 0.5),
            textAlign: TextAlign.center,
          ),
          if (_timestamp.isNotEmpty) ...[
            const SizedBox(height: 32),
            _infoRow('Metric Variation', '$_randomValue', Colors.indigoAccent),
            const SizedBox(height: 16),
            _infoRow('Last Pulse', _timestamp.substring(11, 19), Colors.tealAccent),
          ] else ...[
            const SizedBox(height: 20),
            Text(
              'Awaiting first manual synchronization request',
              style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ]
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 14)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            value,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color, fontFamily: 'Monospace'),
          ),
        ),
      ],
    );
  }
}
