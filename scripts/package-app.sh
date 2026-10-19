#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
if [ "${MUSE_PACKAGE_TEST_MODE:-0}" = "1" ]; then
    [ -n "${MUSE_PACKAGE_PROJECT_DIR:-}" ] || {
        echo "MUSE_PACKAGE_PROJECT_DIR is required in package test mode" >&2
        exit 1
    }
    PROJECT_DIR="$(cd "$MUSE_PACKAGE_PROJECT_DIR" && /bin/pwd -P)"
else
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"
fi

PACKAGING_SOURCE_COMMIT=""
PACKAGING_SOURCE_TREE=""
if [ "${MUSE_PACKAGE_TEST_MODE:-0}" != "1" ]; then
    if [ -n "${MUSE_SOURCE_COMMIT:-}" ]; then
        echo "MUSE_SOURCE_COMMIT cannot override provenance outside package test mode" >&2
        exit 1
    fi
    if [ -n "${MUSE_SOURCE_TREE:-}" ]; then
        echo "MUSE_SOURCE_TREE cannot override provenance outside package test mode" >&2
        exit 1
    fi
    git -C "$PROJECT_DIR" rev-parse --verify HEAD >/dev/null 2>&1 || {
        echo "Unable to determine Muse source commit for packaged artifact" >&2
        exit 1
    }
    if ! git -C "$PROJECT_DIR" diff --quiet -- \
        || ! git -C "$PROJECT_DIR" diff --cached --quiet --; then
        echo "Refusing to package a tracked dirty worktree; commit the exact candidate source first" >&2
        exit 1
    fi
    UNTRACKED_BUILD_INPUTS="$(git -C "$PROJECT_DIR" ls-files --others --exclude-standard -- \
        Muse Frameworks Package.swift Package.resolved)"
    if [ -n "$UNTRACKED_BUILD_INPUTS" ]; then
        echo "Refusing to package untracked build inputs; commit the exact candidate source first" >&2
        exit 1
    fi
    PACKAGING_SOURCE_COMMIT="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
    PACKAGING_SOURCE_TREE="$(git -C "$PROJECT_DIR" rev-parse 'HEAD^{tree}')"
