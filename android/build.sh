#!/usr/bin/env bash
# Local build helper: keeps all toolchain state inside the repo (.tooling/).
set -e
cd "$(dirname "$0")"
export JAVA_HOME="$PWD/../.tooling/jdk21/Contents/Home"
export ANDROID_HOME="$PWD/../.tooling/android-sdk"
export ANDROID_USER_HOME="$PWD/../.tooling/android-home"
exec ./gradlew --gradle-user-home ../.tooling/gradle-home "$@"
