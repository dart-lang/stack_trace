import 'dart:async';

import 'package:stack_trace/stack_trace.dart';

void main() {
  Chain.capture(_scheduleAsync);
}

void _scheduleAsync() {
  Future<void>.delayed(const Duration(seconds: 1)).then((_) => _runAsync());
}

void _runAsync() {
  throw StateError('oh no!');
}
