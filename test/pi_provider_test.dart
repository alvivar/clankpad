import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clankpad/services/ai_provider.dart';
import 'package:clankpad/services/pi_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new_session rejection cleans up and allows a fresh request', () async {
    final failed = _FakeProcess(rejectSession: true);
    await _expectFailureAndRetry(failed, 'Session rejected');
    expect(failed.input.commands, ['set_thinking_level', 'new_session']);
  });

  test(
    'setup timeout cleans up a still-live process and allows retry',
    () async {
      final failed = _FakeProcess(ignoreSession: true);
      await _expectFailureAndRetry(
        failed,
        'Command timed out: new_session',
        deadline: const Duration(seconds: 7),
      );
      expect(failed.input.commands, ['set_thinking_level', 'new_session']);
    },
  );

  test('setup stdin write failure cleans up and allows retry', () async {
    final failed = _FakeProcess(writeFailureAt: 'set_thinking_level');
    await _expectFailureAndRetry(failed, 'Could not write to Pi:');
  });

  test('prompt stdin write failure before listening allows retry', () async {
    final failed = _FakeProcess(writeFailureAt: 'prompt');
    await _expectFailureAndRetry(failed, 'Could not write to Pi:');
    expect(failed.input.commands, [
      'set_thinking_level',
      'new_session',
      'prompt',
    ]);
  });

  test('prompt stdin flush failure before listening allows retry', () async {
    final failed = _FakeProcess(flushFailureAt: 'prompt');
    await _expectFailureAndRetry(failed, 'Could not write to Pi:');
  });

  test('process exit is observed even while setup flush is pending', () async {
    final failed = _FakeProcess(exitDuringSetupFlush: true);
    await _expectFailureAndRetry(failed, 'Pi process exited unexpectedly.');
  });

  test('abort during setup prevents prompt and keeps Pi warm', () async {
    final process = _FakeProcess(deferResponseFor: 'set_thinking_level');
    var starts = 0;
    final provider = PiProvider(
      startProcess: (executable, arguments, {required runInShell}) async {
        starts++;
        return process;
      },
    );
    addTearDown(provider.dispose);

    final cancelled = _request(provider);
    await process.deferredCommand.future.timeout(const Duration(seconds: 1));
    provider.abort();
    process.respondToDeferred();

    expect(await cancelled.timeout(const Duration(seconds: 1)), isEmpty);
    expect(process.input.commands, ['set_thinking_level']);
    expect(process.killed, isFalse);
    expect(await _request(provider).timeout(const Duration(seconds: 1)), [
      'replacement',
    ]);
    expect(starts, 1);
    expect(process.input.commands, [
      'set_thinking_level',
      'set_thinking_level',
      'new_session',
      'prompt',
    ]);
  });

  test('abort during prompt flush is sent after transmission', () async {
    final process = _FakeProcess(holdPromptFlush: true);
    var starts = 0;
    final provider = PiProvider(
      startProcess: (executable, arguments, {required runInShell}) async {
        starts++;
        return process;
      },
    );
    addTearDown(provider.dispose);

    final cancelled = _request(provider);
    await process.promptWritten.future.timeout(const Duration(seconds: 1));
    provider.abort();
    expect(process.input.commands.last, 'prompt');

    process.releaseFlush();
    expect(await cancelled.timeout(const Duration(seconds: 1)), isEmpty);
    expect(process.input.commands.sublist(2), ['prompt', 'abort']);
    expect(process.killed, isFalse);
    expect(await _request(provider).timeout(const Duration(seconds: 1)), [
      'replacement',
    ]);
    expect(starts, 1);
  });

  test('dispose does not await an unlistened prompt controller', () async {
    final failed = _FakeProcess(holdPromptFlush: true);
    final retry = _FakeProcess();
    final processes = [failed, retry];
    final provider = PiProvider(
      startProcess: (executable, arguments, {required runInShell}) async {
        return processes.removeAt(0);
      },
    );
    addTearDown(provider.dispose);

    final result = _request(provider);
    final error = expectLater(result, throwsA(isA<AiProviderError>()));
    await failed.promptWritten.future.timeout(const Duration(seconds: 1));
    await provider.dispose().timeout(const Duration(seconds: 1));
    await error.timeout(const Duration(seconds: 1));
    _expectReleased(failed);
    expect(await _request(provider), ['replacement']);
  });
}

Future<List<String>> _request(PiProvider provider) => provider
    .streamEdit(
      documentText: 'original',
      editTarget: 'original',
      userInstruction: 'replace',
    )
    .toList();

Future<void> _expectFailureAndRetry(
  _FakeProcess failed,
  String message, {
  Duration deadline = const Duration(seconds: 1),
}) async {
  final retry = _FakeProcess();
  final processes = [failed, retry];
  var starts = 0;
  final provider = PiProvider(
    startProcess: (executable, arguments, {required runInShell}) async {
      starts++;
      return processes.removeAt(0);
    },
  );
  addTearDown(provider.dispose);

  await expectLater(
    _request(provider).timeout(deadline),
    throwsA(
      isA<AiProviderError>().having(
        (error) => error.message,
        'message',
        contains(message),
      ),
    ),
  );
  _expectReleased(failed);
  expect(await _request(provider).timeout(const Duration(seconds: 1)), [
    'replacement',
  ]);
  expect(starts, 2);
  expect(retry.killed, isFalse); // Successful requests retain the warm process.
}

