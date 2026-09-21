import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../api/api_service.dart';
import '../l10n/global_l10n.dart';
import '../utils/debug_log.dart';
import 'notification_text.dart';

/// Web implementation: the Notifications API while the page is open, plus a
/// dedicated push service worker (web/push/sw.js) so delivery continues with
/// the tab closed.
class NotificationService {
  bool _notificationsEnabled = false;
  bool _initialized = false;
  bool _initialThreadConsumed = false;
  String _pushStatus = 'off';

  /// Invoked with a thread id when the user activates a notification — both
  /// in-page ones and service worker push clicks routed via postMessage.
  void Function(String threadId)? onOpenThread;

  bool get notificationsEnabled => _notificationsEnabled;

  /// 'on' while a subscription is registered with the server, 'off' when it
  /// is not, 'denied'/'unsupported' for the platform-level blockers, and
  /// 'unavailable'/'error' when the server has no push support or the
  /// registration failed.
  String get pushStatus {
    if (!pushSupported) return 'unsupported';
    if (_permission == 'denied') return 'denied';
    return _pushStatus;
  }

  bool get pushSupported {
    try {
      // Accessing serviceWorker throws on browsers without it.
      web.window.navigator.serviceWorker;
      return _hasNotification &&
          (web.window as JSObject).hasProperty('PushManager'.toJS).toDart;
    } catch (_) {
      return false;
    }
  }

  bool get _hasNotification {
    try {
      return (web.window as JSObject).hasProperty('Notification'.toJS).toDart;
    } catch (_) {
      return false;
    }
  }

  String get _permission {
    try {
      return web.Notification.permission;
    } catch (_) {
      return 'unsupported';
    }
  }

  /// Attach the service-worker message listener once. Called at bootstrap so
  /// push clicks route even when in-page notifications are off.
  void initialize() {
    if (_initialized) return;
    _initialized = true;
    try {
      web.window.navigator.serviceWorker.addEventListener(
        'message',
        _onServiceWorkerMessage.toJS,
      );
    } catch (_) {}
  }

  void _onServiceWorkerMessage(web.Event event) {
    try {
      final data = (event as web.MessageEvent).data.dartify();
      if (data is Map && data['type'] == 'open_thread') {
        final id = data['thread_id'];
        if (id is String && id.isNotEmpty) onOpenThread?.call(id);
      }
    } catch (_) {}
  }

  /// The `?thread=` deep link a push click opened the app with. Consumed on
  /// first read so later logins or server switches do not reopen it.
  String? initialThreadId() {
    if (_initialThreadConsumed) return null;
    _initialThreadConsumed = true;
    try {
      final uri = Uri.parse(web.window.location.href);
      final id = uri.queryParameters['thread'];
      if (id == null || id.isEmpty) return null;
      // Strip the param so reloads and server switches do not reopen the
      // thread forever.
      final cleaned = uri.replace(
        queryParameters: Map.of(uri.queryParameters)..remove('thread'),
      );
      try {
        web.window.history.replaceState(null, '', cleaned.toString());
      } catch (_) {}
      return id;
    } catch (_) {
      return null;
    }
  }

  /// 'granted' | 'denied' | 'default' | 'unsupported'.
  Future<String> permissionState() async => _permission;

  Future<void> setNotificationsEnabled(
    bool enabled, {
    bool allowPrompt = true,
  }) async {
    _notificationsEnabled = enabled;
    if (enabled && allowPrompt) await _requestPermission();
  }

  Future<void> _requestPermission() async {
    try {
      if (web.Notification.permission == 'default') {
        await web.Notification.requestPermission().toDart;
      }
    } catch (_) {}
  }

  /// Show a notification for a run transition. Visibility decisions are the
  /// caller's — the service only honors the preference and permission.
  void notifyRunEvent({
    required String threadId,
    required String title,
    required String kind,
  }) {
    if (!_notificationsEnabled || _permission != 'granted') return;
    final (headline, body) = runEventText(appL10n, kind, title);
    try {
      final notification = web.Notification(
        headline,
        web.NotificationOptions(
          body: body,
          tag: 'devinorium-$kind-$threadId',
          icon: 'icons/Icon-192.png',
        ),
      );
      notification.onclick = ((web.Event _) {
        try {
          web.window.focus();
        } catch (_) {}
        onOpenThread?.call(threadId);
      }).toJS;
    } catch (_) {}
  }

