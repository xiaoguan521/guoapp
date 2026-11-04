import 'package:duanju_app/app_build.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default metadata URL points to GitHub Releases API', () {
    expect(
      updateMetadataUrl,
      'https://api.github.com/repos/xiaoguan521/guoapp/releases?per_page=30',
    );
    final uri = Uri.parse(updateMetadataUrl);
    expect(uri.scheme, 'https');
    expect(uri.host, 'api.github.com');
  });

  test('default allowed hosts contain all GitHub download domains', () {
    final hosts = updateAllowedHosts
        .split(',')
        .map((h) => h.trim())
        .where((h) => h.isNotEmpty)
        .toSet();
    expect(hosts, contains('api.github.com'));
    expect(hosts, contains('github.com'));
    expect(hosts, contains('release-assets.githubusercontent.com'));
    expect(hosts, contains('objects.githubusercontent.com'));
    expect(hosts, hasLength(4));
  });

  test('default download path prefix matches GitHub releases', () {
    expect(updateDownloadPathPrefix, '/xiaoguan521/guoapp/releases/download/');
  });

  test('default release page points to GitHub releases', () {
    expect(updateReleasePage, 'https://github.com/xiaoguan521/guoapp/releases');
    final uri = Uri.parse(updateReleasePage);
    expect(uri.scheme, 'https');
    expect(uri.host, 'github.com');
  });

  group('trusted URL validation', () {
    bool trusted(
      Uri uri, {
      bool metadata = false,
      String metadataUrl = '',
      String allowedHosts = '',
      String pathPrefix = '',
    }) {
      if (metadataUrl.isEmpty) metadataUrl = updateMetadataUrl;
      if (allowedHosts.isEmpty) allowedHosts = updateAllowedHosts;
      if (pathPrefix.isEmpty) pathPrefix = updateDownloadPathPrefix;

      if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.port != 443)
        return false;
      final allowed = allowedHosts
          .split(',')
          .map((h) => h.trim())
          .where((h) => h.isNotEmpty)
          .toSet();
      final metadataHost = Uri.tryParse(metadataUrl)?.host ?? '';
      if (metadata) {
        return uri.host == metadataHost && allowed.contains(uri.host);
      }
      if (!allowed.contains(uri.host)) return false;
      if (pathPrefix.isNotEmpty) {
        if (uri.path.startsWith(pathPrefix)) return true;
        if (uri.host == metadataHost) return false;
      }
      return true;
    }

    test('default config: metadata URL accepted', () {
      expect(trusted(Uri.parse(updateMetadataUrl), metadata: true), isTrue);
    });

    test('default config: metadata host rejected for download', () {
      expect(
        trusted(
          Uri.parse('https://api.github.com/repos/xiaoguan521/guoapp/other'),
        ),
        isFalse,
      );
    });

    test('default config: GitHub download URL accepted', () {
      expect(
        trusted(
          Uri.parse(
            'https://github.com/xiaoguan521/guoapp/releases/download/v1.0/app.apk',
          ),
        ),
        isTrue,
      );
    });

    test(
      'default config: GitHub non-download path accepted as whitelisted',
      () {
        expect(trusted(Uri.parse('https://github.com/other/repo')), isTrue);
      },
    );

    test('default config: redirect hosts accepted', () {
      expect(
        trusted(
          Uri.parse('https://release-assets.githubusercontent.com/some/path'),
        ),
        isTrue,
      );
      expect(
        trusted(Uri.parse('https://objects.githubusercontent.com/some/path')),
        isTrue,
      );
    });

    test('default config: unknown host rejected', () {
      expect(trusted(Uri.parse('https://evil.com/something')), isFalse);
    });

    test('default config: HTTP rejected', () {
      expect(
        trusted(Uri.parse('http://github.com/xiaoguan521/guoapp/releases')),
        isFalse,
      );
    });

    test('default config: non-443 port rejected', () {
      expect(trusted(Uri.parse('https://github.com:8443/path')), isFalse);
    });

    test('default config: userInfo rejected', () {
      expect(trusted(Uri.parse('https://user@github.com/path')), isFalse);
    });

    test('CNB config: metadata URL accepted', () {
      const cnbMeta =
          'https://cnb.cool/201807xyz/guoapp/-/git/raw/update-dist/update/releases.json';
      const cnbHosts = 'cnb.cool';
      const cnbPrefix = '/201807xyz/guoapp/-/git/raw/update-dist/';

      expect(
        trusted(
          Uri.parse(cnbMeta),
          metadata: true,
          metadataUrl: cnbMeta,
          allowedHosts: cnbHosts,
          pathPrefix: cnbPrefix,
        ),
        isTrue,
      );
    });

    test('CNB config: download with matching path accepted', () {
      const cnbMeta =
          'https://cnb.cool/201807xyz/guoapp/-/git/raw/update-dist/update/releases.json';
      const cnbHosts = 'cnb.cool';
      const cnbPrefix = '/201807xyz/guoapp/-/git/raw/update-dist/';

      expect(
        trusted(
          Uri.parse(
            'https://cnb.cool/201807xyz/guoapp/-/git/raw/update-dist/hongguojian-0.2.164+2177-arm64-v8a.apk',
          ),
          metadataUrl: cnbMeta,
          allowedHosts: cnbHosts,
          pathPrefix: cnbPrefix,
        ),
        isTrue,
      );
    });

    test('CNB config: wrong path on metadata host rejected', () {
      const cnbMeta =
          'https://cnb.cool/201807xyz/guoapp/-/git/raw/update-dist/update/releases.json';
      const cnbHosts = 'cnb.cool';
      const cnbPrefix = '/201807xyz/guoapp/-/git/raw/update-dist/';

      expect(
        trusted(
          Uri.parse('https://cnb.cool/other/path'),
          metadataUrl: cnbMeta,
          allowedHosts: cnbHosts,
          pathPrefix: cnbPrefix,
        ),
        isFalse,
      );
    });

    test('CNB config: GitHub host rejected', () {
      const cnbMeta =
          'https://cnb.cool/201807xyz/guoapp/-/git/raw/update-dist/update/releases.json';
      const cnbHosts = 'cnb.cool';
      const cnbPrefix = '/201807xyz/guoapp/-/git/raw/update-dist/';

      expect(
        trusted(
          Uri.parse(
            'https://github.com/xiaoguan521/guoapp/releases/download/v1/a.apk',
          ),
          metadataUrl: cnbMeta,
          allowedHosts: cnbHosts,
          pathPrefix: cnbPrefix,
        ),
        isFalse,
      );
    });

    test('CNB config with redirect host: redirect accepted', () {
      const cnbMeta =
          'https://cnb.cool/201807xyz/guoapp/-/git/raw/update-dist/update/releases.json';
      const cnbHosts = 'cnb.cool,cdn.cnb.cool';
      const cnbPrefix = '/201807xyz/guoapp/-/git/raw/update-dist/';

      expect(
        trusted(
          Uri.parse('https://cdn.cnb.cool/some/asset/path'),
          metadataUrl: cnbMeta,
          allowedHosts: cnbHosts,
          pathPrefix: cnbPrefix,
        ),
        isTrue,
      );
    });
  });
}
