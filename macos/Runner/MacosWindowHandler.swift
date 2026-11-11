import Cocoa
import FlutterMacOS

/// macOS 窗口控制桥接。
///
/// 当前只提供系统全屏切换，供视频随心听画面进入真正的 macOS 全屏空间。
final class MacosWindowHandler: NSObject {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var observers: [NSObjectProtocol] = []
  private var pendingTarget: Bool?
  private var pendingResult: FlutterResult?
  private var pendingTimeout: DispatchWorkItem?

  init(binaryMessenger: FlutterBinaryMessenger, window: NSWindow) {
    self.window = window
    channel = FlutterMethodChannel(
      name: "top.loop-back/window",
      binaryMessenger: binaryMessenger
    )
    super.init()
    channel.setMethodCallHandler(handle)
    observeFullscreenChanges(window)
  }

  deinit {
    pendingTimeout?.cancel()
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setFullscreen":
      guard
        let args = call.arguments as? [String: Any],
        let fullscreen = args["fullscreen"] as? Bool
      else {
        result(FlutterError(code: "bad_args", message: "missing fullscreen", details: nil))
        return
      }
      setFullscreen(fullscreen, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func setFullscreen(_ fullscreen: Bool, result: @escaping FlutterResult) {
    guard let window else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      let isFullscreen = window.styleMask.contains(.fullScreen)
      guard isFullscreen != fullscreen else {
        result(true)
        return
      }
      guard self.pendingResult == nil else {
        result(false)
        return
      }
      self.pendingTarget = fullscreen
      self.pendingResult = result
      let timeout = DispatchWorkItem { [weak self] in
        self?.completePendingRequest(success: false)
      }
      self.pendingTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
      window.toggleFullScreen(nil)
    }
  }

  private func observeFullscreenChanges(_ window: NSWindow) {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: NSWindow.didEnterFullScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        self?.publishFullscreenChange(true)
      }
    )
    observers.append(
      center.addObserver(
        forName: NSWindow.didExitFullScreenNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        self?.publishFullscreenChange(false)
      }
    )
  }

  private func publishFullscreenChange(_ fullscreen: Bool) {
    channel.invokeMethod("fullscreenChanged", arguments: fullscreen)
    let target = pendingTarget
    completePendingRequest(success: target == fullscreen)
  }

  private func completePendingRequest(success: Bool) {
    pendingTimeout?.cancel()
    pendingTimeout = nil
    pendingTarget = nil
    let result = pendingResult
    pendingResult = nil
    result?(success)
  }
}
