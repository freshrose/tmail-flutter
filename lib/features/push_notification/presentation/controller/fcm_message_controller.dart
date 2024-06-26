
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:core/data/network/config/dynamic_url_interceptors.dart';
import 'package:core/presentation/state/failure.dart';
import 'package:core/presentation/state/success.dart';
import 'package:core/utils/app_logger.dart';
import 'package:core/utils/platform_info.dart';
import 'package:fcm/model/type_name.dart';
import 'package:jmap_dart_client/jmap/account_id.dart';
import 'package:jmap_dart_client/jmap/core/session/session.dart';
import 'package:jmap_dart_client/jmap/core/state.dart' as jmap;
import 'package:jmap_dart_client/jmap/core/user_name.dart';
import 'package:jmap_dart_client/jmap/push/state_change.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tmail_ui_user/features/base/action/ui_action.dart';
import 'package:tmail_ui_user/features/caching/config/hive_cache_config.dart';
import 'package:tmail_ui_user/features/home/domain/extensions/session_extensions.dart';
import 'package:tmail_ui_user/features/home/domain/state/get_session_state.dart';
import 'package:tmail_ui_user/features/home/domain/usecases/get_session_interactor.dart';
import 'package:tmail_ui_user/features/home/presentation/home_bindings.dart';
import 'package:tmail_ui_user/features/login/data/network/interceptors/authorization_interceptors.dart';
import 'package:tmail_ui_user/features/login/domain/state/get_authenticated_account_state.dart';
import 'package:tmail_ui_user/features/login/domain/state/get_credential_state.dart';
import 'package:tmail_ui_user/features/login/domain/state/get_stored_token_oidc_state.dart';
import 'package:tmail_ui_user/features/login/domain/usecases/get_authenticated_account_interactor.dart';
import 'package:tmail_ui_user/features/mailbox_dashboard/presentation/bindings/mailbox_dashboard_bindings.dart';
import 'package:tmail_ui_user/features/push_notification/presentation/action/fcm_action.dart';
import 'package:tmail_ui_user/features/push_notification/presentation/bindings/fcm_interactor_bindings.dart';
import 'package:tmail_ui_user/features/push_notification/presentation/controller/fcm_base_controller.dart';
import 'package:tmail_ui_user/features/push_notification/presentation/controller/fcm_token_controller.dart';
import 'package:tmail_ui_user/features/push_notification/presentation/extensions/state_change_extension.dart';
import 'package:tmail_ui_user/features/push_notification/presentation/listener/email_change_listener.dart';
import 'package:tmail_ui_user/features/push_notification/presentation/listener/mailbox_change_listener.dart';
import 'package:tmail_ui_user/features/push_notification/presentation/services/fcm_service.dart';
import 'package:tmail_ui_user/features/push_notification/presentation/utils/fcm_utils.dart';
import 'package:tmail_ui_user/main/bindings/main_bindings.dart';
import 'package:tmail_ui_user/main/routes/route_navigation.dart';

class FcmMessageController extends FcmBaseController {

  AccountId? _currentAccountId;
  Session? _currentSession;
  UserName? _userName;
  Map<String, dynamic>? _payloadData;

  GetAuthenticatedAccountInteractor? _getAuthenticatedAccountInteractor;
  DynamicUrlInterceptors? _dynamicUrlInterceptors;
  AuthorizationInterceptors? _authorizationInterceptors;
  GetSessionInteractor? _getSessionInteractor;

  FcmMessageController._internal();

  static final FcmMessageController _instance = FcmMessageController._internal();

  static FcmMessageController get instance => _instance;

  void initialize({AccountId? accountId, Session? session}) {
    _currentAccountId = accountId;
    _currentSession = session;
    _userName = session?.username;

    _listenTokenStream();
    _listenForegroundMessageStream();
    _listenBackgroundMessageStream();
  }

  void _listenForegroundMessageStream() {
    FcmService.instance.foregroundMessageStreamController
      ?.stream
      .debounceTime(const Duration(milliseconds: FcmUtils.durationMessageComing))
      .listen(_handleForegroundMessageAction);
  }

  void _listenBackgroundMessageStream() {
    FcmService.instance.backgroundMessageStreamController
      ?.stream
      .debounceTime(const Duration(milliseconds: FcmUtils.durationMessageComing))
      .listen(_handleBackgroundMessageAction);
  }

  void _listenTokenStream() {
    FcmService.instance.fcmTokenStreamController
      ?.stream
      .debounceTime(const Duration(milliseconds: FcmUtils.durationRefreshToken))
      .listen(FcmTokenController.instance.onFcmTokenChanged);
  }

