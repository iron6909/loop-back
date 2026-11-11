/// 通用网页词典视图。
///
/// WebView 始终挂载；在网页出现首个可见内容前由 Flutter 主题色遮罩覆盖，
/// 避免原生视图首次绘制时露出底色。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../services/app_logger.dart';
import '../../services/dictionary/web_dictionary_ad_block_rules.dart';
import '../../theme/app_theme.dart';
import 'web_dictionary_load_state.dart';

/// 用移动 Safari UA 让按 User-Agent 分流的词典站点返回移动版页面。
const _mobileSafariUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) '
    'Version/17.0 Mobile/15E148 Safari/604.1';

/// 收敛词典页常见页眉、页脚与 Cookie 提示；广告元素由专用规则隐藏。
const _defaultTidyCss = '''
  header, nav, .hfl-h, #onetrust-consent-sdk, .cookie-banner,
  .bb, .footer, footer { display: none !important; }
  body { padding-top: 0 !important; }
''';

/// 自动点击常见 Cookie 同意按钮，兼容 OneTrust 与通用接受按钮。
const _defaultAcceptCookieJs = '''
  (function() {
    var button = document.querySelector('#onetrust-accept-btn-handler')
      || document.querySelector('.cookie-accept');
    if (button) button.click();
  })();
''';

/// 在各平台内嵌网页词典，并管理首屏加载、失败与重试。
class WebDictionaryView extends StatefulWidget {
  /// 网页词典来源标识，用于诊断日志。
  final String sourceId;

  /// 待加载网页地址。
  final Uri url;

  /// 是否启用网页广告过滤。
  final bool adFilteringEnabled;

  /// 创建网页词典视图。
  const WebDictionaryView({
    super.key,
    required this.sourceId,
    required this.url,
    required this.adFilteringEnabled,
  });

  @override
  State<WebDictionaryView> createState() => _WebDictionaryViewState();
}

class _WebDictionaryViewState extends State<WebDictionaryView> {
  static const Duration _loadTimeout = Duration(seconds: 30);

  /// Apple 的 didCommit 早于首次绘制；等待视口出现内容并经过两次浏览器帧回调。
  static const String _firstVisibleContentScript = r'''
    const deadline = performance.now() + 25000;
    let foundVisibleContent = false;
    while (performance.now() < deadline) {
      const body = document.body;
      if (body) {
        const text = typeof body.innerText === 'string'
          ? body.innerText.trim()
          : '';
        const hasVisibleMedia = Array.from(
          body.querySelectorAll('img, svg, canvas, video, iframe')
        ).some((element) => {
          const style = window.getComputedStyle(element);
          const rect = element.getBoundingClientRect();
          return style.display !== 'none' &&
            style.visibility !== 'hidden' &&
            Number(style.opacity) > 0 &&
            rect.width > 0 &&
            rect.height > 0 &&
            rect.right > 0 &&
            rect.bottom > 0 &&
            rect.left < window.innerWidth &&
            rect.top < window.innerHeight;
        });
        if (text.length > 0 || hasVisibleMedia) {
          foundVisibleContent = true;
          break;
        }
      }
      await new Promise((resolve) => window.requestAnimationFrame(resolve));
    }

    if (!foundVisibleContent) return false;

    await new Promise((resolve) => window.requestAnimationFrame(() => {
      window.requestAnimationFrame(resolve);
    }));
    return true;
  ''';
  static const String _afterWebKitPaintScript = r'''
    await new Promise((resolve) => window.requestAnimationFrame(() => {
      window.requestAnimationFrame(resolve);
    }));
    return true;
  ''';
  String get _applyPageStylesScript {
    final adHidingCss = widget.adFilteringEnabled
        ? '\n$webDictionaryAdHidingCss'
        : '';
    return '''
    (() => {
      const styleId = '__loop_back_web_dictionary_styles__';
      if (document.getElementById(styleId)) return;
      const style = document.createElement('style');
      style.id = styleId;
      style.textContent = ${jsonEncode('$_defaultTidyCss$adHidingCss\n*::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }')};
      (document.head || document.documentElement)?.appendChild(style);
    })();
  ''';
  }

  late WebDictionaryLoadState _loadState;
  InAppWebViewController? _controller;
  Timer? _loadTimeoutTimer;

  bool get _webViewSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  @override
  void initState() {
    super.initState();
    _loadState = WebDictionaryLoadState.initial(widget.url.toString());
    _scheduleLoadTimeout(_loadState.generation);
  }

  @override
  void dispose() {
    _loadTimeoutTimer?.cancel();
    super.dispose();
  }

  /// 新导航开始后显示遮罩，并为这次导航重新计时。
  void _onLoadStart(WebUri? url) {
    if (!mounted) return;
    final nextState = _loadState.navigationStarted(url?.toString());
    AppLogger.log(
      'WebDictionary',
      'source=${widget.sourceId} load started '
          'generation=${nextState.generation} '
          'url=${url?.toString() ?? 'unknown'}',
    );
    _updateLoadState(nextState);
    _scheduleLoadTimeout(nextState.generation);
  }

