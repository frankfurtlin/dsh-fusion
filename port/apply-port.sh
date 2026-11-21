#!/usr/bin/env bash
# Applies the phone-bridge port (dsh-mobile -> dsh-Go fork) onto the app/android tree.
#
#   port/apply-port.sh            # idempotent: re-running changes nothing
#
# What it does:
#   1. copies port/staging/*.java          -> app/android/app/src/main/java/io/github/ccch1mneyyy/dsh_app/bridge/
#      copies port/staging/BridgePlugin.kt -> app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/bridge/
#   2. build.gradle.kts : adds OkHttp, retargets applicationId to the fork's own id
#   3. AndroidManifest.xml : declares the bridge service (+ FGS-connected-device permission)
#   4. MainActivity.kt : registers BridgePlugin on the engine it already builds
#
# Everything is marker-guarded; nothing here rewrites upstream code.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STAGE="$HERE/staging"
MAIN="$ROOT/app/android/app/src/main"
JAVA_DIR="$MAIN/java/io/github/ccch1mneyyy/dsh_app/bridge"
KT_DIR="$MAIN/kotlin/io/github/ccch1mneyyy/dsh_app/bridge"
GRADLE="$ROOT/app/android/app/build.gradle.kts"
MANIFEST="$MAIN/AndroidManifest.xml"
ACTIVITY="$MAIN/kotlin/io/github/ccch1mneyyy/dsh_app/MainActivity.kt"

FORK_APP_ID="${FORK_APP_ID:-top.frankfurtlin.dshfusion}"

mkdir -p "$JAVA_DIR" "$KT_DIR"
cp "$STAGE"/*.java "$JAVA_DIR"/
cp "$STAGE/BridgePlugin.kt" "$KT_DIR"/
echo "copied $(ls "$STAGE"/*.java | wc -l) java + BridgePlugin.kt"

python3 - "$GRADLE" "$MANIFEST" "$ACTIVITY" "$FORK_APP_ID" <<'PY'
import sys, re
gradle, manifest, activity, app_id = sys.argv[1:5]

# ---- build.gradle.kts ------------------------------------------------------
g = open(gradle).read()
if 'squareup.okhttp3' not in g:
    g = g.replace('''    implementation("androidx.webkit:webkit:1.15.0")''',
'''    implementation("androidx.webkit:webkit:1.15.0") // Apache-2.0: web islands' force dark (webview_flutter's own version)
    // Apache-2.0: the agent/phone bridge (ported from dsh-mobile) speaks WebSocket through OkHttp.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")''')
    assert 'squareup.okhttp3' in g, 'okhttp insert failed'
if f'applicationId = "{app_id}"' not in g:
    g, n = re.subn(r'applicationId = "[^"]*"', f'applicationId = "{app_id}"', g, count=1)
    assert n == 1, 'applicationId not found'
open(gradle, 'w').write(g)

# ---- AndroidManifest.xml ---------------------------------------------------
m = open(manifest).read()
if 'FOREGROUND_SERVICE_CONNECTED_DEVICE' not in m:
    m = m.replace('''    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />''',
'''    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />''')
    assert 'FOREGROUND_SERVICE_CONNECTED_DEVICE' in m
if '.bridge.A11yService' not in m:
    entry = '''        <!-- Agent/phone bridge accessibility: answers the bridge's a11y.* ops (bridge/A11yService.java).
             Separate from phone.a11y.PhoneA11yService, which belongs to the local engine's tool set. -->
        <service
            android:name=".bridge.A11yService"
            android:label="@string/bridge_a11y_label"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE"
            android:exported="true">
            <intent-filter>
                <action android:name="android.accessibilityservice.AccessibilityService" />
            </intent-filter>
            <meta-data
                android:name="android.accessibilityservice"
                android:resource="@xml/bridge_a11y_service" />
        </service>

        <!-- Agent/phone bridge: keeps the WSS to the public bridge origin alive (bridge/BridgeService.java). -->'''
    m = m.replace('''        <!-- Agent/phone bridge: keeps the WSS to the public bridge origin alive (bridge/BridgeService.java). -->''', entry, 1)
    assert '.bridge.A11yService' in m
if '.bridge.BridgeService' not in m:
    entry = '''        <!-- Agent/phone bridge: keeps the WSS to the public bridge origin alive (bridge/BridgeService.java). -->
        <service
            android:name=".bridge.BridgeService"
            android:exported="false"
            android:foregroundServiceType="connectedDevice" />

        <!-- Keeps the local DSH process alive while the app is in the background. -->'''
    m = m.replace('        <!-- Keeps the local DSH process alive while the app is in the background. -->', entry, 1)
    assert '.bridge.BridgeService' in m
open(manifest, 'w').write(m)

# ---- MainActivity.kt -------------------------------------------------------
a = open(activity).read()
if 'bridge.BridgePlugin()' not in a:
    a = a.replace('''            engine.plugins.add(LinksPlugin())''',
'''            engine.plugins.add(LinksPlugin())
            engine.plugins.add(io.github.ccch1mneyyy.dsh_app.bridge.BridgePlugin())''', 1)
    assert 'bridge.BridgePlugin()' in a
open(activity, 'w').write(a)
print('gradle/manifest/MainActivity patched')
PY

echo "apply-port: ok (appId=$FORK_APP_ID)"
