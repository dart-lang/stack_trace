// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:path/path.dart' as path;

import 'trace.dart';
import 'unparsed_frame.dart';

// #1      Foo._bar (file:///home/nweiz/code/stuff.dart:42:21)
// #1      Foo._bar (file:///home/nweiz/code/stuff.dart:42)
// #1      Foo._bar (file:///home/nweiz/code/stuff.dart)
final _vmFrame = RegExp(r'^#\d+\s+(\S.*) \((.+?)((?::\d+){0,2})\)$');

//     at Object.stringify (native)
//     at VW.call$0 (https://example.com/stuff.dart.js:560:28)
//     at VW.call$0 (eval as fn
//         (https://example.com/stuff.dart.js:560:28), efn:3:28)
//     at https://example.com/stuff.dart.js:560:28
final _v8JsFrame =
    RegExp(r'^\s*at (?:(\S.*?)(?: \[as [^\]]+\])? \((.*)\)|(.*))$');

// https://example.com/stuff.dart.js:560:28
// https://example.com/stuff.dart.js:560
//
// Group 1: URI, required
// Group 2: line number, required
// Group 3: column number, optional
final _v8JsUrlLocation = RegExp(r'^(.*?):(\d+)(?::(\d+))?$|native$');

// With names:
//
//     at Error.f (wasm://wasm/0006d966:wasm-function[119]:0xbb13)
//     at g (wasm://wasm/0006d966:wasm-function[796]:0x143b4)
//
// Without names:
//
//     at wasm://wasm/0005168a:wasm-function[119]:0xbb13
//     at wasm://wasm/0005168a:wasm-function[796]:0x143b4
//
// Matches named groups:
//
// - "member": optional, `Error.f` in the first example, NA in the second.
// - "uri":  `wasm://wasm/0006d966`.
// - "index": `119`.
// - "offset": (hex number) `bb13`.
//
// To avoid having multiple groups for the same part of the frame, this regex
// matches unmatched parentheses after the member name.
final _v8WasmFrame = RegExp(r'^\s*at (?:(?<member>.+) )?'
    r'(?:\(?(?:(?<uri>\S+):wasm-function\[(?<index>\d+)\]'
    r'\:0x(?<offset>[0-9a-fA-F]+))\)?)$');

// eval as function (https://example.com/stuff.dart.js:560:28), efn:3:28
// eval as function (https://example.com/stuff.dart.js:560:28)
// eval as function (eval as otherFunction
//     (https://example.com/stuff.dart.js:560:28))
final _v8EvalLocation =
    RegExp(r'^eval at (?:\S.*?) \((.*)\)(?:, .*?:\d+:\d+)?$');

// anonymous/<@https://example.com/stuff.js line 693 > Function:3:40
// anonymous/<@https://example.com/stuff.js line 693 > eval:3:40
final _firefoxEvalLocation =
    RegExp(r'(\S+)@(\S+) line (\d+) >.* (Function|eval):\d+:\d+');

// .VW.call$0@https://example.com/stuff.dart.js:560
// .VW.call$0("arg")@https://example.com/stuff.dart.js:560
// .VW.call$0/name<@https://example.com/stuff.dart.js:560
// .VW.call$0@https://example.com/stuff.dart.js:560:36
// https://example.com/stuff.dart.js:560
final _firefoxSafariJSFrame = RegExp(r'^'
    r'(?:' // Member description. Not present in some Safari frames.
    r'([^@(/]*)' // The actual name of the member.
    r'(?:\(.*\))?' // Arguments to the member, sometimes captured by Firefox.
    r'((?:/[^/]*)*)' // Extra characters indicating a nested closure.
    r'(?:\(.*\))?' // Arguments to the closure.
    r'@'
    r')?'
    r'(.*?)' // The frame's URL.
    r':'
    r'(\d*)' // The line number. Empty in Safari if it's unknown.
    r'(?::(\d*))?' // The column number. Not present in older browsers and
    // empty in Safari if it's unknown.
    r'$');

