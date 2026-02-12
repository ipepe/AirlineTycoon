#!/bin/bash
set -euo pipefail

BUILD_DIR="$1"
BINARY="$BUILD_DIR/AT"

# Helper: list Homebrew/non-system dylib references from a Mach-O file
get_brew_deps() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' | \
        grep -E '/opt/homebrew|/usr/local/(Cellar|opt)' || true
}

# Phase 1: Iteratively copy all transitive Homebrew dependencies
CHANGED=true
while $CHANGED; do
    CHANGED=false
    for file in "$BINARY" "$BUILD_DIR"/*.dylib; do
        [ -f "$file" ] || continue
        for dep in $(get_brew_deps "$file"); do
            dep_name=$(basename "$dep")
            if [ ! -f "$BUILD_DIR/$dep_name" ]; then
                echo "Bundling $dep"
                cp "$dep" "$BUILD_DIR/$dep_name"
                chmod u+w "$BUILD_DIR/$dep_name"
                CHANGED=true
            fi
        done
    done
done

# Phase 2: Rewrite all Homebrew references to @executable_path
for file in "$BINARY" "$BUILD_DIR"/*.dylib; do
    [ -f "$file" ] || continue
    # Fix dylib's own install name
    if [[ "$file" == *.dylib ]]; then
        install_name_tool -id "@executable_path/$(basename "$file")" "$file"
    fi
    # Fix references to Homebrew dylibs
    for dep in $(get_brew_deps "$file"); do
        dep_name=$(basename "$dep")
        install_name_tool -change "$dep" "@executable_path/$dep_name" "$file"
    done
done

# Phase 3: Ad-hoc code sign (required on Apple Silicon, safe on Intel)
for file in "$BUILD_DIR"/*.dylib "$BINARY"; do
    [ -f "$file" ] || continue
    codesign -fs - "$file"
done

echo "Bundled libraries:"
ls -la "$BUILD_DIR"/*.dylib 2>/dev/null || echo "(none found)"
