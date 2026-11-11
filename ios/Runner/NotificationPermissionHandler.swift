import Flutter
import UIKit
import UserNotifications

/// 通知权限查询/请求/跳转设置的 iOS 原生桥接。
///
/// 直接读取 `UNAuthorizationStatus` 返回 authorized/denied/notDetermined，
/// 比 permission_handler 的同步 semaphore 方式更可靠。
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

  /// 查询通知授权状态，直接映射 `UNAuthorizationStatus`。
  private func getAuthorizationStatus(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let status: String
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        status = "authorized"
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

  /// 请求通知权限。
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

  /// 打开系统设置。
  private func openSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result([:])
      return
    }
    UIApplication.shared.open(url)
    result([:])
  }
}
