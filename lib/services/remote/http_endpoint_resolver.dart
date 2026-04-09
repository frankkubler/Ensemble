import '../../constants/network.dart';

class HttpEndpointResolver {
  const HttpEndpointResolver({
    required this.serverUrl,
    this.customPort,
  });

  static const String webRtcBootstrapHost = 'remote.music-assistant.invalid';

  final String? serverUrl;
  final int? customPort;

  bool get hasResolvableBaseUrl => buildBaseUri() != null;

  Uri? buildBaseUri() {
    final rawServerUrl = serverUrl?.trim();
    if (rawServerUrl == null || rawServerUrl.isEmpty) {
      return null;
    }

    var normalizedUrl = rawServerUrl;
    var useSecure = true;

    if (!normalizedUrl.startsWith('http://') &&
        !normalizedUrl.startsWith('https://')) {
      if (normalizedUrl.startsWith('wss://')) {
        normalizedUrl = 'https://${normalizedUrl.substring(6)}';
        useSecure = true;
      } else if (normalizedUrl.startsWith('ws://')) {
        normalizedUrl = 'http://${normalizedUrl.substring(5)}';
        useSecure = false;
      } else {
        normalizedUrl = 'https://$normalizedUrl';
        useSecure = true;
      }
    } else {
      useSecure = normalizedUrl.startsWith('https://');
    }

    final uri = Uri.parse(normalizedUrl);
    if (_isPlaceholderHost(uri.host)) {
      return null;
    }

    if (customPort != null) {
      return Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: customPort,
      );
    }

    if (_hasExplicitPort(rawServerUrl)) {
      return Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.port,
      );
    }

    if (useSecure) {
      return Uri(
        scheme: uri.scheme,
        host: uri.host,
      );
    }

    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: NetworkConstants.defaultWsPort,
    );
  }

  String? buildAbsoluteUrl(String? pathOrUrl) {
    if (pathOrUrl == null || pathOrUrl.isEmpty) {
      return null;
    }

    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      return pathOrUrl;
    }

    final baseUri = buildBaseUri();
    if (baseUri == null) {
      return null;
    }

    final path = pathOrUrl.startsWith('/') ? pathOrUrl : '/$pathOrUrl';
    return baseUri.replace(path: path).toString();
  }

  String? buildFlowUrl(String playerId, String streamId, String extension) {
    final baseUri = buildBaseUri();
    if (baseUri == null) {
      return null;
    }

    return baseUri
        .replace(path: '/flow/$playerId/$streamId.$extension')
        .toString();
  }

  String? buildPreviewUrl({
    required String provider,
    required String itemId,
  }) {
    final baseUri = buildBaseUri();
    if (baseUri == null) {
      return null;
    }

    return baseUri.replace(
      path: '/preview',
      queryParameters: {
        'item_id': itemId,
        'provider': provider,
      },
    ).toString();
  }

  String? buildImageProxyUrl({
    required String imagePath,
    String? provider,
    int size = 256,
    String format = 'jpeg',
  }) {
    final baseUri = buildBaseUri();
    if (baseUri == null) {
      // If imagePath is already an absolute URL (e.g. Spotify CDN, Last.fm)
      // return it directly — skips the proxy but at least shows the image.
      if (imagePath.startsWith('http://') || imagePath.startsWith('https://')) {
        return imagePath;
      }
      return null;
    }

    return baseUri.replace(
      path: '/imageproxy',
      queryParameters: {
        'provider': provider ?? '',
        'size': '$size',
        'fmt': format,
        'path': imagePath,
      },
    ).toString();
  }

  String? rebuildImageProxyUrl(String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty) {
      return null;
    }

    final baseUri = buildBaseUri();
    if (baseUri == null) {
      return imageUrl;
    }

    try {
      final imageUri = Uri.parse(imageUrl);
      if (imageUri.query.isEmpty) {
        return imageUrl;
      }

      return baseUri.replace(
        path: '/imageproxy',
        query: imageUri.query,
      ).toString();
    } catch (_) {
      return imageUrl;
    }
  }

  String? buildSendspinWebSocketUrl() {
    final rawServerUrl = serverUrl?.trim();
    if (rawServerUrl == null || rawServerUrl.isEmpty) {
      return null;
    }

    var url = rawServerUrl;

    if (url.startsWith('https://')) {
      url = 'wss://${url.substring(8)}';
    } else if (url.startsWith('http://')) {
      url = 'ws://${url.substring(7)}';
    } else if (!url.startsWith('ws://') && !url.startsWith('wss://')) {
      url = 'wss://$url';
    }

    final uri = Uri.parse(url.replaceAll(RegExp(r'/+$'), ''));
    if (_isPlaceholderHost(uri.host)) {
      return null;
    }

    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '/sendspin',
    ).toString();
  }

  bool _hasExplicitPort(String url) {
    final withoutScheme = url.replaceFirst(RegExp(r'^(https?|wss?)://'), '');
    return RegExp(r'^[^/:]+:\d+').hasMatch(withoutScheme);
  }

  bool _isPlaceholderHost(String host) {
    return host.isEmpty || host == webRtcBootstrapHost || host.endsWith('.invalid');
  }
}