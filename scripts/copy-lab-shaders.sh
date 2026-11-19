#!/bin/sh
# The lab ships distinct Metal libraries; never put Simulator shaders in a phone app.
set -eu
case "$PLATFORM_NAME" in
    iphoneos|iphonesimulator) ;;
    *) echo "Unsupported lab shader platform: $PLATFORM_NAME" >&2; exit 1 ;;
esac
shader_source="$SRCROOT/Vendor/LabShaders/$PLATFORM_NAME"
shader_destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$shader_destination"
for shader_library in "$shader_source"/*.metallib; do
    test -f "$shader_library"
    cp "$shader_library" "$shader_destination/$(basename "$shader_library")"
done
