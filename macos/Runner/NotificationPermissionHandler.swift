import Cocoa
import FlutterMacOS
import UserNotifications

/// 通知权限查询/请求/跳转设置的 macOS 原生桥接。
///
/// 关键修复：macOS 上 `authorizationStatus` 和通知实际送达设置是独立的。
/// 用户在系统设置关闭 "Allow Notifications" 后 `authorizationStatus`
/// 仍是 `.authorized`，但 `notificationCenterSetting` 变为 `.disabled`。
/// 本 handler 同时检查两者，避免 App 内误显示"提醒已开启"。
final class NotificationPermissionHandler: NSObject {
  private let methodChannel: FlutterMethodChannel

  init(binaryMessenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "top.loop-back/notification_permission",
      binaryMessenger: binaryMessenger
    )
    super.init()
    methodChannel.setMethodCallHandler(handle)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getAuthorizationStatus":
      getAuthorizationStatus(result: result)
    case "requestAuthorization":
      requestAuthorization(result: result)
    case "openSettings":
      openSettings(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 查询通知授权状态。
  ///
  /// 仅当 `authorizationStatus` 为 authorized/provisional **且**
  /// notificationCenter/alert/badge/sound 中至少一个为 enabled 时返回 authorized。
  /// 否则返回 denied（用户已在系统设置关闭）、notDetermined 或 restricted。
  private func getAuthorizationStatus(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let status: String
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        let effectivelyEnabled =
          settings.notificationCenterSetting == .enabled ||
          settings.alertSetting == .enabled ||
          settings.badgeSetting == .enabled ||
          settings.soundSetting == .enabled
        status = effectivelyEnabled ? "authorized" : "denied"
      case .denied:
        status = "denied"
      case .notDetermined:
        status = "notDetermined"
      @unknown default:
        status = "restricted"
      }
      result(["status": status])
    }
  }

  /// 请求通知权限。macOS 上可能不弹系统对话框（取决于系统版本），
  /// 但 `requestAuthorization` 回调会反映最终授权状态。
  private func requestAuthorization(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { granted, error in
      if let error {
        result(FlutterError(
          code: "requestFailed",
          message: error.localizedDescription,
          details: nil
        ))
        return
      }
      result(["granted": granted])
    }
  }

  /// 打开系统设置中的通知页面（macOS 13+），旧版回退 URL。
  private func openSettings(result: @escaping FlutterResult) {
    let url: URL? =
      URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
      ?? URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
    guard let url else {
      result([:])
      return
    }
    NSWorkspace.shared.open(url)
    result([:])
  }
}
