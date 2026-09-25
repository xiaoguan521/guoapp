import os
from pathlib import Path
import plistlib

from app_build import BuildVariant


def configure(path, dart_defines):
    variant = BuildVariant.from_dart_defines(dart_defines)
    data = plistlib.loads(path.read_bytes())
    data['CFBundleDisplayName'] = variant.name
    data['CFBundleName'] = variant.slug
    path.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY, sort_keys=False))


if __name__ == '__main__':
    configure(Path(os.environ['TARGET_BUILD_DIR']) / os.environ['INFOPLIST_PATH'],
              os.environ.get('DART_DEFINES', ''))