// With names:
//
// g@http://localhost:8080/test.wasm:wasm-function[796]:0x143b4
// f@http://localhost:8080/test.wasm:wasm-function[795]:0x143a8
// main@http://localhost:8080/test.wasm:wasm-function[792]:0x14390
//
// Without names:
//
// @http://localhost:8080/test.wasm:wasm-function[796]:0x143b4
// @http://localhost:8080/test.wasm:wasm-function[795]:0x143a8
// @http://localhost:8080/test.wasm:wasm-function[792]:0x14390
//
// JSShell in the command line uses a different format, which this regex also
// parses.
//
// With names:
//
// main@/home/user/test.mjs line 29 > WebAssembly.compile:wasm-function[792]:0x14378
//
// Without names:
//
// @/home/user/test.mjs line 29 > WebAssembly.compile:wasm-function[792]:0x14378
//
// Matches named groups:
//
// - "member": Function name, may be empty: `g`.
// - "uri": `http://localhost:8080/test.wasm`.
// - "index": `796`.
// - "offset": (in hex) `143b4`.
final _firefoxWasmFrame =
    RegExp(r'^(?<member>.*?)@(?:(?<uri>\S+).*?:wasm-function'
        r'\[(?<index>\d+)\]:0x(?<offset>[0-9a-fA-F]+))$');

// With names:
//
// (Note: Lines below are literal text, e.g. <?> is not a placeholder, it's a
// part of the stack frame.)
//
// <?>.wasm-function[g]@[wasm code]
// <?>.wasm-function[f]@[wasm code]
// <?>.wasm-function[main]@[wasm code]
//
// Without names:
//
// <?>.wasm-function[796]@[wasm code]
// <?>.wasm-function[795]@[wasm code]
// <?>.wasm-function[792]@[wasm code]
//
// Matches named group "member": `g` or `796`.
final _safariWasmFrame =
    RegExp(r'^.*?wasm-function\[(?<member>.*)\]@\[wasm code\]$');

// foo/bar.dart 10:11 Foo._bar
// foo/bar.dart 10:11 (anonymous function).dart.fn
// https://dart.dev/foo/bar.dart Foo._bar
// data:... 10:11 Foo._bar
final _friendlyFrame = RegExp(r'^(\S+)(?: (\d+)(?::(\d+))?)?\s+([^\d].*)$');

/// A regular expression that matches asynchronous member names generated by the
/// VM.
final _asyncBody = RegExp(r'<(<anonymous closure>|[^>]+)_async_body>');

final _initialDot = RegExp(r'^\.');

/// A single stack frame. Each frame points to a precise location in Dart code.
class Frame {
  /// The URI of the file in which the code is located.
  ///
  /// This URI will usually have the scheme `dart`, `file`, `http`, or `https`.
  final Uri uri;

  /// The line number on which the code location is located.
  ///
  /// This can be null, indicating that the line number is unknown or
  /// unimportant.
  final int? line;

  /// The column number of the code location.
  ///
  /// This can be null, indicating that the column number is unknown or
  /// unimportant.
  final int? column;

  /// The name of the member in which the code location occurs.
  ///
  /// Anonymous closures are represented as `<fn>` in this member string.
  final String? member;

  /// Whether this stack frame comes from the Dart core libraries.
  bool get isCore => uri.scheme == 'dart';

  /// Returns a human-friendly description of the library that this stack frame
  /// comes from.
  ///
  /// This will usually be the string form of [uri], but a relative URI will be
  /// used if possible. Data URIs will be truncated.
  String get library {
    if (uri.scheme == 'data') return 'data:...';
    return path.prettyUri(uri);
  }

  /// Returns the name of the package this stack frame comes from, or `null` if
  /// this stack frame doesn't come from a `package:` URL.
  String? get package {
    if (uri.scheme != 'package') return null;
    return uri.path.split('/').first;
  }

  /// A human-friendly description of the code location.
  String get location {
    if (line == null) return library;
    if (column == null) return '$library $line';
    return '$library $line:$column';
  }

  /// Returns a single frame of the current stack.
  ///
  /// By default, this will return the frame above the current method. If
  /// [level] is `0`, it will return the current method's frame; if [level] is
  /// higher than `1`, it will return higher frames.
  factory Frame.caller([int level = 1]) {
    if (level < 0) {
      throw ArgumentError('Argument [level] must be greater than or equal '
          'to 0.');
    }

    return Trace.current(level + 1).frames.first;
  }

