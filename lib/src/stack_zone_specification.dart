// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'trace.dart';
import 'chain.dart';

/// A function that handles errors in the zone wrapped by [Chain.capture].
typedef void _ChainHandler(error, Chain chain);

/// A class encapsulating the zone specification for a [Chain.capture] zone.
///
/// Until they're materialized and exposed to the user, stack chains are tracked
/// as linked lists of [Trace]s using the [_Node] class. These nodes are stored
/// in three distinct ways:
///
/// * When a callback is registered, a node is created and stored as a captured
///   local variable until the callback is run.
///
/// * When a callback is run, its captured node is set as the [_currentNode] so
///   it can be available to [Chain.current] and to be linked into additional
///   chains when more callbacks are scheduled.
///
/// * When a callback throws an error or a Future or Stream emits an error, the
///   current node is associated with that error's stack trace using the
///   [_chains] expando.
///
/// Since [ZoneSpecification] can't be extended or even implemented, in order to
/// get a real [ZoneSpecification] instance it's necessary to call [toSpec].
class StackZoneSpecification {
  /// An opaque object used as a zone value to disable chain tracking in a given
  /// zone.
  ///
  /// If `Zone.current[disableKey]` is `true`, no stack chains will be tracked.
  static final disableKey = new Object();

  /// Whether chain-tracking is disabled in the current zone.
  bool get _disabled => Zone.current[disableKey] == true;

  /// The expando that associates stack chains with [StackTrace]s.
  ///
  /// The chains are associated with stack traces rather than errors themselves
  /// because it's a common practice to throw strings as errors, which can't be
  /// used with expandos.
  ///
  /// The chain associated with a given stack trace doesn't contain a node for
  /// that stack trace.
  final _chains = new Expando<_Node>("stack chains");

  /// The error handler for the zone.
  ///
  /// If this is null, that indicates that any unhandled errors should be passed
  /// to the parent zone.
  final _ChainHandler _onError;

  /// The most recent node of the current stack chain.
  _Node _currentNode;

  StackZoneSpecification([this._onError]);

  /// Converts [this] to a real [ZoneSpecification].
  ZoneSpecification toSpec() {
    return new ZoneSpecification(
        handleUncaughtError: _handleUncaughtError,
        registerCallback: _registerCallback,
        registerUnaryCallback: _registerUnaryCallback,
        registerBinaryCallback: _registerBinaryCallback,
        errorCallback: _errorCallback);
  }

  /// Returns the current stack chain.
  ///
  /// By default, the first frame of the first trace will be the line where
  /// [currentChain] is called. If [level] is passed, the first trace will start
  /// that many frames up instead.
  Chain currentChain([int level=0]) => _createNode(level + 1).toChain();

  /// Returns the stack chain associated with [trace], if one exists.
  ///
  /// The first stack trace in the returned chain will always be [trace]
  /// (converted to a [Trace] if necessary). If there is no chain associated
  /// with [trace], this just returns a single-trace chain containing [trace].
  Chain chainFor(StackTrace trace) {
    if (trace is Chain) return trace;
    var previous = trace == null ? null : _chains[trace];
    return new _Node(trace, previous).toChain();
  }

  /// Tracks the current stack chain so it can be set to [_currentChain] when
  /// [f] is run.
  ZoneCallback _registerCallback(Zone self, ZoneDelegate parent, Zone zone,
      Function f) {
    if (f == null || _disabled) return parent.registerCallback(zone, f);
    var node = _createNode(1);
    return parent.registerCallback(zone, () => _run(f, node));
  }

  /// Tracks the current stack chain so it can be set to [_currentChain] when
  /// [f] is run.
  ZoneUnaryCallback _registerUnaryCallback(Zone self, ZoneDelegate parent,
      Zone zone, Function f) {
    if (f == null || _disabled) return parent.registerUnaryCallback(zone, f);
    var node = _createNode(1);
    return parent.registerUnaryCallback(zone, (arg) {
      return _run(() => f(arg), node);
    });
  }

  /// Tracks the current stack chain so it can be set to [_currentChain] when
  /// [f] is run.
  ZoneBinaryCallback _registerBinaryCallback(Zone self, ZoneDelegate parent,
      Zone zone, Function f) {
    if (f == null || _disabled) return parent.registerBinaryCallback(zone, f);

    var node = _createNode(1);
    return parent.registerBinaryCallback(zone, (arg1, arg2) {
      return _run(() => f(arg1, arg2), node);
    });
  }

  /// Looks up the chain associated with [stackTrace] and passes it either to
  /// [_onError] or [parent]'s error handler.
  _handleUncaughtError(Zone self, ZoneDelegate parent, Zone zone, error,
      StackTrace stackTrace) {
    if (_disabled) {
      return parent.handleUncaughtError(zone, error, stackTrace);
    }

    var stackChain = chainFor(stackTrace);
    if (_onError == null) {
      return parent.handleUncaughtError(zone, error, stackChain);
    }

    // TODO(nweiz): Currently this copies a lot of logic from [runZoned]. Just
    // allow [runBinary] to throw instead once issue 18134 is fixed.
    try {
      return parent.runBinary(zone, _onError, error, stackChain);
    } catch (newError, newStackTrace) {
      if (identical(newError, error)) {
        return parent.handleUncaughtError(zone, error, stackChain);
      } else {
        return parent.handleUncaughtError(zone, newError, newStackTrace);
      }
    }
  }

  /// Attaches the current stack chain to [stackTrace], replacing it if
  /// necessary.
  AsyncError _errorCallback(Zone self, ZoneDelegate parent, Zone zone,
      Object error, StackTrace stackTrace) {
    if (_disabled) return parent.errorCallback(zone, error, stackTrace);

    // Go up two levels to get through [_CustomZone.errorCallback].
    if (stackTrace == null) {
      stackTrace = _createNode(2).toChain();
    } else {
      if (_chains[stackTrace] == null) _chains[stackTrace] = _createNode(2);
    }

    var asyncError = parent.errorCallback(zone, error, stackTrace);
    return asyncError == null ? new AsyncError(error, stackTrace) : asyncError;
  }

  /// Creates a [_Node] with the current stack trace and linked to
  /// [_currentNode].
  ///
  /// By default, the first frame of the first trace will be the line where
  /// [_createNode] is called. If [level] is passed, the first trace will start
  /// that many frames up instead.
  _Node _createNode([int level=0]) =>
    new _Node(new Trace.current(level + 1), _currentNode);

  // TODO(nweiz): use a more robust way of detecting and tracking errors when
  // issue 15105 is fixed.
  /// Runs [f] with [_currentNode] set to [node].
  ///
  /// If [f] throws an error, this associates [node] with that error's stack
  /// trace.
  _run(Function f, _Node node) {
    var previousNode = _currentNode;
    _currentNode = node;
    try {
      return f();
    } catch (e, stackTrace) {
      _chains[stackTrace] = node;
      rethrow;
    } finally {
      _currentNode = previousNode;
    }
  }
}

/// A linked list node representing a single entry in a stack chain.
class _Node {
  /// The stack trace for this link of the chain.
  final Trace trace;

  /// The previous node in the chain.
  final _Node previous;

  _Node(StackTrace trace, [this.previous])
      : trace = trace == null ? new Trace.current() : new Trace.from(trace);

  /// Converts this to a [Chain].
  Chain toChain() {
    var nodes = <Trace>[];
    var node = this;
    while (node != null) {
      nodes.add(node.trace);
      node = node.previous;
    }
    return new Chain(nodes);
  }
}
