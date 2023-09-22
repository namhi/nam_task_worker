import 'dart:async';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

class TaskRunner {
  TaskRunner({
    this.maximumConcurrent = 1,
    this.workerDelay,
    this.taskDelay,
  }) {
    _workers = List<TaskWorker>.generate(
      maximumConcurrent,
      (index) => TaskWorker(
          taskDelay: taskDelay,
          onChanged: (key) {
            onStatusChanged?.call(key);
          }),
    ).toList();
  }

  final int maximumConcurrent;
  final Duration? taskDelay;
  final Duration? workerDelay;

  late final List<TaskWorker> _workers;

  List<dynamic> get runningKeys =>
      _workers.expand((element) => element.runningKeys).toList();

  List<dynamic> get queueKeys =>
      _workers.expand((element) => element.queueKeys).toList();

  Function(dynamic key)? onStatusChanged;

  Future<dynamic> run(
    Function future,
    dynamic key, {
    Future<bool> Function()? onErrorRetry,
  }) async {
    final TaskWorker? freeWorker = minBy(_workers, (s) => s.delayTask);
    final workerIndex = _workers.indexOf(freeWorker!);
    if (kDebugMode) {
      print('Task added run by worker <$workerIndex>');
    }

    final result = await freeWorker.run(
      future,
      key,
      onErrorRetry: onErrorRetry,
    );
    return result;
  }
}

class TaskWorker {
  TaskWorker({this.taskDelay, this.onChanged});

  final Duration? taskDelay;
  final QueueList<TaskJob> _taskQueue = QueueList<TaskJob>();
  bool _isQueueRunning = false;

  int get delayTask => _taskQueue.length;

  final Function(dynamic key)? onChanged;

  List<dynamic> get runningKeys => _taskQueue
      .where((element) => element.status == TaskJobStatus.running)
      .map((e) => e.unique)
      .toList();

  List<dynamic> get queueKeys => _taskQueue
      .where((element) => element.status == TaskJobStatus.queue)
      .map((e) => e.unique)
      .toList();

  Future<dynamic> run(
    Function future,
    dynamic key, {
    Future<bool> Function()? onErrorRetry,
  }) async {
    final Completer completer = Completer();
    final TaskJob job = TaskJob(
      unique: key,
      future: future,
      createdTime: DateTime.now(),
      status: TaskJobStatus.queue,
      onErrorRetry: onErrorRetry,
      onCompleted: (result) {
        if (kDebugMode) {
          print('Job completed: CreatedAt:');
        }
        completer.complete(result);
      },
      onError: (e, s) {
        completer.completeError(e, s);
      },
    );

    _taskQueue.add(job);
    unawaited(_startJob());
    await completer.future;
  }

  Future<dynamic> _startJob() async {
    if (_isQueueRunning) {
      if (kDebugMode) {
        print('worker already running');
      }
      return;
    }

    _isQueueRunning = true;

    while (_taskQueue.isNotEmpty) {
      if (taskDelay != null) {
        await Future.delayed(taskDelay!);
      }
      final job = _taskQueue.first;
      job.startTime = DateTime.now();
      job.status = TaskJobStatus.running;
      onChanged?.call(job.unique);

      try {
        final result = await job.future();
        job.completedTime = DateTime.now();
        job.status = TaskJobStatus.done;
        job.onCompleted(result);
      } catch (e, s) {
        job.status = TaskJobStatus.doneWithError;
        job.completedTime = DateTime.now();
        job.onError?.call(e, s);
      }

      onChanged?.call(job.unique);

      if (kDebugMode) {
        print(
          'job completed: '
          '\nAdded At: ${job.createdTime}'
          '\nStarted At: ${job.startTime}'
          '\nCompleted At: ${job.completedTime}',
        );
      }
      bool needRetry = false;
      if (job.onErrorRetry != null) {
        needRetry = await job.onErrorRetry!.call();
      }

      if (!needRetry) {
        _taskQueue.remove(job);
      }
    }

    _isQueueRunning = false;
  }
}

class TaskJob {
  TaskJob({
    required this.unique,
    this.createdTime,
    this.startTime,
    this.completedTime,
    required this.future,
    required this.onCompleted,
    this.onError,
    this.status = TaskJobStatus.queue,
    this.onErrorRetry,
  });

  String unique;
  DateTime? startTime;
  DateTime? createdTime;
  DateTime? completedTime;
  TaskJobStatus status;
  final Function future;
  final Function(dynamic) onCompleted;
  final Function(dynamic error, StackTrace stackTrace)? onError;
  final Future<bool> Function()? onErrorRetry;
}

enum TaskJobStatus {
  queue,
  running,
  done,
  doneWithError,
}