  /// Reconcile the desired push state: subscribing (and registering the
  /// endpoint with the server) when [enabled], tearing it down otherwise.
  /// [allowPrompt] controls whether a missing notification permission may
  /// trigger the browser prompt — automatic re-syncs never prompt.
  Future<String> syncPush({
    required ApiService api,
    required String lang,
    required bool enabled,
    bool allowPrompt = false,
  }) async {
    if (!pushSupported) {
      return _pushStatus = 'unsupported';
    }
    if (!enabled) {
      await _unsubscribe(api);
      return _pushStatus = 'off';
    }
    try {
      final registration = await _pushRegistration();
      if (registration == null) return _pushStatus = 'error';
      final vapidKey = await api.pushVapidKey();
      if (vapidKey == null) return _pushStatus = 'unavailable';
      var subscription = await registration.pushManager
          .getSubscription()
          .toDart;
      if (subscription != null &&
          _subscriptionServerKey(subscription) != vapidKey) {
        // Bound to another server's VAPID key — pushes would be rejected
        // silently by the push service, so re-subscribe.
        try {
          await api.pushUnsubscribe(subscription.endpoint);
        } catch (_) {}
        await subscription.unsubscribe().toDart;
        subscription = null;
      }
      if (subscription == null) {
        var permission = _permission;
        if (permission != 'granted' && allowPrompt) {
          await _requestPermission();
          permission = _permission;
        }
        if (permission != 'granted') {
          return _pushStatus = permission == 'denied' ? 'denied' : 'off';
        }
        subscription = await _subscribeFresh(registration, vapidKey);
        if (subscription == null) return _pushStatus;
      }
      final p256dh = _subscriptionKey(subscription, 'p256dh');
      final auth = _subscriptionKey(subscription, 'auth');
      if (p256dh == null || auth == null) return _pushStatus = 'error';
      await api.pushSubscribe(
        endpoint: subscription.endpoint,
        p256dh: p256dh,
        auth: auth,
        lang: lang,
      );
      return _pushStatus = 'on';
    } catch (e) {
      debugLogFailure('notifications.syncPush', e);
      return _pushStatus = 'error';
    }
  }

  /// The application server key this subscription was created with, as a
  /// base64url string matching the format `GET /api/push/vapid-key` returns.
  /// Null when the subscription predates `options` support.
  String? _subscriptionServerKey(web.PushSubscription subscription) {
    try {
      final key = subscription.options.applicationServerKey;
      if (key == null) return null;
      return base64Url.encode(key.toDart.asUint8List()).replaceAll('=', '');
    } catch (_) {
      return null;
    }
  }

  Future<web.ServiceWorkerRegistration?> _pushRegistration() async {
    try {
      return await web.window.navigator.serviceWorker
          .register('push/sw.js'.toJS, web.RegistrationOptions(scope: 'push/'))
          .toDart;
    } catch (e) {
      debugLogFailure('notifications.swRegister', e);
      return null;
    }
  }

  Future<web.PushSubscription?> _subscribeFresh(
    web.ServiceWorkerRegistration registration,
    String vapidKey,
  ) async {
    final options = web.PushSubscriptionOptionsInit(
      userVisibleOnly: true,
      applicationServerKey: base64Url
          .decode(base64Url.normalize(vapidKey))
          .toJS,
    );
    try {
      return await registration.pushManager.subscribe(options).toDart;
    } catch (_) {
      // A stale subscription bound to a different application server key
      // must go before the browser accepts a new one.
      try {
        final stale = await registration.pushManager.getSubscription().toDart;
        await stale?.unsubscribe().toDart;
        return await registration.pushManager.subscribe(options).toDart;
      } catch (e) {
        debugLogFailure('notifications.subscribe', e);
        _pushStatus = 'error';
        return null;
      }
    }
  }

  Future<void> _unsubscribe(ApiService api) async {
    try {
      final registration = await web.window.navigator.serviceWorker
          .getRegistration('push/')
          .toDart;
      final subscription = await registration?.pushManager
          .getSubscription()
          .toDart;
      if (subscription == null) return;
      try {
        await api.pushUnsubscribe(subscription.endpoint);
      } catch (_) {}
      await subscription.unsubscribe().toDart;
    } catch (e) {
      debugLogFailure('notifications.unsubscribe', e);
    }
  }

  String? _subscriptionKey(web.PushSubscription subscription, String name) {
    final buffer = subscription.getKey(name);
    if (buffer == null) return null;
    return base64Url.encode(buffer.toDart.asUint8List());
  }
}
