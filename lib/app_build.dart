const allSourcesEnabled = bool.fromEnvironment('ALL_SOURCES');
const android6Compatibility = bool.fromEnvironment('ANDROID6_COMPAT');
const liveActivationCode = 'Shineyue';
const _compatibilitySuffix = android6Compatibility ? '兼容版' : '';
const appName = (allSourcesEnabled ? '真果鉴' : '红果鉴') + _compatibilitySuffix;
const appSlug = allSourcesEnabled ? 'zhenguojian' : 'hongguojian';

const updateMetadataUrl = String.fromEnvironment(
  'UPDATE_METADATA_URL',
  defaultValue:
      'https://api.github.com/repos/xiaoguan521/guoapp/releases?per_page=30',
);
const updateAllowedHosts = String.fromEnvironment(
  'UPDATE_ALLOWED_HOSTS',
  defaultValue:
      'api.github.com,github.com,release-assets.githubusercontent.com,objects.githubusercontent.com',
);
const updateDownloadPathPrefix = String.fromEnvironment(
  'UPDATE_DOWNLOAD_PATH_PREFIX',
  defaultValue: '/xiaoguan521/guoapp/releases/download/',
);
const updateReleasePage = String.fromEnvironment(
  'UPDATE_RELEASE_PAGE',
  defaultValue: 'https://github.com/xiaoguan521/guoapp/releases',
);

/// 全站源版可在完整模式与绿色模式之间切换，默认保持完整模式。
String appEditionName(bool fullMode) =>
    (allSourcesEnabled && fullMode ? '真果鉴' : '红果鉴') + _compatibilitySuffix;