  void _handleForegroundMessageAction(Map<String, dynamic> payloadData) {
    log('FcmMessageController::_handleForegroundMessageAction():payloadData: $payloadData | _currentAccountId: $_currentAccountId');
    if (_currentAccountId != null && _userName != null) {
      final stateChange = _parsingPayloadData(payloadData);
      final mapTypeState = stateChange.getMapTypeState(_currentAccountId!);
      _mappingTypeStateToAction(mapTypeState, _currentAccountId!, _userName!, session: _currentSession);
    }
  }

  void _handleBackgroundMessageAction(Map<String, dynamic> payloadData) async {
    log('FcmMessageController::_handleBackgroundMessageAction():payloadData: $payloadData');
    _payloadData = payloadData;
    await _initialAppConfig();
    _getAuthenticatedAccount();
  }

  StateChange? _parsingPayloadData(Map<String, dynamic> payloadData) {
    return FcmUtils.instance.convertFirebaseDataMessageToStateChange(payloadData);
  }

  void _mappingTypeStateToAction(
    Map<String, dynamic> mapTypeState,
    AccountId accountId,
    UserName userName, {
    bool isForeground = true,
    Session? session
  }) {
    log('FcmMessageController::_mappingTypeStateToAction():mapTypeState: $mapTypeState');
    final listTypeName = mapTypeState.keys
      .map((value) => TypeName(value))
      .toList();

    final listEmailActions = listTypeName
      .where((typeName) => typeName == TypeName.emailType || typeName == TypeName.emailDelivery)
      .map((typeName) => toFcmAction(typeName, accountId, userName, mapTypeState, isForeground, session: session))
      .whereNotNull()
      .toList();

    log('FcmMessageController::_mappingTypeStateToAction():listEmailActions: $listEmailActions');

    if (listEmailActions.isNotEmpty) {
       EmailChangeListener.instance.dispatchActions(listEmailActions);
    }

    final listMailboxActions = listTypeName
      .where((typeName) => typeName == TypeName.mailboxType)
      .map((typeName) => toFcmAction(typeName, accountId, userName, mapTypeState, isForeground))
      .whereNotNull()
      .toList();

    log('FcmMessageController::_mappingTypeStateToAction():listMailboxActions: $listEmailActions');

    if (listMailboxActions.isNotEmpty) {
      MailboxChangeListener.instance.dispatchActions(listMailboxActions);
    }
  }

  FcmAction? toFcmAction(
    TypeName typeName,
    AccountId accountId,
    UserName userName,
    Map<String, dynamic> mapTypeState,
    isForeground,
    {
      Session? session
    }
  ) {
    final newState = jmap.State(mapTypeState[typeName.value]);
    if (typeName == TypeName.emailType) {
      if (isForeground) {
        return SynchronizeEmailOnForegroundAction(typeName, newState, accountId, session);
      } else {
        return StoreEmailStateToRefreshAction(typeName, newState, accountId, userName, session);
      }
    } else if (typeName == TypeName.emailDelivery) {
      if (!isForeground) {
        return PushNotificationAction(typeName, newState, session, accountId, userName);
      }
    } else if (typeName == TypeName.mailboxType) {
      if (isForeground) {
        return SynchronizeMailboxOnForegroundAction(typeName, newState, accountId);
      } else {
        return StoreMailboxStateToRefreshAction(typeName, newState, accountId, userName);
      }
    }
    return null;
  }

  Future<void> _initialAppConfig() async {
    await Future.wait([
      MainBindings().dependencies(),
      HiveCacheConfig.instance.setUp()
    ]);

    await Future.sync(() {
      HomeBindings().dependencies();
      MailboxDashBoardBindings().dependencies();
      FcmInteractorBindings().dependencies();
    });

    _getInteractorBindings();
  }

  void _getInteractorBindings() {
    _getAuthenticatedAccountInteractor = getBinding<GetAuthenticatedAccountInteractor>();
    _dynamicUrlInterceptors = getBinding<DynamicUrlInterceptors>();
    _authorizationInterceptors = getBinding<AuthorizationInterceptors>();
    _getSessionInteractor = getBinding<GetSessionInteractor>();

    FcmTokenController.instance.initialBindingInteractor();
  }

  void _getAuthenticatedAccount() {
    if (_getAuthenticatedAccountInteractor != null) {
      consumeState(_getAuthenticatedAccountInteractor!.execute());
    } else {
      _clearPayloadData();
      logError('FcmMessageController::_getAuthenticatedAccount():_getAuthenticatedAccountInteractor is null');
    }
  }

