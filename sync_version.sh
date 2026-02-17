#!/bin/bash
# Read versionName from app.json5 and sync to all hardcoded locations

VERSION=$(grep -oP '"versionName":\s*"\K[^"]+' AppScope/app.json5)
if [ -z "$VERSION" ]; then
  echo "ERROR: Could not read versionName from AppScope/app.json5"
  exit 1
fi

echo "Syncing version: $VERSION"

# 1. ChatPage.ets - Text('vX.Y.Z')
sed -i "s/Text('v[0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\?')/Text('v${VERSION}')/" \
  entry/src/main/ets/pages/ChatPage.ets

# 2. NodeRuntime.ets - const APP_VERSION = 'X.Y.Z';
sed -i "s/const APP_VERSION = '[0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\?';/const APP_VERSION = '${VERSION}';/" \
  entry/src/main/ets/service/gateway/NodeRuntime.ets

# 3. SettingsPage.ets - InfoRow(...version..., 'X.Y.Z')
sed -i "s/this\.InfoRow(I18n\.t('settings\.version'), '[0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\?')/this.InfoRow(I18n.t('settings.version'), '${VERSION}')/" \
  entry/src/main/ets/pages/SettingsPage.ets

# 4. Index.ets - Text('vX.Y.Z')
sed -i "s/Text('v[0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\?')/Text('v${VERSION}')/" \
  entry/src/main/ets/pages/Index.ets

echo "Version synced to $VERSION in ChatPage, NodeRuntime, SettingsPage, Index"
