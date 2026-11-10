#!/bin/bash
set -euo pipefail

source_dir=$(cd "$(dirname "$0")" && pwd)
destination=${1:-"$source_dir/build/Audio Capture.app"}
case "$destination" in
    /*) ;;
    *) destination="$PWD/$destination" ;;
esac
if [[ "$destination" != *.app || -e "$destination" || -L "$destination" ]]; then
    printf 'Choose a new destination ending in .app. Got %s\n' "$destination" >&2
    exit 1
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/audio-capture.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
bundle="$scratch/Audio Capture.app"
model_resources="$bundle/Contents/Resources/WhisperKit"
mkdir -p "$bundle/Contents/MacOS" "$model_resources"
cp "$source_dir/Info.plist" "$bundle/Contents/Info.plist"

printf 'Preparing bundled Whisper Base files\n'
while read -r checksum file; do
    case "$file" in
        models/argmaxinc/whisperkit-coreml/openai_whisper-base/*)
            repo=argmaxinc/whisperkit-coreml
            revision=0f63a7800b00dd0226abd051b906c246e1907482
            ;;
        models/openai/whisper-base/*)
            repo=openai/whisper-base
            revision=e37978b90ca9030d5170a5c07aadb050351a65bb
            ;;
        *)
            printf 'Unexpected model file in manifest: %s\n' "$file" >&2
            exit 1
            ;;
    esac

    target="$model_resources/$file"
    mkdir -p "$(dirname "$target")"
    if [[ -n "${WHISPERKIT_CACHE_DIR:-}" && -f "$WHISPERKIT_CACHE_DIR/$file" ]]; then
        cp "$WHISPERKIT_CACHE_DIR/$file" "$target"
    else
        remote_path=${file#models/"$repo"/}
        /usr/bin/curl --fail --silent --show-error --location --retry 2 --max-time 180 \
            --output "$target" "https://huggingface.co/$repo/resolve/$revision/$remote_path"
    fi
done < "$source_dir/Whisper Base.sha256"
(
    cd "$model_resources"
    /usr/bin/shasum -a 256 --check --quiet "$source_dir/Whisper Base.sha256"
)

for arch in arm64 x86_64; do
    options=(
        --package-path "$source_dir"
        --scratch-path "$scratch/$arch"
        --configuration release
        --triple "$arch-apple-macosx26.0"
        --force-resolved-versions
    )
    xcrun swift build "${options[@]}" --product AudioCapture
    bin_path=$(xcrun swift build "${options[@]}" --show-bin-path)
    cp "$bin_path/AudioCapture" "$scratch/AudioCapture-$arch"
done

cp "$scratch/arm64/checkouts/argmax-oss-swift/"{LICENSE,NOTICES} \
    "$model_resources/"
cp "$source_dir/Whisper Base Notices.txt" "$model_resources/"
xcrun lipo -create "$scratch/AudioCapture-arm64" "$scratch/AudioCapture-x86_64" \
    -output "$bundle/Contents/MacOS/AudioCapture"
codesign --sign - --options runtime --entitlements "$source_dir/AudioCapture.entitlements" "$bundle"
codesign --verify --strict "$bundle"
mkdir -p "$(dirname "$destination")"
mv "$bundle" "$destination"
printf '%s\n' "$destination"