  /// Parses a string representation of a Dart VM stack frame.
  factory Frame.parseVM(String frame) => _catchFormatException(frame, () {
        // The VM sometimes folds multiple stack frames together and replaces
        // them with "...".
        if (frame == '...') {
          return Frame(Uri(), null, null, '...');
        }

        var match = _vmFrame.firstMatch(frame);
        if (match == null) return UnparsedFrame(frame);

        // Get the pieces out of the regexp match. Function, URI and line should
        // always be found. The column is optional.
        var member = match[1]!
            .replaceAll(_asyncBody, '<async>')
            .replaceAll('<anonymous closure>', '<fn>');
        var uri = match[2]!.startsWith('<data:')
            ? Uri.dataFromString('')
            : Uri.parse(match[2]!);

        var lineAndColumn = match[3]!.split(':');
        var line =
            lineAndColumn.length > 1 ? int.parse(lineAndColumn[1]) : null;
        var column =
            lineAndColumn.length > 2 ? int.parse(lineAndColumn[2]) : null;
        return Frame(uri, line, column, member);
      });

  /// Parses a string representation of a Chrome/V8 stack frame.
  factory Frame.parseV8(String frame) => _catchFormatException(frame, () {
        // Try to match a Wasm frame first: the Wasm frame regex won't match a
        // JS frame but the JS frame regex may match a Wasm frame.
        var match = _v8WasmFrame.firstMatch(frame);
        if (match != null) {
          final member = match.namedGroup('member');
          final uri = _uriOrPathToUri(match.namedGroup('uri')!);
          final functionIndex = match.namedGroup('index')!;
          final functionOffset =
              int.parse(match.namedGroup('offset')!, radix: 16);
          return Frame(uri, 1, functionOffset + 1, member ?? functionIndex);
        }

        match = _v8JsFrame.firstMatch(frame);
        if (match != null) {
          // v8 location strings can be arbitrarily-nested, since it adds a
          // layer of nesting for each eval performed on that line.
          Frame parseJsLocation(String location, String member) {
            var evalMatch = _v8EvalLocation.firstMatch(location);
            while (evalMatch != null) {
              location = evalMatch[1]!;
              evalMatch = _v8EvalLocation.firstMatch(location);
            }

            if (location == 'native') {
              return Frame(Uri.parse('native'), null, null, member);
            }

            var urlMatch = _v8JsUrlLocation.firstMatch(location);
            if (urlMatch == null) return UnparsedFrame(frame);

            final uri = _uriOrPathToUri(urlMatch[1]!);
            final line = int.parse(urlMatch[2]!);
            final columnMatch = urlMatch[3];
            final column = columnMatch != null ? int.parse(columnMatch) : null;
            return Frame(uri, line, column, member);
          }

          // V8 stack frames can be in two forms.
          if (match[2] != null) {
            // The first form looks like " at FUNCTION (LOCATION)". V8 proper
            // lists anonymous functions within eval as "<anonymous>", while
            // IE10 lists them as "Anonymous function".
            return parseJsLocation(
                match[2]!,
                match[1]!
                    .replaceAll('<anonymous>', '<fn>')
                    .replaceAll('Anonymous function', '<fn>')
                    .replaceAll('(anonymous function)', '<fn>'));
          } else {
            // The second form looks like " at LOCATION", and is used for
            // anonymous functions.
            return parseJsLocation(match[3]!, '<fn>');
          }
        }

        return UnparsedFrame(frame);
      });

  /// Parses a string representation of a JavaScriptCore stack trace.
  factory Frame.parseJSCore(String frame) => Frame.parseV8(frame);

  /// Parses a string representation of an IE stack frame.
  ///
  /// IE10+ frames look just like V8 frames. Prior to IE10, stack traces can't
  /// be retrieved.
  factory Frame.parseIE(String frame) => Frame.parseV8(frame);

  /// Parses a Firefox 'eval' or 'function' stack frame.
  ///
  /// For example:
  ///
  /// ```
  /// anonymous/<@https://example.com/stuff.js line 693 > Function:3:40
  /// anonymous/<@https://example.com/stuff.js line 693 > eval:3:40
  /// ```
  factory Frame._parseFirefoxEval(String frame) =>
      _catchFormatException(frame, () {
        final match = _firefoxEvalLocation.firstMatch(frame);
        if (match == null) return UnparsedFrame(frame);
        var member = match[1]!.replaceAll('/<', '');
        final uri = _uriOrPathToUri(match[2]!);
        final line = int.parse(match[3]!);
        if (member.isEmpty || member == 'anonymous') {
          member = '<fn>';
        }
        return Frame(uri, line, null, member);
      });

