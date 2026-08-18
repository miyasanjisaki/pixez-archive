import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixez/custom_tab_plugin.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/utils/ascii2d_browser_search.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Browser fallback for images that cannot be resolved by local provenance or
/// direct reverse-image providers.
///
/// [sanitizedImageBytes] must already be stripped of metadata and reduced to a
/// suitable upload size. Android hands one app-private temporary file to
/// Ascii2D's normal HTML file chooser. JavaScript, cookies, and any challenge
/// pages remain under the site's control; this page does not issue a direct
/// POST or attempt to bypass a challenge.
class Ascii2dBrowserSearchPage extends StatefulWidget {
  final Uint8List sanitizedImageBytes;

  Ascii2dBrowserSearchPage({super.key, required Uint8List sanitizedImageBytes})
    : sanitizedImageBytes = Uint8List.fromList(sanitizedImageBytes);

  static Route<void> route({required Uint8List sanitizedImageBytes}) {
    return MaterialPageRoute<void>(
      builder: (_) =>
          Ascii2dBrowserSearchPage(sanitizedImageBytes: sanitizedImageBytes),
    );
  }

  @override
  State<Ascii2dBrowserSearchPage> createState() =>
      _Ascii2dBrowserSearchPageState();
}

class _Ascii2dBrowserSearchPageState extends State<Ascii2dBrowserSearchPage> {
  final Ascii2dUploadGate _uploadGate = Ascii2dUploadGate();
  late final WebViewController _controller;