  /// 等待 Apple WebKit 首次绘出实际内容；Android 直接使用可见提交回调。
  Future<void> _onPageCommitVisible(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    if (!mounted) return;
    if (!_loadState.isLoading) return;
    final generation = _loadState.generation;
    await _applyPageEnhancements(controller);
    if (!mounted ||
        !_loadState.isLoading ||
        _loadState.generation != generation) {
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      AppLogger.log(
        'WebDictionary',
        'source=${widget.sourceId} content visible via=page_commit '
            'generation=$generation '
            'url=${url?.toString() ?? 'unknown'} '
            'activeUrl=${_loadState.activeUrl ?? 'unknown'}',
      );
      _updateLoadState(_loadState.pageCommitted(url?.toString()));
      return;
    }

    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }

    AppLogger.log(
      'WebDictionary',
      'source=${widget.sourceId} page committed '
          'generation=$generation '
          'url=${url?.toString() ?? 'unknown'} '
          'activeUrl=${_loadState.activeUrl ?? 'unknown'}',
    );
    try {
      final result = await controller.callAsyncJavaScript(
        functionBody: _firstVisibleContentScript,
      );
      if (!mounted ||
          !_loadState.isLoading ||
          _loadState.generation != generation) {
        return;
      }
      if (result?.error != null) {
        AppLogger.log(
          'WebDictionary',
          'source=${widget.sourceId} first content check failed '
              'error=javascript',
        );
        return;
      }
      if (result?.value != true) return;
      AppLogger.log(
        'WebDictionary',
        'source=${widget.sourceId} content visible via=first_content '
            'generation=$generation '
            'url=${url?.toString() ?? 'unknown'} '
            'activeUrl=${_loadState.activeUrl ?? 'unknown'} '
            'callbackUrlMatchesActive=${_matchesActiveUrl(url)}',
      );
      // WebKit 提交回调可能使用重定向后的 URL；当前代际与页面内容均已验证，
      // 此处不再用完整 URL 字符串阻止本次导航结束加载。
      _updateLoadState(_loadState.pageCommitted(null));
    } catch (error) {
      if (!mounted ||
          !_loadState.isLoading ||
          _loadState.generation != generation) {
        return;
      }
      AppLogger.log(
        'WebDictionary',
        'source=${widget.sourceId} first content check failed '
            'error=${error.runtimeType}',
      );
      // JavaScript 检查失败时继续等待 onLoadStop 或超时兜底。
    }
  }

  /// 加载完成兜底；Apple 平台先让 WebKit 至少完成一次绘制机会。
  Future<void> _onLoadStop(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    if (!mounted) return;
    if (!_loadState.isLoading) return;
    final generation = _loadState.generation;
    AppLogger.log(
      'WebDictionary',
      'source=${widget.sourceId} load stopped generation=$generation '
          'url=${url?.toString() ?? 'unknown'} '
          'activeUrl=${_loadState.activeUrl ?? 'unknown'} '
          'callbackUrlMatchesActive=${_matchesActiveUrl(url)}',
    );
    await _applyPageEnhancements(controller);
    if (!mounted || _loadState.generation != generation) return;

    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      try {
        await controller.callAsyncJavaScript(
          functionBody: _afterWebKitPaintScript,
        );
      } catch (error) {
        AppLogger.log(
          'WebDictionary',
          'source=${widget.sourceId} final paint wait failed '
              'error=${error.runtimeType}',
        );
      }
      if (!mounted || _loadState.generation != generation) return;
    }

    final completionUrl =
        defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS
        ? null
        : url?.toString();
    // Apple 回调已通过当前代际和绘制机会校验，避免重定向 URL 与初始 URL
    // 的字符串差异让加载状态卡住。
    _updateLoadState(_loadState.loadStopped(completionUrl));
  }

  bool _matchesActiveUrl(WebUri? url) {
    final activeUrl = _loadState.activeUrl;
    return url == null || activeUrl == null || url.toString() == activeUrl;
  }

  /// 仅主框架错误会切换到可重试的错误界面。
  void _onReceivedError({
    required bool? isForMainFrame,
    required String url,
    required String errorType,
  }) {
    if (!mounted) return;
    AppLogger.log(
      'WebDictionary',
      'source=${widget.sourceId} request failed '
          'frame=${isForMainFrame == true ? 'main' : 'sub'} '
          'url=$url error=$errorType',
    );
    if (isForMainFrame != true) return;

    final nextState = _loadState.loadFailed(url);
    if (identical(nextState, _loadState)) return;

    _updateLoadState(nextState);
  }

  /// 仅记录 WebView 已加载的子资源 URL，便于识别跨域请求。
  void _onLoadResource(LoadedResource resource) {
    final url = resource.url?.toString();
    if (url == null || url.isEmpty) return;
    AppLogger.log('WebDictionary', url);
  }

  /// 注入页面清理样式并尝试接受 Cookie；网络广告请求另由平台规则拦截。
  Future<void> _applyPageEnhancements(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(source: _applyPageStylesScript);
    } catch (error) {
      AppLogger.log(
        'WebDictionary',
        'source=${widget.sourceId} page style injection failed '
            'error=${error.runtimeType}',
      );
    }
    try {
      await controller.evaluateJavascript(source: _defaultAcceptCookieJs);
    } catch (error) {
      AppLogger.log(
        'WebDictionary',
        'source=${widget.sourceId} cookie acceptance script failed '
            'error=${error.runtimeType}',
      );
    }
  }

  /// 超时后结束加载态，防止慢网络下动画无限显示。
  void _scheduleLoadTimeout(int generation) {
    if (!mounted) return;
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = Timer(_loadTimeout, () {
      if (!mounted) return;
      final nextState = _loadState.timedOut(generation);
      if (identical(nextState, _loadState)) return;

      AppLogger.log(
        'WebDictionary',
        'source=${widget.sourceId} load timed out generation=$generation '
            'activeUrl=${_loadState.activeUrl ?? 'unknown'}',
      );
      _updateLoadState(nextState);
    });
  }

  /// 应用状态变化，并在页面离开加载态时清理超时计时器。
  void _updateLoadState(WebDictionaryLoadState nextState) {
    if (!mounted) return;
    if (identical(nextState, _loadState)) return;
    final previousPhase = _loadState.phase;
    _loadState = nextState;
    if (!nextState.isLoading) _loadTimeoutTimer?.cancel();
    AppLogger.log(
      'WebDictionary',
      'source=${widget.sourceId} phase=${previousPhase.name}'
          '->${nextState.phase.name} generation=${nextState.generation}',
    );
    setState(() {});
  }

  /// 重载当前网页，并为重试建立新的加载代际。
  Future<void> _retry() async {
    final controller = _controller;
    if (controller == null) return;

    final retryState = _loadState.retryStarted();
    _updateLoadState(retryState);
    _scheduleLoadTimeout(retryState.generation);

    try {
      await controller.reload();
    } catch (error) {
      if (!mounted ||
          _loadState.generation != retryState.generation ||
          !_loadState.isLoading) {
        return;
      }
      AppLogger.log(
        'WebDictionary',
        'source=${widget.sourceId} reload failed '
            'error=${error.runtimeType}',
      );
      _updateLoadState(_loadState.loadFailed(_loadState.activeUrl));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_webViewSupported) return _unsupportedFallback(context);

    final theme = Theme.of(context);
    final backgroundColor = theme.colorScheme.surface;
    final l10n = AppLocalizations.of(context)!;
    final useOnLoadResource =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    final preferredContentMode = useOnLoadResource
        ? UserPreferredContentMode.MOBILE
        : null;
    final nativeScrollIndicatorSupported =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final underPageBackgroundColor =
        defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS
        ? backgroundColor
        : null;
    final contentBlockersSupported =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    final networkAdFilteringEnabled =
        widget.adFilteringEnabled && contentBlockersSupported;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: backgroundColor,
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url.toString())),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                cacheEnabled: true,
                transparentBackground: false,
                userAgent: _mobileSafariUserAgent,
                verticalScrollBarEnabled: nativeScrollIndicatorSupported
                    ? false
                    : null,
                useOnLoadResource: useOnLoadResource,
                preferredContentMode: preferredContentMode,
                underPageBackgroundColor: underPageBackgroundColor,
                contentBlockers: networkAdFilteringEnabled
                    ? webDictionaryCommonAdBlockers
                    : null,
              ),
              gestureRecognizers: {
                Factory<VerticalDragGestureRecognizer>(
                  VerticalDragGestureRecognizer.new,
                ),
              },
              onWebViewCreated: (controller) {
                _controller = controller;
                AppLogger.log(
                  'WebDictionary',
                  'source=${widget.sourceId} ad filters configured '
                      'enabled=${widget.adFilteringEnabled} '
                      'network=$networkAdFilteringEnabled '
                      'rules=${networkAdFilteringEnabled ? webDictionaryCommonAdBlockers.length : 0} '
                      'css=${widget.adFilteringEnabled}',
                );
              },
              onLoadStart: (_, url) => _onLoadStart(url),
              onPageCommitVisible: (controller, url) =>
                  _onPageCommitVisible(controller, url),
              onLoadStop: (controller, url) => _onLoadStop(controller, url),
              onLoadResource: (controller, resource) =>
                  _onLoadResource(resource),
              onReceivedError: (_, request, error) => _onReceivedError(
                isForMainFrame: request.isForMainFrame,
                url: request.url.toString(),
                errorType: error.type.toString(),
              ),
            ),
          ),
          if (_loadState.phase == WebDictionaryLoadPhase.loading)
            ColoredBox(
              color: backgroundColor,
              child: const Center(child: CircularProgressIndicator.adaptive()),
            ),
          if (_loadState.phase == WebDictionaryLoadPhase.error)
            ColoredBox(
              color: backgroundColor,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.m),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.aiLoadFailed,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s),
                      FilledButton.tonal(
                        onPressed: _retry,
                        child: Text(l10n.aiRetry),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _unsupportedFallback(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.l),
      child: Center(
        child: FilledButton.tonalIcon(
          onPressed: () =>
              launchUrl(widget.url, mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_browser),
          label: Text(l10n.dictCambridgeOpenInBrowser),
        ),
      ),
    );
  }
}
