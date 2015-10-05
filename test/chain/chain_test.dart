// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:stack_trace/stack_trace.dart';
import 'package:test/test.dart';

import 'utils.dart';

void main() {
  group('Chain.parse()', () {
    test('parses a real Chain', () {
      return captureFuture(() => inMicrotask(() => throw 'error'))
          .then((chain) {
        expect(new Chain.parse(chain.toString()).toString(),
            equals(chain.toString()));
      });
    });

    test('parses an empty string', () {
      var chain = new Chain.parse('');
      expect(chain.traces, isEmpty);
    });

    test('parses a chain containing empty traces', () {
      var chain =
          new Chain.parse('===== asynchronous gap ===========================\n'
              '===== asynchronous gap ===========================\n');
      expect(chain.traces, hasLength(3));
      expect(chain.traces[0].frames, isEmpty);
      expect(chain.traces[1].frames, isEmpty);
      expect(chain.traces[2].frames, isEmpty);
    });
  });

  test("toString() ensures that all traces are aligned", () {
    var chain = new Chain([
      new Trace.parse('short 10:11  Foo.bar\n'),
      new Trace.parse('loooooooooooong 10:11  Zop.zoop')
    ]);

    expect(
        chain.toString(),
        equals('short 10:11            Foo.bar\n'
            '===== asynchronous gap ===========================\n'
            'loooooooooooong 10:11  Zop.zoop\n'));
  });

  var userSlashCode = p.join('user', 'code.dart');
  group('Chain.terse', () {
    test('makes each trace terse', () {
      var chain = new Chain([
        new Trace.parse('dart:core 10:11       Foo.bar\n'
            'dart:core 10:11       Bar.baz\n'
            'user/code.dart 10:11  Bang.qux\n'
            'dart:core 10:11       Zip.zap\n'
            'dart:core 10:11       Zop.zoop'),
        new Trace.parse('user/code.dart 10:11                        Bang.qux\n'
            'dart:core 10:11                             Foo.bar\n'
            'package:stack_trace/stack_trace.dart 10:11  Bar.baz\n'
            'dart:core 10:11                             Zip.zap\n'
            'user/code.dart 10:11                        Zop.zoop')
      ]);

      expect(
          chain.terse.toString(),
          equals('dart:core             Bar.baz\n'
              '$userSlashCode 10:11  Bang.qux\n'
              '===== asynchronous gap ===========================\n'
              '$userSlashCode 10:11  Bang.qux\n'
              'dart:core             Zip.zap\n'
              '$userSlashCode 10:11  Zop.zoop\n'));
    });

    test('eliminates internal-only traces', () {
      var chain = new Chain([
        new Trace.parse('user/code.dart 10:11  Foo.bar\n'
            'dart:core 10:11       Bar.baz'),
        new Trace.parse('dart:core 10:11                             Foo.bar\n'
            'package:stack_trace/stack_trace.dart 10:11  Bar.baz\n'
            'dart:core 10:11                             Zip.zap'),
        new Trace.parse('user/code.dart 10:11  Foo.bar\n'
            'dart:core 10:11       Bar.baz')
      ]);

      expect(
          chain.terse.toString(),
          equals('$userSlashCode 10:11  Foo.bar\n'
              '===== asynchronous gap ===========================\n'
              '$userSlashCode 10:11  Foo.bar\n'));
    });

    test("doesn't return an empty chain", () {
      var chain = new Chain([
        new Trace.parse('dart:core 10:11                             Foo.bar\n'
            'package:stack_trace/stack_trace.dart 10:11  Bar.baz\n'
            'dart:core 10:11                             Zip.zap'),
        new Trace.parse('dart:core 10:11                             A.b\n'
            'package:stack_trace/stack_trace.dart 10:11  C.d\n'
            'dart:core 10:11                             E.f')
      ]);

      expect(chain.terse.toString(), equals('dart:core  E.f\n'));
    });
  });

  group('Chain.foldFrames', () {
    test('folds each trace', () {
      var chain = new Chain([
        new Trace.parse('a.dart 10:11  Foo.bar\n'
            'a.dart 10:11  Bar.baz\n'
            'b.dart 10:11  Bang.qux\n'
            'a.dart 10:11  Zip.zap\n'
            'a.dart 10:11  Zop.zoop'),
        new Trace.parse('a.dart 10:11  Foo.bar\n'
            'a.dart 10:11  Bar.baz\n'
            'a.dart 10:11  Bang.qux\n'
            'a.dart 10:11  Zip.zap\n'
            'b.dart 10:11  Zop.zoop')
      ]);

      var folded = chain.foldFrames((frame) => frame.library == 'a.dart');
      expect(
          folded.toString(),
          equals('a.dart 10:11  Bar.baz\n'
              'b.dart 10:11  Bang.qux\n'
              'a.dart 10:11  Zop.zoop\n'
              '===== asynchronous gap ===========================\n'
              'a.dart 10:11  Zip.zap\n'
              'b.dart 10:11  Zop.zoop\n'));
    });

    test('with terse: true, folds core frames as well', () {
      var chain = new Chain([
        new Trace.parse('a.dart 10:11                        Foo.bar\n'
            'dart:async-patch/future.dart 10:11  Zip.zap\n'
            'b.dart 10:11                        Bang.qux\n'
            'dart:core 10:11                     Bar.baz\n'
            'a.dart 10:11                        Zop.zoop'),
        new Trace.parse('a.dart 10:11  Foo.bar\n'
            'a.dart 10:11  Bar.baz\n'
            'a.dart 10:11  Bang.qux\n'
            'a.dart 10:11  Zip.zap\n'
            'b.dart 10:11  Zop.zoop')
      ]);

      var folded =
          chain.foldFrames((frame) => frame.library == 'a.dart', terse: true);
      expect(
          folded.toString(),
          equals('dart:async    Zip.zap\n'
              'b.dart 10:11  Bang.qux\n'
              'a.dart        Zop.zoop\n'
              '===== asynchronous gap ===========================\n'
              'a.dart        Zip.zap\n'
              'b.dart 10:11  Zop.zoop\n'));
    });

    test('eliminates completely-folded traces', () {
      var chain = new Chain([
        new Trace.parse('a.dart 10:11  Foo.bar\n'
            'b.dart 10:11  Bang.qux'),
        new Trace.parse('a.dart 10:11  Foo.bar\n'
            'a.dart 10:11  Bang.qux'),
        new Trace.parse('a.dart 10:11  Zip.zap\n'
            'b.dart 10:11  Zop.zoop')
      ]);

      var folded = chain.foldFrames((frame) => frame.library == 'a.dart');
      expect(
          folded.toString(),
          equals('a.dart 10:11  Foo.bar\n'
              'b.dart 10:11  Bang.qux\n'
              '===== asynchronous gap ===========================\n'
              'a.dart 10:11  Zip.zap\n'
              'b.dart 10:11  Zop.zoop\n'));
    });

    test("doesn't return an empty trace", () {
      var chain = new Chain([
        new Trace.parse('a.dart 10:11  Foo.bar\n'
            'a.dart 10:11  Bang.qux')
      ]);

      var folded = chain.foldFrames((frame) => frame.library == 'a.dart');
      expect(folded.toString(), equals('a.dart 10:11  Bang.qux\n'));
    });
  });

  test('Chain.toTrace eliminates asynchronous gaps', () {
    var trace = new Chain([
      new Trace.parse('user/code.dart 10:11  Foo.bar\n'
          'dart:core 10:11       Bar.baz'),
      new Trace.parse('user/code.dart 10:11  Foo.bar\n'
          'dart:core 10:11       Bar.baz')
    ]).toTrace();

    expect(
        trace.toString(),
        equals('$userSlashCode 10:11  Foo.bar\n'
            'dart:core 10:11       Bar.baz\n'
            '$userSlashCode 10:11  Foo.bar\n'
            'dart:core 10:11       Bar.baz\n'));
  });

  group('Chain.track(Future)', () {
    test('forwards the future value within Chain.capture()', () {
      Chain.capture(() {
        expect(Chain.track(new Future.value('value')),
            completion(equals('value')));

        var trace = new Trace.current();
        expect(
            Chain
                .track(new Future.error('error', trace))
                .catchError((e, stackTrace) {
              expect(e, equals('error'));
              expect(stackTrace.toString(), equals(trace.toString()));
            }),
            completes);
      });
    });

    test('forwards the future value outside of Chain.capture()', () {
      expect(
          Chain.track(new Future.value('value')), completion(equals('value')));

      var trace = new Trace.current();
      expect(
          Chain
              .track(new Future.error('error', trace))
              .catchError((e, stackTrace) {
            expect(e, equals('error'));
            expect(stackTrace.toString(), equals(trace.toString()));
          }),
          completes);
    });
  });

  group('Chain.track(Stream)', () {
    test('forwards stream values within Chain.capture()', () {
      Chain.capture(() {
        var controller = new StreamController()
          ..add(1)
          ..add(2)
          ..add(3)
          ..close();
        expect(Chain.track(controller.stream).toList(),
            completion(equals([1, 2, 3])));

        var trace = new Trace.current();
        controller = new StreamController()..addError('error', trace);
        expect(
            Chain.track(controller.stream).toList().catchError((e, stackTrace) {
              expect(e, equals('error'));
              expect(stackTrace.toString(), equals(trace.toString()));
            }),
            completes);
      });
    });

    test('forwards stream values outside of Chain.capture()', () {
      Chain.capture(() {
        var controller = new StreamController()
          ..add(1)
          ..add(2)
          ..add(3)
          ..close();
        expect(Chain.track(controller.stream).toList(),
            completion(equals([1, 2, 3])));

        var trace = new Trace.current();
        controller = new StreamController()..addError('error', trace);
        expect(
            Chain.track(controller.stream).toList().catchError((e, stackTrace) {
              expect(e, equals('error'));
              expect(stackTrace.toString(), equals(trace.toString()));
            }),
            completes);
      });
    });
  });

  group('Chain.foldAsyncStacks(exact: false)', () {
    test('eliminates async stacks in same function', () {
      var chain = new Chain([
        new Trace.parse('test/exp.dart 10:21    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           _Future.then\n'
            'test/exp.dart 8:5    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           _Future.then\n'
            'test/exp.dart 7:5    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           _Future.then\n'
            'test/exp.dart 6:5    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           Future.Future.microtask\n'
            'test/exp.dart        main.<fn>\n'
            'package:stack_trace  Chain.capture\n'
            'test/exp.dart 5:9    main\n')
      ]).foldAsyncStacks(exact: false);
      expect(chain.traces, hasLength(2));
      expect(chain.traces[0].frames[0].line, 10);
    });

    test('keeps async stacks from different methods', () {
      var chain = new Chain([
        new Trace.parse('test/exp.dart 10:21    main.<fn>.<fn>.<async>\n'),
        new Trace.parse('dart:async           _Future.then\n'
            'test/exp.dart 8:5    main.<fn>.<fn>.<async>\n'),
        new Trace.parse('dart:async           _Future.then\n'
            'test/exp.dart 7:5    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           _Future.then\n'
            'test/exp.dart 6:5    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           Future.Future.microtask\n'
            'test/exp.dart        main.<fn>\n'
            'package:stack_trace  Chain.capture\n'
            'test/exp.dart 5:9    main\n')
      ]).foldAsyncStacks(exact: false);
      expect(chain.traces, hasLength(3));
      expect(chain.traces[0].frames[0].line, 10);
      expect(chain.traces[1].frames[1].line, 7);
    });
  });

  group('Chain.foldAsyncStacks(exact: true)', () {
    test('eliminates async stacks at same line', () {
      var chain = new Chain([
        new Trace.parse('test/exp.dart 10:21    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           _Future.then\n'
            'test/exp.dart 6:5    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           _Future.then\n'
            'test/exp.dart 6:5    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           _Future.then\n'
            'test/exp.dart 6:5    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           Future.Future.microtask\n'
            'test/exp.dart        main.<fn>\n'
            'package:stack_trace  Chain.capture\n'
            'test/exp.dart 5:9    main\n')
      ]).foldAsyncStacks(exact: true);
      expect(chain.traces, hasLength(3));
      expect(chain.traces[0].frames[0].line, 10);
      expect(chain.traces[1].frames[1].line, 6);
    });

    test('keeps async stacks from different lines', () {
      var chain = new Chain([
        new Trace.parse('test/exp.dart 10:21    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           _Future.then\n'
            'test/exp.dart 8:5    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           _Future.then\n'
            'test/exp.dart 7:5    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           _Future.then\n'
            'test/exp.dart 6:5    main.<fn>.<async>\n'),
        new Trace.parse('dart:async           Future.Future.microtask\n'
            'test/exp.dart        main.<fn>\n'
            'package:stack_trace  Chain.capture\n'
            'test/exp.dart 5:9    main\n')
      ]).foldAsyncStacks(exact: true);
      expect(chain.traces, hasLength(5));
      expect(chain.traces[0].frames[0].line, 10);
      expect(chain.traces[1].frames[1].line, 8);
      expect(chain.traces[2].frames[1].line, 7);
    });
  });
}