  void _handleGetAuthenticatedAccountSuccess(GetAuthenticatedAccountSuccess success) {
    _currentAccountId = success.account.accountId;
    _userName = success.account.userName;
    if (!PlatformInfo.isAndroid) {
      _dynamicUrlInterceptors?.changeBaseUrl(success.account.apiUrl);
    }
    log('FcmMessageController::_handleGetAuthenticatedAccountSuccess():_currentAccountId: $_currentAccountId | _userName: $_userName');
  }

  void _handleGetAccountByOidcSuccess(GetStoredTokenOidcSuccess storedTokenOidcSuccess) {
    log('FcmMessageController::_handleGetAccountByOidcSuccess():');
    _dynamicUrlInterceptors?.setJmapUrl(storedTokenOidcSuccess.baseUrl.toString());
    _authorizationInterceptors?.setTokenAndAuthorityOidc(
      newToken: storedTokenOidcSuccess.tokenOidc,
      newConfig: storedTokenOidcSuccess.oidcConfiguration
    );

    if (PlatformInfo.isAndroid) {
      _dynamicUrlInterceptors?.changeBaseUrl(storedTokenOidcSuccess.baseUrl.toString());
      _getSessionAction();
    } else {
      _pushActionFromRemoteMessageBackground();
    }
  }

  void _handleGetAccountByBasicAuthSuccess(GetCredentialViewState credentialViewState) {
    log('FcmMessageController::_handleGetAccountByBasicAuthSuccess():');
    _dynamicUrlInterceptors?.setJmapUrl(credentialViewState.baseUrl.toString());
    _authorizationInterceptors?.setBasicAuthorization(
      credentialViewState.userName,
      credentialViewState.password,
    );
    if (PlatformInfo.isAndroid) {
      _dynamicUrlInterceptors?.changeBaseUrl(credentialViewState.baseUrl.toString());
      _getSessionAction();
    } else {
      _pushActionFromRemoteMessageBackground();
    }
  }

  void _getSessionAction() {
    if (_getSessionInteractor != null) {
      consumeState(_getSessionInteractor!.execute());
    } else {
      _clearPayloadData();
      logError('FcmMessageController::_getSessionAction():_getSessionInteractor is null');
    }
  }

  void _handleGetSessionSuccess(GetSessionSuccess success) {
    _currentSession = success.session;
    _userName = success.session.username;
    final apiUrl = success.session.getQualifiedApiUrl(baseUrl: _dynamicUrlInterceptors?.jmapUrl);
    log('FcmMessageController::_pushActionFromRemoteMessageBackground():apiUrl: $apiUrl');
    if (apiUrl.isNotEmpty) {
      _dynamicUrlInterceptors?.changeBaseUrl(apiUrl);
      _pushActionFromRemoteMessageBackground();
    } else {
      _clearPayloadData();
      logError('FcmMessageController::_handleGetSessionSuccess():apiUrl is null');
    }
  }

  void _pushActionFromRemoteMessageBackground() {
    log('FcmMessageController::_pushActionFromRemoteMessageBackground():_payloadData: $_payloadData | _currentAccountId: $_currentAccountId | _currentSession: $_currentSession');
    if (_payloadData?.isNotEmpty == true && _currentAccountId != null && _userName != null) {
      final stateChange = _parsingPayloadData(_payloadData!);
      final mapTypeState = stateChange.getMapTypeState(_currentAccountId!);
      _mappingTypeStateToAction(mapTypeState, _currentAccountId!, _userName!, isForeground: false, session: _currentSession);
    }
    _clearPayloadData();
  }

  void _clearPayloadData() {
    _payloadData = null;
  }

  @override
  void handleFailureViewState(Failure failure) {
    log('FcmMessageController::_handleFailureViewState(): $failure');
    _clearPayloadData();
  }

  @override
  void handleSuccessViewState(Success success) {
    log('FcmMessageController::_handleSuccessViewState(): $success');
    if (success is GetAuthenticatedAccountSuccess) {
      _handleGetAuthenticatedAccountSuccess(success);
    } else if (success is GetSessionSuccess) {
      _handleGetSessionSuccess(success);
    } else if (success is GetStoredTokenOidcSuccess) {
      _handleGetAccountByOidcSuccess(success);
    } else if (success is GetCredentialViewState) {
      _handleGetAccountByBasicAuthSuccess(success);
    }
  }
}