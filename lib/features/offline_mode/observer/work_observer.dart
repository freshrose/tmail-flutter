import 'dart:async';
import 'package:core/presentation/state/failure.dart';
import 'package:core/presentation/state/success.dart';
import 'package:core/utils/app_logger.dart';
import 'package:dartz/dartz.dart';

abstract class WorkObserver {
  Future<void> bindDI();

  Future<void> observe(String taskId, Map<String, dynamic> inputData, Completer<bool> completer);

  void consumeState(Stream<Either<Failure, Success>> newStateStream) {
    newStateStream.listen(
      _handleStateStream,
      onError: (error, stackTrace) {
        logError('WorkObserver::consumeState():onError:error: $error');
        logError('WorkObserver::consumeState():onError:stackTrace: $stackTrace');
      }
    );
  }

  void _handleStateStream(Either<Failure, Success> newState) {
    newState.fold(handleFailureViewState, handleSuccessViewState);
  }

  void handleFailureViewState(Failure failure) {}

  void handleSuccessViewState(Success success) {}
}