  /// Parses a string representation of a Firefox or Safari stack frame.
  factory Frame.parseFirefox(String frame) => _catchFormatException(frame, () {
        var match = _firefoxSafariJSFrame.firstMatch(frame);
        if (match != null) {
          if (match[3]!.contains(' line ')) {
            return Frame._parseFirefoxEval(frame);
          }

          // Normally this is a URI, but in a jsshell trace it can be a path.
          var uri = _uriOrPathToUri(match[3]!);

          var member = match[1];
          if (member != null) {
            member +=
                List.filled('/'.allMatches(match[2]!).length, '.<fn>').join();
            if (member == '') member = '<fn>';

            // Some Firefox members have initial dots. We remove them for
            // consistency with other platforms.
            member = member.replaceFirst(_initialDot, '');
          } else {
            member = '<fn>';
          }

          var line = match[4] == '' ? null : int.parse(match[4]!);
          var column =
              match[5] == null || match[5] == '' ? null : int.parse(match[5]!);
          return Frame(uri, line, column, member);
        }

        match = _firefoxWasmFrame.firstMatch(frame);
        if (match != null) {
          final member = match.namedGroup('member')!;
          final uri = _uriOrPathToUri(match.namedGroup('uri')!);
          final functionIndex = match.namedGroup('index')!;
          final functionOffset =
              int.parse(match.namedGroup('offset')!, radix: 16);
          return Frame(uri, 1, functionOffset + 1,
              member.isNotEmpty ? member : functionIndex);
        }

        match = _safariWasmFrame.firstMatch(frame);
        if (match != null) {
          final member = match.namedGroup('member')!;
          return Frame(Uri(path: 'wasm code'), null, null, member);
        }

        return UnparsedFrame(frame);
      });

  /// Parses a string representation of a Safari 6.0 stack frame.
  @Deprecated('Use Frame.parseSafari instead.')
  factory Frame.parseSafari6_0(String frame) => Frame.parseFirefox(frame);

  /// Parses a string representation of a Safari 6.1+ stack frame.
  @Deprecated('Use Frame.parseSafari instead.')
  factory Frame.parseSafari6_1(String frame) => Frame.parseFirefox(frame);

  /// Parses a string representation of a Safari stack frame.
  factory Frame.parseSafari(String frame) => Frame.parseFirefox(frame);

  /// Parses this package's string representation of a stack frame.
  factory Frame.parseFriendly(String frame) => _catchFormatException(frame, () {
        var match = _friendlyFrame.firstMatch(frame);
        if (match == null) {
          throw FormatException(
              "Couldn't parse package:stack_trace stack trace line '$frame'.");
        }
        // Fake truncated data urls generated by the friendly stack trace format
        // cause Uri.parse to throw an exception so we have to special case
        // them.
        var uri = match[1] == 'data:...'
            ? Uri.dataFromString('')
            : Uri.parse(match[1]!);
        // If there's no scheme, this is a relative URI. We should interpret it
        // as relative to the current working directory.
        if (uri.scheme == '') {
          uri = path.toUri(path.absolute(path.fromUri(uri)));
        }

        var line = match[2] == null ? null : int.parse(match[2]!);
        var column = match[3] == null ? null : int.parse(match[3]!);
        return Frame(uri, line, column, match[4]);
      });

  /// A regular expression matching an absolute URI.
  static final _uriRegExp = RegExp(r'^[a-zA-Z][-+.a-zA-Z\d]*://');

  /// A regular expression matching a Windows path.
  static final _windowsRegExp = RegExp(r'^([a-zA-Z]:[\\/]|\\\\)');

  /// Converts [uriOrPath], which can be a URI, a Windows path, or a Posix path,
  /// to a URI (absolute if possible).
  static Uri _uriOrPathToUri(String uriOrPath) {
    if (uriOrPath.contains(_uriRegExp)) {
      return Uri.parse(uriOrPath);
    } else if (uriOrPath.contains(_windowsRegExp)) {
      return Uri.file(uriOrPath, windows: true);
    } else if (uriOrPath.startsWith('/')) {
      return Uri.file(uriOrPath, windows: false);
    }

    // As far as I've seen, Firefox and V8 both always report absolute paths in
    // their stack frames. However, if we do get a relative path, we should
    // handle it gracefully.
    if (uriOrPath.contains('\\')) return path.windows.toUri(uriOrPath);
    return Uri.parse(uriOrPath);
  }

  /// Runs [body] and returns its result.
  ///
  /// If [body] throws a [FormatException], returns an [UnparsedFrame] with
  /// [text] instead.
  static Frame _catchFormatException(String text, Frame Function() body) {
    try {
      return body();
    } on FormatException catch (_) {
      return UnparsedFrame(text);
    }
  }

  Frame(this.uri, this.line, this.column, this.member);

  @override
  String toString() => '$location in $member';
}
