#!/bin/bash
set -euo pipefail

BUILD_DIR="$1"
BINARY="$BUILD_DIR/AT"

# Helper: list Homebrew dylib references (absolute paths)
get_brew_deps() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' | \
        grep -E '/opt/homebrew|/usr/local/(Cellar|opt)' || true
}

# Helper: list @rpath dylib references
get_rpath_deps() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' | grep '^@rpath/' || true
}

# Helper: get LC_RPATH entries from a Mach-O file
get_rpaths() {
    otool -l "$1" | awk '/cmd LC_RPATH/{found=1} found && /path /{print $2; found=0}'
}

# Helper: resolve an @rpath/lib reference to an actual file path
resolve_rpath() {
    local file="$1"
    local ref="$2"
    local libname="${ref#@rpath/}"

    # Try LC_RPATH resolution first
    for rpath in $(get_rpaths "$file"); do
        local resolved="${rpath/@loader_path/$(dirname "$file")}"
        if [ -f "$resolved/$libname" ]; then
            echo "$resolved/$libname"
            return
        fi
    done

    # Fallback: search Homebrew directories (covers copied dylibs whose
    # @loader_path no longer resolves to the original Homebrew location)
    local brew_prefix
    brew_prefix=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")
    if [ -f "$brew_prefix/lib/$libname" ]; then
        echo "$brew_prefix/lib/$libname"
        return
    fi
    for dir in "$brew_prefix"/opt/*/lib; do
        if [ -f "$dir/$libname" ]; then
            echo "$dir/$libname"
            return
        fi
    done
}

# Phase 1: Iteratively copy all transitive dependencies (Homebrew absolute + @rpath)
CHANGED=true
while $CHANGED; do
    CHANGED=false
    for file in "$BINARY" "$BUILD_DIR"/*.dylib; do
        [ -f "$file" ] || continue

        # Copy Homebrew absolute-path dependencies
        for dep in $(get_brew_deps "$file"); do
            dep_name=$(basename "$dep")
            if [ ! -f "$BUILD_DIR/$dep_name" ]; then
                echo "Bundling $dep"
                cp "$dep" "$BUILD_DIR/$dep_name"
                chmod u+w "$BUILD_DIR/$dep_name"
                CHANGED=true
            fi
        done

        # Copy @rpath dependencies
        for dep in $(get_rpath_deps "$file"); do
            dep_name=$(basename "$dep")
            if [ ! -f "$BUILD_DIR/$dep_name" ]; then
                actual_path=$(resolve_rpath "$file" "$dep")
                if [ -n "$actual_path" ]; then
                    echo "Bundling $dep -> $actual_path"
                    cp "$actual_path" "$BUILD_DIR/$dep_name"
                    chmod u+w "$BUILD_DIR/$dep_name"
                    CHANGED=true
                fi
            fi
        done
    done
done

# Phase 2: Rewrite all references to @executable_path
for file in "$BINARY" "$BUILD_DIR"/*.dylib; do
    [ -f "$file" ] || continue
    # Fix dylib's own install name
    if [[ "$file" == *.dylib ]]; then
        install_name_tool -id "@executable_path/$(basename "$file")" "$file"
    fi
    # Fix Homebrew absolute-path references
    for dep in $(get_brew_deps "$file"); do
        dep_name=$(basename "$dep")
        install_name_tool -change "$dep" "@executable_path/$dep_name" "$file"
    done
    # Fix @rpath references
    for dep in $(get_rpath_deps "$file"); do
        dep_name=$(basename "$dep")
        if [ -f "$BUILD_DIR/$dep_name" ]; then
            install_name_tool -change "$dep" "@executable_path/$dep_name" "$file"
        fi
    done
done

# Phase 3: Ad-hoc code sign (required on Apple Silicon, safe on Intel)
for file in "$BUILD_DIR"/*.dylib "$BINARY"; do
    [ -f "$file" ] || continue
    codesign -fs - "$file"
done

echo "Bundled libraries:"
ls -la "$BUILD_DIR"/*.dylib 2>/dev/null || echo "(none found)"