fi
APP_PATH="${APP_PATH:-$PROJECT_DIR/dist/Muse.app}"
QUALITY_BUILD_MANIFEST_PATH="${MUSE_QUALITY_BUILD_MANIFEST_PATH:-}"
QUALITY_DATASET_PATH=""
QUALITY_PROFILE="${MUSE_QUALITY_PROFILE:-legacy}"
QUALITY_CONTRACT_PATH=""
if [ -n "$QUALITY_BUILD_MANIFEST_PATH" ]; then
    case "$QUALITY_PROFILE" in
        legacy|three_mode) ;;
        *) echo "MUSE_QUALITY_PROFILE must be legacy or three_mode" >&2; exit 1 ;;
    esac
    case "$QUALITY_BUILD_MANIFEST_PATH" in
        /*) ;;
        *) echo "MUSE_QUALITY_BUILD_MANIFEST_PATH must be an absolute path" >&2; exit 1 ;;
    esac
    if [ -e "$QUALITY_BUILD_MANIFEST_PATH" ] || [ -L "$QUALITY_BUILD_MANIFEST_PATH" ]; then
        echo "Quality build manifest path must not already exist" >&2
        exit 1
    fi
    case "$QUALITY_BUILD_MANIFEST_PATH" in
        "$APP_PATH"|"$APP_PATH"/*)
            echo "Quality build manifest must be stored outside the signed app bundle" >&2
            exit 1
            ;;
    esac
    /bin/mkdir -p "$(/usr/bin/dirname "$QUALITY_BUILD_MANIFEST_PATH")"

    if [ "${MUSE_PACKAGE_TEST_MODE:-0}" = "1" ]; then
        QUALITY_DATASET_PATH="${MUSE_QUALITY_DATASET_PATH:-}"
        [ -n "$QUALITY_DATASET_PATH" ] || {
            echo "MUSE_QUALITY_DATASET_PATH is required for a quality manifest in package test mode" >&2
            exit 1
        }
    else
        if [ -n "${MUSE_QUALITY_DATASET_PATH:-}" ]; then
            echo "MUSE_QUALITY_DATASET_PATH cannot override the frozen production dataset" >&2
            exit 1
        fi
        if [ "$QUALITY_PROFILE" = "three_mode" ]; then
            QUALITY_DATASET_PATH="$PROJECT_DIR/docs/2026-09-10-Muse-Three-Mode-Quality-Test-Set.json"
        else
            QUALITY_DATASET_PATH="$PROJECT_DIR/docs/2026-08-17-Muse-Voice-Polish-Quality-Test-Set.json"
        fi
    fi
    case "$QUALITY_DATASET_PATH" in
        /*) ;;
        *) echo "Quality dataset path must be absolute" >&2; exit 1 ;;
    esac
    if [ ! -f "$QUALITY_DATASET_PATH" ] || [ -L "$QUALITY_DATASET_PATH" ]; then
        echo "Quality dataset must be an existing regular non-symlink file: $QUALITY_DATASET_PATH" >&2
        exit 1
    fi
    if [ "$QUALITY_PROFILE" = "three_mode" ]; then
        if [ "${MUSE_PACKAGE_TEST_MODE:-0}" = "1" ]; then
            QUALITY_CONTRACT_PATH="${MUSE_QUALITY_CONTRACT_PATH:-}"
        else
            if [ -n "${MUSE_QUALITY_CONTRACT_PATH:-}" ]; then
                echo "MUSE_QUALITY_CONTRACT_PATH cannot override frozen production contracts" >&2
                exit 1
            fi
            QUALITY_CONTRACT_PATH="$PROJECT_DIR/docs/2026-09-10-Muse-Three-Mode-Quality-Contracts.json"
        fi
        case "$QUALITY_CONTRACT_PATH" in
            /*) ;;
            *) echo "Three-mode scoring contracts must use an absolute path" >&2; exit 1 ;;
        esac
        if [ ! -f "$QUALITY_CONTRACT_PATH" ] || [ -L "$QUALITY_CONTRACT_PATH" ]; then
            echo "Three-mode scoring contracts must be a regular non-symlink file" >&2
            exit 1
        fi
    fi
fi
APP_NAME="${APP_NAME:-Muse}"
APP_EXECUTABLE="Muse"
APP_ICON_NAME="AppIcon"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-pro.daliang.muse}"
APP_URL_SCHEME="muse"
if [ "$APP_BUNDLE_ID" = "pro.daliang.muse.interactive-test" ]; then
    APP_URL_SCHEME="muse-interactive-test"
fi
APP_VERSION="${APP_VERSION:-2.1.2}"
APP_BUILD="${APP_BUILD:-1}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
MICROPHONE_USAGE_DESCRIPTION="${MICROPHONE_USAGE_DESCRIPTION:-Muse 需要访问麦克风以录制语音并将其转换为文本。}"
SPEECH_RECOGNITION_USAGE_DESCRIPTION="${SPEECH_RECOGNITION_USAGE_DESCRIPTION:-Muse 需要语音识别权限以将你的语音转写为文字。}"
APPLE_EVENTS_USAGE_DESCRIPTION="${APPLE_EVENTS_USAGE_DESCRIPTION:-Muse 需要辅助功能权限来注入转写文字到其他应用}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
SENSEVOICE_DIST="$PROJECT_DIR/sensevoice-server/dist/sensevoice-server"
QWEN3_DIST="$PROJECT_DIR/qwen3-asr-server/dist/qwen3-asr-server"

# Local packaging must fail before building or replacing an existing Bundle when
# either frozen service distribution is unavailable.
if [ "${BUNDLE_LOCAL_ASR:-0}" = "1" ] \
    && { [ ! -d "$SENSEVOICE_DIST" ] || [ ! -d "$QWEN3_DIST" ]; }; then
    echo "Local bundle requested, but both frozen service distributions are required." >&2
    exit 1
fi
if [ "${BUNDLE_LOCAL_ASR:-0}" = "1" ] \
    && { [ ! -f "$SENSEVOICE_DIST/sensevoice-server" ] \
        || [ ! -x "$SENSEVOICE_DIST/sensevoice-server" ] \
        || [ ! -f "$QWEN3_DIST/qwen3-asr-server" ] \
        || [ ! -x "$QWEN3_DIST/qwen3-asr-server" ]; }; then
    echo "Local bundle requested, but both frozen service launchers are required and must be executable." >&2
    exit 1
fi

trash_path() {
    local path="$1"
    [ -e "$path" ] || return 0

    local base stamp target
    base="$(basename "$path")"
    stamp="$(date +%Y%m%d-%H%M%S)"
    target="$HOME/.Trash/${base}-${stamp}"
    while [ -e "$target" ]; do
        stamp="$(date +%Y%m%d-%H%M%S)-$RANDOM"
        target="$HOME/.Trash/${base}-${stamp}"
    done
    /bin/mv "$path" "$target"
}

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    SIGNING_IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Muse Dev"; then
    SIGNING_IDENTITY="Muse Dev"
elif [ -d "$APP_PATH" ] && codesign -dv "$APP_PATH" 2>/dev/null; then
    # Existing app is already signed -- reuse its identity to preserve Accessibility permission.
    # Changing signing identity invalidates macOS TCC entries (Accessibility, etc).
    EXISTING_AUTHORITY=$(codesign -dvvv "$APP_PATH" 2>&1 | grep "^Authority=" | head -1 | cut -d= -f2)
    if [ -n "$EXISTING_AUTHORITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "$EXISTING_AUTHORITY"; then
        SIGNING_IDENTITY="$EXISTING_AUTHORITY"
        echo "Reusing existing signing identity: $SIGNING_IDENTITY"
    else
        # Existing app was ad-hoc signed or cert is gone -- keep ad-hoc to not break permission
        SIGNING_IDENTITY="-"
    fi
else
    # Fresh install, no existing app. Default to ad-hoc signing. Creating and trusting
    # a local certificate modifies the user's login keychain, so it is opt-in.
    CERT_NAME="Muse Local"
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
        if [ "${ALLOW_LOCAL_CERT_BOOTSTRAP:-0}" != "1" ]; then
            echo "No code signing identity found; using ad-hoc signing."
            echo "Set ALLOW_LOCAL_CERT_BOOTSTRAP=1 to create a persistent local signing certificate."
            SIGNING_IDENTITY="-"
        else
            echo "Creating self-signed certificate '$CERT_NAME' for consistent code signing..."
            echo "This opt-in operation updates the login keychain trust settings."
            CERT_TEMP=$(mktemp -d)
            CERT_PASSWORD="$(openssl rand -hex 16)"
            cat > "$CERT_TEMP/cert.cfg" <<CERTEOF
[ req ]
distinguished_name = req_dn
[ req_dn ]
CN = $CERT_NAME
[ extensions ]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
CERTEOF
            openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout "$CERT_TEMP/key.pem" -out "$CERT_TEMP/cert.pem" \
                -days 3650 -subj "/CN=$CERT_NAME" -extensions extensions \
                -config "$CERT_TEMP/cert.cfg" 2>/dev/null
            # -legacy + 非空密码：openssl 3.x 默认 p12 加密 security import 不识别，
            # 会只导入证书、丢私钥 → codesign 退回 ad-hoc（CDHash 每次变、辅助功能授权反复失效）。
            # -A 让 codesign 可无授权框访问私钥。（2026-06-22 修复）
            openssl pkcs12 -export -legacy -out "$CERT_TEMP/cert.p12" \
                -inkey "$CERT_TEMP/key.pem" -in "$CERT_TEMP/cert.pem" \
                -name "$CERT_NAME" -passout "pass:$CERT_PASSWORD" 2>/dev/null
            security import "$CERT_TEMP/cert.p12" -k ~/Library/Keychains/login.keychain-db \
                -T /usr/bin/codesign -A -P "$CERT_PASSWORD" 2>/dev/null || \
            security import "$CERT_TEMP/cert.p12" -k ~/Library/Keychains/login.keychain \
                -T /usr/bin/codesign -A -P "$CERT_PASSWORD" 2>/dev/null || true
            security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db \
                "$CERT_TEMP/cert.pem" 2>/dev/null || \
            security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain \
                "$CERT_TEMP/cert.pem" 2>/dev/null || true
            trash_path "$CERT_TEMP"
            echo "Certificate '$CERT_NAME' created and trusted."
            SIGNING_IDENTITY="$CERT_NAME"
        fi
    else
        SIGNING_IDENTITY="$CERT_NAME"
    fi
fi

run_swift_build() {
    set +e
    swift build "$@" 2>&1 | grep -E "Build complete|Build succeeded|error:|warning:"
    local build_status=${PIPESTATUS[0]}
    set -e
    if [ "$build_status" -ne 0 ]; then
        echo "swift build failed with exit code $build_status"
        exit "$build_status"
    fi
}

MUSE_PACKAGE_REQUIRE_PREBUILT="${MUSE_PACKAGE_REQUIRE_PREBUILT:-0}"
case "$MUSE_PACKAGE_REQUIRE_PREBUILT" in
    0|1) ;;
    *) echo "MUSE_PACKAGE_REQUIRE_PREBUILT must be 0 or 1" >&2; exit 1 ;;
esac

if [ "$MUSE_PACKAGE_REQUIRE_PREBUILT" = "1" ]; then
    BINARY="${MUSE_PACKAGE_PREBUILT_BINARY:-}"
    EXPECTED_BINARY_SHA256="${MUSE_PACKAGE_PREBUILT_SHA256:-}"
    [ -n "$BINARY" ] && [ -f "$BINARY" ] && [ ! -L "$BINARY" ] && [ -x "$BINARY" ] || {
        echo "Signing-window packaging requires an executable regular prebuilt binary" >&2
        exit 1
    }
    [[ "$EXPECTED_BINARY_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
        echo "MUSE_PACKAGE_PREBUILT_SHA256 must be 64 lowercase hexadecimal characters" >&2
        exit 1
    }
    ACTUAL_BINARY_SHA256="$(/usr/bin/shasum -a 256 "$BINARY" | /usr/bin/awk '{print $1}')"
    [ "$ACTUAL_BINARY_SHA256" = "$EXPECTED_BINARY_SHA256" ] || {
        echo "Prebuilt release binary SHA256 mismatch" >&2
        exit 1
    }
elif [ "${MUSE_PACKAGE_TEST_MODE:-0}" = "1" ]; then
    BINARY="${MUSE_PACKAGE_BINARY:-}"
    [ -f "$BINARY" ] || {
        echo "MUSE_PACKAGE_BINARY must point to a fixture executable" >&2
        exit 1
    }
else
    XCBUILD_BIN="/Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild"
    if [ -x "$XCBUILD_BIN" ]; then
        echo "Building universal release (arm64 + x86_64)..."
        run_swift_build -c release --package-path "$PROJECT_DIR" --arch arm64 --arch x86_64
    else
        echo "xcbuild not found, falling back to single-arch release build..."
        run_swift_build -c release --package-path "$PROJECT_DIR"
    fi

    if [ -f "$PROJECT_DIR/.build/apple/Products/Release/Muse" ]; then
        BINARY="$PROJECT_DIR/.build/apple/Products/Release/Muse"
    elif [ -f "$PROJECT_DIR/.build/release/Muse" ]; then
        BINARY="$PROJECT_DIR/.build/release/Muse"
    else
        BINARY="$(find "$PROJECT_DIR/.build" -path '*/release/Muse' -type f -not -path '*/x86_64/*' -not -path '*/arm64/*' | head -n 1)"
    fi
fi

if [ ! -f "$BINARY" ]; then
    echo "Build failed: binary not found"
    exit 1
fi

if [ "${MUSE_PACKAGE_TEST_MODE:-0}" = "1" ]; then
    MUSE_SOURCE_COMMIT_VALUE="${MUSE_SOURCE_COMMIT:-0000000000000000000000000000000000000000}"
    MUSE_SOURCE_TREE_VALUE="${MUSE_SOURCE_TREE:-0000000000000000000000000000000000000000}"
else
    MUSE_SOURCE_COMMIT_VALUE="$PACKAGING_SOURCE_COMMIT"
    MUSE_SOURCE_TREE_VALUE="$PACKAGING_SOURCE_TREE"
fi
MUSE_SOURCE_COMMIT_VALUE="$(printf '%s' "$MUSE_SOURCE_COMMIT_VALUE" | /usr/bin/tr '[:upper:]' '[:lower:]')"
MUSE_SOURCE_TREE_VALUE="$(printf '%s' "$MUSE_SOURCE_TREE_VALUE" | /usr/bin/tr '[:upper:]' '[:lower:]')"
[[ "$MUSE_SOURCE_COMMIT_VALUE" =~ ^[0-9a-f]{40}$ ]] || {
    echo "MUSE_SOURCE_COMMIT must be a full 40-character Git commit" >&2
    exit 1
}
[[ "$MUSE_SOURCE_TREE_VALUE" =~ ^[0-9a-f]{40}$ ]] || {
    echo "MUSE_SOURCE_TREE must be a full 40-character Git tree" >&2
    exit 1
}

echo "Packaging app bundle at $APP_PATH..."
trash_path "$APP_PATH/Contents"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY" "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
/bin/chmod 755 "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
cp "$PROJECT_DIR/Muse/Resources/${APP_ICON_NAME}.icns" "$APP_PATH/Contents/Resources/${APP_ICON_NAME}.icns" 2>/dev/null || true
cp "$PROJECT_DIR/Muse/Resources/BrandLogo.png" "$APP_PATH/Contents/Resources/BrandLogo.png" 2>/dev/null || true

cat >"$INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_EXECUTABLE}</string>
    <key>CFBundleIconFile</key>
    <string>${APP_ICON_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>MuseSourceCommit</key>
    <string>${MUSE_SOURCE_COMMIT_VALUE}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_SYSTEM_VERSION}</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>${MICROPHONE_USAGE_DESCRIPTION}</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>${SPEECH_RECOGNITION_USAGE_DESCRIPTION}</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>${APPLE_EVENTS_USAGE_DESCRIPTION}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${APP_BUNDLE_ID}</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>${APP_URL_SCHEME}</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

mkdir -p "$APP_PATH/Contents/Resources/Sounds"
cp "$PROJECT_DIR/Muse/Resources/Sounds/"*.wav "$APP_PATH/Contents/Resources/Sounds/" 2>/dev/null || true

# Copy SenseVoice model if available (for full DMG builds)
SENSEVOICE_MODEL_CACHE="$HOME/.cache/modelscope/hub/models/iic/SenseVoiceSmall"
SENSEVOICE_MODEL_FILES=(
    "model.pt"
    "config.yaml"
    "am.mvn"
    "chn_jpn_yue_eng_ko_spectok.bpe.model"
    "configuration.json"
)
SENSEVOICE_MODEL_SIZES=(936291369 1855 11203 377341 396)
SENSEVOICE_MODEL_SHA256=(
    "833ca2dcfdf8ec91bd4f31cfac36d6124e0c459074d5e909aec9cabe6204a3ea"
    "f71e239ba36705564b5bf2d2ffd07eece07b8e3f2bbf6d2c99d8df856339ac19"
    "29b3c740a2c0cfc6b308126d31d7f265fa2be74f3bb095cd2f143ea970896ae5"
    "aa87f86064c3730d799ddf7af3c04659151102cba548bce325cf06ba4da4e6a8"
    "02810a7f8e9e8aee10370a265f7e799728ce25b4c00cdbf4602b303ee395a38e"
)
if [ "${BUNDLE_SENSEVOICE_MODEL:-0}" = "1" ]; then
    if [ ! -d "$SENSEVOICE_MODEL_CACHE" ] || [ -L "$SENSEVOICE_MODEL_CACHE" ]; then
        echo "Pinned SenseVoice model cache is missing or is a symlink" >&2
        exit 1
    fi
    echo "Bundling SenseVoice model..."
    mkdir -p "$APP_PATH/Contents/Resources/Models"
    SENSEVOICE_MODEL_DEST="$APP_PATH/Contents/Resources/Models/SenseVoiceSmall"
    mkdir -p "$SENSEVOICE_MODEL_DEST"
    for index in "${!SENSEVOICE_MODEL_FILES[@]}"; do
        model_file="${SENSEVOICE_MODEL_FILES[$index]}"
        model_source="$SENSEVOICE_MODEL_CACHE/$model_file"
        model_dest="$SENSEVOICE_MODEL_DEST/$model_file"
        if [ ! -f "$model_source" ] || [ -L "$model_source" ]; then
            echo "Pinned SenseVoice model file is missing or is a symlink: $model_file" >&2
            exit 1
        fi
        actual_size="$(/usr/bin/stat -f%z "$model_source")"
        if [ "$actual_size" != "${SENSEVOICE_MODEL_SIZES[$index]}" ]; then
            echo "SenseVoice model size mismatch: $model_file" >&2
            exit 1
        fi
        actual_hash="$(/usr/bin/shasum -a 256 "$model_source" | /usr/bin/awk '{print $1}')"
        if [ "$actual_hash" != "${SENSEVOICE_MODEL_SHA256[$index]}" ]; then
            echo "SenseVoice model SHA256 mismatch: $model_file" >&2
            exit 1
        fi
        /bin/cp "$model_source" "$model_dest"
    done
    echo "SenseVoice model bundled."
fi

# Copy Qwen3-ASR model (4-bit quantized) if available
QWEN3_MODEL_CACHE="${QWEN3_MODEL_PATH:-$HOME/.cache/modelscope/hub/models/Qwen/Qwen3-ASR-0.6B-4bit}"
if [ "${BUNDLE_SENSEVOICE_MODEL:-0}" = "1" ] && [ -d "$QWEN3_MODEL_CACHE" ]; then
    echo "Bundling Qwen3-ASR model (4-bit)..."
    mkdir -p "$APP_PATH/Contents/Resources/Models/Qwen3-ASR"
    cp "$QWEN3_MODEL_CACHE"/model.safetensors "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/"
    cp "$QWEN3_MODEL_CACHE"/config.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/"
    cp "$QWEN3_MODEL_CACHE"/tokenizer_config.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    cp "$QWEN3_MODEL_CACHE"/vocab.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    cp "$QWEN3_MODEL_CACHE"/merges.txt "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    cp "$QWEN3_MODEL_CACHE"/generation_config.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    cp "$QWEN3_MODEL_CACHE"/preprocessor_config.json "$APP_PATH/Contents/Resources/Models/Qwen3-ASR/" 2>/dev/null || true
    echo "Qwen3-ASR model bundled."
fi

# Copy both local services only for the Local product. A requested Local build
# must never silently degrade into a Cloud bundle.
if [ "${BUNDLE_LOCAL_ASR:-0}" = "1" ]; then
    echo "Bundling sensevoice-server..."
    cp -R "$SENSEVOICE_DIST" "$APP_PATH/Contents/MacOS/sensevoice-server-dist"
    mkdir -p "$APP_PATH/Contents/Resources/LocalServices"
    # Shell wrapper remains a sealed resource. The executable entry is an in-bundle
    # symlink to the signed PyInstaller Mach-O, so codesign does not treat a shell
    # script under Contents/MacOS as unsigned nested code.
    cat > "$APP_PATH/Contents/Resources/LocalServices/sensevoice-server-wrapper.sh" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/../../MacOS/sensevoice-server-dist/sensevoice-server" "$@"
WRAPPER
    ln -s "sensevoice-server-dist/sensevoice-server" "$APP_PATH/Contents/MacOS/sensevoice-server"
    echo "sensevoice-server bundled."

    echo "Bundling qwen3-asr-server..."
    cp -R "$QWEN3_DIST" "$APP_PATH/Contents/MacOS/qwen3-asr-server-dist"
    cat > "$APP_PATH/Contents/Resources/LocalServices/qwen3-asr-server-wrapper.sh" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/../../MacOS/qwen3-asr-server-dist/qwen3-asr-server" "$@"
WRAPPER
    ln -s "qwen3-asr-server-dist/qwen3-asr-server" "$APP_PATH/Contents/MacOS/qwen3-asr-server"
    echo "qwen3-asr-server bundled."
fi

# Copy LLM model if available (for local LLM DMG builds)
LLM_MODEL_DIR="$PROJECT_DIR/sensevoice-server/models"
LLM_MODEL_SIZE="${BUNDLE_LOCAL_LLM:-0}"  # 0=none, 9b（2026-06-11 起 4B 已从产品除名）
if [ "$LLM_MODEL_SIZE" = "9b" ] && [ -f "$LLM_MODEL_DIR/Qwen3.5-9B-Q4_K_M.gguf" ]; then
    echo "Bundling Qwen3.5-9B LLM model (5.3GB)..."
    mkdir -p "$APP_PATH/Contents/Resources/Models"
    cp "$LLM_MODEL_DIR/Qwen3.5-9B-Q4_K_M.gguf" "$APP_PATH/Contents/Resources/Models/qwen3.5-9b-q4_k_m.gguf"
    echo "Qwen3.5-9B model bundled."
fi

# Normalize distributable Bundle permissions before the final signature. The release
# wrapper intentionally protects credentials with umask 077, but those private modes
# must never leak into an App copied for other macOS accounts.
/usr/bin/find "$APP_PATH" -type d -exec /bin/chmod 755 {} +
while IFS= read -r -d '' bundle_file; do
    if [ -x "$bundle_file" ]; then
        /bin/chmod 755 "$bundle_file"
    else
        /bin/chmod 644 "$bundle_file"
    fi
done < <(/usr/bin/find "$APP_PATH" -type f -print0)

# Remove quarantine flag that macOS adds to downloaded apps.
# This must happen before the final outer signature; after that the Bundle is read-only.
/usr/bin/xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true

echo "Signing with '${SIGNING_IDENTITY}'..."
SIGNING_IDENTITY="$SIGNING_IDENTITY" APP_BUNDLE_ID="$APP_BUNDLE_ID" \
    /bin/bash "$SCRIPT_DIR/sign-app-bundle.sh" "$APP_PATH"

EXPECT_LOCAL_BUNDLE="${BUNDLE_LOCAL_ASR:-0}" \
APP_NAME="$APP_NAME" \
APP_BUNDLE_ID="$APP_BUNDLE_ID" \
APP_VERSION="$APP_VERSION" \
APP_BUILD="$APP_BUILD" \
MIN_SYSTEM_VERSION="$MIN_SYSTEM_VERSION" \
    /bin/bash "$SCRIPT_DIR/test_app_bundle.sh" "$APP_PATH"

if [ -n "$QUALITY_BUILD_MANIFEST_PATH" ]; then
    PACKAGED_EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_EXECUTABLE"
    PACKAGED_EXECUTABLE_SHA256="$(/usr/bin/shasum -a 256 "$PACKAGED_EXECUTABLE" | /usr/bin/awk '{print $1}')"
    QUALITY_DATASET_SHA256="$(/usr/bin/shasum -a 256 "$QUALITY_DATASET_PATH" | /usr/bin/awk '{print $1}')"
    DESIGNATED_REQUIREMENT_OUTPUT="$(/usr/bin/codesign -dr - "$APP_PATH" 2>&1)"
    DESIGNATED_REQUIREMENT="$(printf '%s\n' "$DESIGNATED_REQUIREMENT_OUTPUT" | /usr/bin/awk '
        /^(# )?designated => / {
            sub(/^(# )?designated => /, "")
            print
            exit
        }
    ')"
    [ -n "$DESIGNATED_REQUIREMENT" ] || {
        echo "Unable to extract packaged app designated requirement" >&2
        exit 1
    }
    DESIGNATED_REQUIREMENT_SHA256="$(printf '%s' "$DESIGNATED_REQUIREMENT" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
    if [ "${MUSE_PACKAGE_TEST_MODE:-0}" = "1" ]; then
        MANIFEST_PACKAGE_MODE="test"
    else
        MANIFEST_PACKAGE_MODE="production"
    fi

    MUSE_MANIFEST_PACKAGE_MODE="$MANIFEST_PACKAGE_MODE" \
    MUSE_MANIFEST_BUNDLE_ID="$APP_BUNDLE_ID" \
    MUSE_MANIFEST_SOURCE_COMMIT="$MUSE_SOURCE_COMMIT_VALUE" \
    MUSE_MANIFEST_SOURCE_TREE="$MUSE_SOURCE_TREE_VALUE" \
    MUSE_MANIFEST_EXECUTABLE_SHA256="$PACKAGED_EXECUTABLE_SHA256" \
    MUSE_MANIFEST_DATASET_SHA256="$QUALITY_DATASET_SHA256" \
    MUSE_MANIFEST_QUALITY_PROFILE="$QUALITY_PROFILE" \
    MUSE_MANIFEST_CONTRACT_PATH="$QUALITY_CONTRACT_PATH" \
    MUSE_MANIFEST_DATASET_PATH="$QUALITY_DATASET_PATH" \
    MUSE_MANIFEST_DESIGNATED_REQUIREMENT="$DESIGNATED_REQUIREMENT" \
    MUSE_MANIFEST_DESIGNATED_REQUIREMENT_SHA256="$DESIGNATED_REQUIREMENT_SHA256" \
        /usr/bin/python3 - "$QUALITY_BUILD_MANIFEST_PATH" <<'PY'
import datetime
import hashlib
import json
import os
import sys
from pathlib import Path

path = sys.argv[1]
document = {
    "schema_version": 1,
    "artifact_kind": "muse_voice_polish_quality_candidate",
    "package_mode": os.environ["MUSE_MANIFEST_PACKAGE_MODE"],
    "bundle_id": os.environ["MUSE_MANIFEST_BUNDLE_ID"],
    "source_commit": os.environ["MUSE_MANIFEST_SOURCE_COMMIT"],
    "source_tree": os.environ["MUSE_MANIFEST_SOURCE_TREE"],
    "executable_sha256": os.environ["MUSE_MANIFEST_EXECUTABLE_SHA256"],
    "dataset_sha256": os.environ["MUSE_MANIFEST_DATASET_SHA256"],
    "designated_requirement": os.environ["MUSE_MANIFEST_DESIGNATED_REQUIREMENT"],
    "designated_requirement_sha256": os.environ[
        "MUSE_MANIFEST_DESIGNATED_REQUIREMENT_SHA256"
    ],
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat().replace(
        "+00:00", "Z"
    ),
}
document["quality_profile"] = os.environ["MUSE_MANIFEST_QUALITY_PROFILE"]
if document["quality_profile"] == "three_mode":
    contract_path = Path(os.environ["MUSE_MANIFEST_CONTRACT_PATH"])
    dataset_path = Path(os.environ["MUSE_MANIFEST_DATASET_PATH"])
    contract_data = contract_path.read_bytes()
    contract = json.loads(contract_data)
    dataset = json.loads(dataset_path.read_bytes())
    if contract.get("dataset_sha256") != document["dataset_sha256"]:
        raise SystemExit("Three-mode contracts do not bind the frozen dataset")
    if contract.get("input_count") != len(dataset.get("inputs", [])):
        raise SystemExit("Three-mode contracts and dataset input counts differ")
    document.update(
        supported_modes=["direct", "light", "standard"],
        scoring_contract_sha256=hashlib.sha256(contract_data).hexdigest(),
        three_mode_input_count=len(dataset["inputs"]),
    )
data = (json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(
    "utf-8"
)
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags, 0o600)
try:
    with os.fdopen(descriptor, "wb", closefd=False) as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.fchmod(descriptor, 0o444)
finally:
    os.close(descriptor)
PY
    QUALITY_BUILD_MANIFEST_SHA256="$(/usr/bin/shasum -a 256 "$QUALITY_BUILD_MANIFEST_PATH" | /usr/bin/awk '{print $1}')"
    echo "Quality build manifest ready at $QUALITY_BUILD_MANIFEST_PATH"
    echo "MUSE_QUALITY_EXPECTED_MANIFEST_SHA256=$QUALITY_BUILD_MANIFEST_SHA256"
    echo "MUSE_QUALITY_EXPECTED_SOURCE_COMMIT=$MUSE_SOURCE_COMMIT_VALUE"
    echo "MUSE_QUALITY_EXPECTED_SOURCE_TREE=$MUSE_SOURCE_TREE_VALUE"
    echo "MUSE_QUALITY_EXPECTED_EXECUTABLE_SHA256=$PACKAGED_EXECUTABLE_SHA256"
    echo "MUSE_QUALITY_EXPECTED_DATASET_SHA256=$QUALITY_DATASET_SHA256"
    if [ "$QUALITY_PROFILE" = "three_mode" ]; then
        QUALITY_CONTRACT_SHA256="$(/usr/bin/shasum -a 256 "$QUALITY_CONTRACT_PATH" | /usr/bin/awk '{print $1}')"
        echo "MUSE_QUALITY_EXPECTED_CONTRACT_SHA256=$QUALITY_CONTRACT_SHA256"
    fi
    echo "MUSE_QUALITY_EXPECTED_DESIGNATED_REQUIREMENT_SHA256=$DESIGNATED_REQUIREMENT_SHA256"
fi

echo "App bundle ready at $APP_PATH"