  File? _temporaryUpload;
  Uri? _currentUri = Uri.parse(ascii2dOrigin);
  double _progress = 0;
  bool _fileBridgeReady = false;
  bool _imageHandedToPage = false;
  bool _automaticLoadAttempted = false;
  bool _automaticLoadInProgress = false;
  String? _preparationError;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress / 100);
          },
          onPageStarted: (url) {
            final uri = Uri.tryParse(url);
            if (!mounted) return;
            setState(() {
              _currentUri = uri;
              _progress = 0;
            });
          },
          onPageFinished: (url) {
            final uri = Uri.tryParse(url);
            if (!mounted) return;
            setState(() {
              _currentUri = uri;
              _progress = 1;
            });
            unawaited(_tryAutomaticImageLoad());
          },
          onNavigationRequest: _handleNavigation,
        ),
      )
      ..loadRequest(Uri.parse(ascii2dOrigin));
    unawaited(_installAndroidFileBridge());
  }

  Future<void> _installAndroidFileBridge() async {
    if (!Platform.isAndroid ||
        _controller.platform is! AndroidWebViewController) {
      return;
    }
    try {
      final androidController =
          _controller.platform as AndroidWebViewController;
      // Android R+ disables file:// access by default. This WebView is a
      // dedicated Ascii2D upload page and only exposes one randomly named,
      // metadata-free cache file after the user explicitly arms the chooser.
      await androidController.setAllowFileAccess(true);
      await androidController.setOnShowFileSelector((_) async {
        if (!_uploadGate.consume(pageUri: _currentUri, now: DateTime.now())) {
          return const <String>[];
        }
        final file = await _prepareTemporaryUpload();
        if (file == null) return const <String>[];
        if (mounted) {
          setState(() => _imageHandedToPage = true);
          _showMessage('图片已装入网页，请在 Ascii2D 页面点击「検索」');
        }
        return <String>[file.uri.toString()];
      });
      if (mounted) {
        setState(() => _fileBridgeReady = true);
        unawaited(_tryAutomaticImageLoad());
      }
    } catch (_) {
      // Keep the official page usable. On unsupported WebView builds the user
      // can still use its normal file chooser and reselect the image.
      if (mounted) setState(() => _fileBridgeReady = false);
    }
  }

  Future<File?> _prepareTemporaryUpload() async {
    if (_temporaryUpload case final file?) return file;
    final validation = validateAscii2dUpload(widget.sanitizedImageBytes);
    if (!validation.isValid) {
      if (mounted) {
        setState(() => _preparationError = validation.error);
        _showMessage(validation.error!);
      }
      return null;
    }
    try {
      final cache = await getTemporaryDirectory();
      final directory = Directory('${cache.path}/pixez-ascii2d');
      await directory.create(recursive: true);
      final file = File(
        '${directory.path}/upload-${DateTime.now().microsecondsSinceEpoch}.'
        '${validation.fileExtension}',
      );
      await file.writeAsBytes(widget.sanitizedImageBytes, flush: true);
      _temporaryUpload = file;
      return file;
    } catch (error) {
      if (mounted) {
        setState(() => _preparationError = '无法准备临时图片：$error');
        _showMessage(_preparationError!);
      }
      return null;
    }
  }

  NavigationDecision _handleNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    final artworkId = pixivArtworkIdFromUri(uri);
    if (artworkId != null) {
      unawaited(
        Leader.pushWithUri(
          context,
          Uri.parse('https://www.pixiv.net/artworks/$artworkId'),
        ),
      );
      return NavigationDecision.prevent;
    }
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return NavigationDecision.prevent;
    }
    if (isTrustedAscii2dUri(uri)) return NavigationDecision.navigate;
    unawaited(CustomTabPlugin.launch(uri.toString()));
    return NavigationDecision.prevent;
  }

  Future<void> _tryAutomaticImageLoad() async {
    if (!mounted ||
        _automaticLoadAttempted ||
        _automaticLoadInProgress ||
        !_fileBridgeReady ||
        _imageHandedToPage ||
        !isAscii2dUploadPageUri(_currentUri)) {
      return;
    }
    _automaticLoadAttempted = true;
    _automaticLoadInProgress = true;
    try {
      await _armAndOpenFileChooser(automatic: true);
    } finally {
      _automaticLoadInProgress = false;
    }
  }

  Future<void> _armAndOpenFileChooser({bool automatic = false}) async {
    if (!isTrustedAscii2dUri(_currentUri)) {
      if (!automatic) _showMessage('请先返回 Ascii2D 页面再上传');
      return;
    }
    final validation = validateAscii2dUpload(widget.sanitizedImageBytes);
    if (!validation.isValid) {
      setState(() => _preparationError = validation.error);
      _showMessage(validation.error!);
      return;
    }
    _uploadGate.arm(DateTime.now());
    if (!_fileBridgeReady) {
      if (!automatic) _showMessage('请在网页中点击「画像のパス」并重新选择图片');
      return;
    }
    try {
      final result = await _controller.runJavaScriptReturningResult('''
(() => {
  const form = document.querySelector('form[action="/search/file"]');
  const input = form && form.querySelector('input[type="file"]');
  if (!input) return 'missing';
  input.click();
  return 'opened';
})()
''');
      if (!automatic && '$result'.contains('missing')) {
        _showMessage(
          '网页尚无文件框：若正在验证请先正常完成；'
          '若在结果页请点右上角主页',
        );
      }
    } catch (_) {
      if (!automatic) {
        _showMessage('请在网页中点击文件选择框；不会绕过验证页');
      }
    }
  }

  Future<void> _switchMode(Ascii2dResultMode mode) async {
    final target = ascii2dResultModeUri(_currentUri, mode);
    if (target == null) {
      _showMessage('先提交图片得到结果，再切换色合/特征搜索');
      return;
    }
    await _controller.loadRequest(target);
  }

  Future<void> _loadHome() async {
    setState(() {
      _automaticLoadAttempted = false;
      _imageHandedToPage = false;
    });
    await _controller.loadRequest(Uri.parse(ascii2dOrigin));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _uploadGate.cancel();
    final temporaryUpload = _temporaryUpload;
    if (temporaryUpload != null) {
      unawaited(_deleteTemporaryUpload(temporaryUpload));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ascii2D识图'),
        actions: [
          IconButton(
            tooltip: '返回 Ascii2D 首页',
            onPressed: _loadHome,
            icon: const Icon(Icons.home_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _controller.reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_progress < 1) LinearProgressIndicator(value: _progress),
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '完整图先用色合；裁剪、局部图再用特征。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _armAndOpenFileChooser(),
                        icon: const Icon(Icons.upload_file),
                        label: Text(_imageHandedToPage ? '重新装入这张图' : '使用这张图'),
                      ),
                      OutlinedButton(
                        onPressed: () => _switchMode(Ascii2dResultMode.color),
                        child: const Text('色合搜索'),
                      ),
                      OutlinedButton(
                        onPressed: () => _switchMode(Ascii2dResultMode.feature),
                        child: const Text('特征搜索'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }

  Future<void> _deleteTemporaryUpload(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // App-private cache may already have been cleared by the OS.
    }
  }
}