void _expectReleased(_FakeProcess process) {
  expect(process.killed, isTrue);
  expect(process.input.closed, isTrue);
  expect(process.output.hasListener, isFalse);
}

// Only the Process/IOSink operations the provider actually uses are implemented.
// JSONL routing, command waits and stream cleanup remain production code; no
// executable, network, credentials or external Pi installation is involved.
class _FakeProcess implements Process {
  _FakeProcess({
    this.rejectSession = false,
    this.ignoreSession = false,
    String? writeFailureAt,
    String? flushFailureAt,
    this.exitDuringSetupFlush = false,
    this.holdPromptFlush = false,
    this.deferResponseFor,
  }) {
    input = _FakeInput(
      onCommand: _handleCommand,
      writeFailureAt: writeFailureAt,
      flushFailureAt: flushFailureAt,
      heldFlush: exitDuringSetupFlush || holdPromptFlush ? _flushGate : null,
      holdAt: exitDuringSetupFlush ? 'set_thinking_level' : 'prompt',
    );
  }

  final bool rejectSession;
  final bool ignoreSession;
  final bool exitDuringSetupFlush;
  bool holdPromptFlush;
  String? deferResponseFor;
  Map<String, dynamic>? _deferred;
  final deferredCommand = Completer<void>();
  final output = StreamController<List<int>>();
  final promptWritten = Completer<void>();
  final _flushGate = Completer<void>();
  final _exit = Completer<int>();
  late final _FakeInput input;
  bool killed = false;

  @override
  IOSink get stdin => input;

  @override
  Stream<List<int>> get stdout => output.stream;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Future<int> get exitCode => _exit.future;

  void _emit(Map<String, dynamic> event) {
    output.add(utf8.encode('${jsonEncode(event)}\n'));
  }

  void releaseFlush() => _flushGate.complete();

  void respondToDeferred() {
    _respond(_deferred!);
    _deferred = null;
  }

  void _handleCommand(Map<String, dynamic> command) {
    final type = command['type'];
    if (type == deferResponseFor) {
      deferResponseFor = null;
      _deferred = command;
      deferredCommand.complete();
      return;
    }
    if (exitDuringSetupFlush && type == 'set_thinking_level') {
      unawaited(output.close());
      return;
    }
    if (type == 'new_session' && ignoreSession) return;
    if (type == 'abort') {
      _emit({
        'type': 'agent_end',
        'messages': [
          {'role': 'assistant', 'stopReason': 'aborted'},
        ],
      });
      return;
    }
    if (type == 'prompt') {
      if (!promptWritten.isCompleted) promptWritten.complete();
      if (holdPromptFlush) {
        holdPromptFlush = false;
        return;
      }
      _emit({
        'type': 'message_update',
        'assistantMessageEvent': {'type': 'text_delta', 'delta': 'replacement'},
      });
      _emit({
        'type': 'agent_end',
        'messages': [
          {'role': 'assistant', 'stopReason': 'stop'},
        ],
      });
      return;
    }
    _respond(command);
  }

  void _respond(Map<String, dynamic> command) {
    final type = command['type'];
    _emit({
      'type': 'response',
      'id': command['id'],
      'command': type,
      'success': !(type == 'new_session' && rejectSession),
      if (type == 'new_session' && rejectSession) 'error': 'Session rejected',
    });
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(0);
    unawaited(output.close());
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeInput implements IOSink {
  _FakeInput({
    required this.onCommand,
    this.writeFailureAt,
    this.flushFailureAt,
    this.heldFlush,
    required this.holdAt,
  });

  final void Function(Map<String, dynamic>) onCommand;
  final String? writeFailureAt;
  final String? flushFailureAt;
  final Completer<void>? heldFlush;
  final String holdAt;
  final commands = <String>[];
  bool closed = false;
  bool _flushPending = false;

  @override
  void writeln([Object? object = '']) {
    // Match IOSink: writes are rejected while a flush is pending.
    if (_flushPending) throw StateError('StreamSink is bound to a stream');
    final command = jsonDecode(object as String) as Map<String, dynamic>;
    final type = command['type'] as String;
    commands.add(type);
    if (type == writeFailureAt) throw StateError('stdin closed');
    onCommand(command);
  }

  @override
  Future<void> flush() async {
    if (commands.last == flushFailureAt) {
      throw const SocketException('stdin broken pipe');
    }
    if (commands.last == holdAt && heldFlush != null) {
      _flushPending = true;
      try {
        await heldFlush!.future;
      } finally {
        _flushPending = false;
      }
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    if (heldFlush != null && !heldFlush!.isCompleted) heldFlush!.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
