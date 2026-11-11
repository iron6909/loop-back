import AVFoundation
import FlutterMacOS

/// macOS 原生 TTS「合成到文件」handler。
///
/// 绕过 flutter_tts 4.2.5 macOS 端的缺陷：其 `synthesizeToFile` 创建 utterance 后
/// **从不设 voice/language**（见 CLAUDE.md §7.15/§7.20），产物永远是系统默认音色、
/// 区分不出英/美音。本 handler 用 `AVSpeechSynthesizer.write` 自行合成，合成前正确
/// 设 `utterance.voice = AVSpeechSynthesisVoice(language:)`，按 PCM buffer 写出 wav
/// 文件到调用方给定的**绝对路径**，使 macOS 平台 TTS 也能像 iOS/Android 一样缓存、
/// 且口音正确。
///
/// 通道：`top.loop-back/tts_synth`，方法 `synthesizeToFile`。
/// 入参：text / filePath(绝对) / languageTag / rate / pitch / volume。
/// 返回：成功产出非空文件 → true；否则 false / FlutterError。
final class MacosTtsSynthHandler: NSObject {
  private let channel: FlutterMethodChannel

  /// 当前在途合成的 synthesizer / 完成回调 / 输出文件。合成期间强引用保活，
  /// 回调到达前不被释放；完成后清空（见 [finish]）。
  private var synthesizer: AVSpeechSynthesizer?
  private var pendingResult: FlutterResult?
  private var output: AVAudioFile?
  private var writeFailed = false

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "top.loop-back/tts_synth",
      binaryMessenger: binaryMessenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "synthesizeToFile" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let text = args["text"] as? String,
      let filePath = args["filePath"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "missing text/filePath", details: nil))
      return
    }
    let language = (args["languageTag"] as? String) ?? "en-US"
    let rate = (args["rate"] as? NSNumber)?.floatValue ?? AVSpeechUtteranceDefaultSpeechRate
    let pitch = (args["pitch"] as? NSNumber)?.floatValue ?? 1.0
    let volume = (args["volume"] as? NSNumber)?.floatValue ?? 1.0

    guard #available(macOS 10.15, *) else {
      result(FlutterError(code: "unsupported", message: "requires macOS 10.15+", details: nil))
      return
    }
    // 协调器侧本就串行合成；若仍有在途任务直接判忙（防御，不打断已在途的）。
    if pendingResult != nil {
      result(FlutterError(code: "busy", message: "synthesis in progress", details: nil))
      return
    }
    synthesize(
      text: text, filePath: filePath, language: language,
      rate: rate, pitch: pitch, volume: volume, result: result
    )
  }

  @available(macOS 10.15, *)
  private func synthesize(
    text: String, filePath: String, language: String,
    rate: Float, pitch: Float, volume: Float, result: @escaping FlutterResult
  ) {
    let utterance = AVSpeechUtterance(string: text)
    // 关键：正确设 voice（flutter_tts macOS 漏设的就是这一步）。voice 为 nil（系统
    // 未装该语言音色）时 AVFoundation 自行回退默认，不崩。
    utterance.voice = AVSpeechSynthesisVoice(language: language)
    utterance.rate = rate
    utterance.pitchMultiplier = pitch
    utterance.volume = volume

    let synth = AVSpeechSynthesizer()
    synthesizer = synth
    pendingResult = result
    output = nil
    writeFailed = false
    let fileURL = URL(fileURLWithPath: filePath)

    synth.write(utterance) { [weak self] (buffer: AVAudioBuffer) in
      guard let self = self else { return }
      guard let pcm = buffer as? AVAudioPCMBuffer else {
        self.writeFailed = true
        return
      }
      if pcm.frameLength == 0 {
        // 末尾空 buffer = 合成结束：关闭文件后回报结果（成功 = 无写错且确有产物）。
        self.finish(success: !self.writeFailed && self.output != nil)
        return
      }
      do {
        if self.output == nil {
          self.output = try AVAudioFile(
            forWriting: fileURL,
            settings: pcm.format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
          )
        }
        try self.output?.write(from: pcm)
      } catch {
        NSLog("MacosTtsSynthHandler write error: \(error.localizedDescription)")
        self.writeFailed = true
      }
    }
  }

  /// 收尾：先关闭文件（output 置 nil 触发 AVAudioFile flush/close），再在主线程回报
  /// 结果，最后清理在途引用。FlutterResult 必须在主线程调用。
  private func finish(success: Bool) {
    output = nil // 关闭文件，确保 Dart 读取时已写完落盘
    let r = pendingResult
    pendingResult = nil
    synthesizer = nil
    writeFailed = false
    DispatchQueue.main.async { r?(success) }
  }
}
