#!/bin/bash
# 重建 libmr_full.dylib（自写 ObjC MediaRemote 插件）
set -e
cd "$(dirname "$0")/.."
clang -fobjc-arc -dynamiclib resources/libmr_full.m -framework Foundation -o resources/libmr_full.dylib
codesign --force --deep -s - resources/libmr_full.dylib
echo "built resources/libmr_full.dylib"
nm -gU resources/libmr_full.dylib | grep mr_ || true
