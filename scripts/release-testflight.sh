#!/bin/sh
set -eu

# Build, sign, export, and upload the iOS app to TestFlight.
# The App Store Connect private key is never stored in this repository.

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_file="$project_root/ios/DSHAnywhere.xcodeproj"
scheme=${DSH_IOS_SCHEME:-DSHAnywhere}
configuration=${DSH_IOS_CONFIGURATION:-Release}

# These identifiers are not private. They can be overridden for another team
# with ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH.
asc_key_id=${ASC_KEY_ID:-3HM6YT6KMS}
asc_issuer_id=${ASC_ISSUER_ID:-60795c18-fe7d-402e-bac5-e8fd62903c2f}
asc_key_path=${ASC_KEY_PATH:-"${HOME}/.appstoreconnect/private_keys/AuthKey_${asc_key_id}.p8"}

usage() {
	cat >&2 <<'EOF'
用法：
  ./scripts/release-testflight.sh [构建号]

不传构建号时，会先将 iOS 工程的 CURRENT_PROJECT_VERSION 自动加 1。
也可以通过 ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_PATH 覆盖默认配置。
EOF
	exit 64
}

[ "$#" -le 1 ] || usage

if [ "$#" -eq 1 ]; then
	build_number=$1
else
	build_number=
fi

[ -f "$asc_key_path" ] || {
	echo "找不到 App Store Connect 私钥：$asc_key_path" >&2
	exit 1
}

key_mode=$(stat -f '%Lp' "$asc_key_path")
case "$key_mode" in
	600|400) ;;
	*)
		echo "私钥权限过宽（当前 $key_mode），请执行：" >&2
		echo "chmod 600 \"$asc_key_path\"" >&2
		exit 1
		;;
esac

command -v xcodebuild >/dev/null 2>&1 || {
	echo "找不到 xcodebuild，请安装 Xcode。" >&2
	exit 1
}
command -v xcrun >/dev/null 2>&1 || {
	echo "找不到 xcrun，请安装 Xcode。" >&2
	exit 1
}

case "$build_number" in
	'')
		(cd "$project_root/ios" && /usr/bin/agvtool next-version -all >/dev/null)
		build_number=$(cd "$project_root/ios" && /usr/bin/agvtool what-version -terse)
		;;
	*[!0-9]*)
		echo "构建号必须是数字：$build_number" >&2
		exit 64
		;;
	*)
		(cd "$project_root/ios" && /usr/bin/agvtool new-version -all "$build_number" >/dev/null)
		;;
esac

archive_root="$project_root/artifacts/ios"
mkdir -p "$archive_root"
stamp=$(date '+%Y%m%d-%H%M%S')
archive_path="$archive_root/DSHAnywhere-build${build_number}-${stamp}.xcarchive"
export_path="$archive_root/export-build${build_number}-${stamp}"
export_options="$project_root/ios/ExportOptions-AppStore.plist"
# Use a fresh build directory for each archive.  Reusing a Finder/FileProvider
# directory can put FinderInfo back on the generated .app directory.
derived_data_path="${TMPDIR:-/tmp}/DSHAnywhere-DerivedData-TestFlight-${build_number}-${stamp}"

# macOS can attach Finder metadata to files copied from Finder, archives, or
# Downloads.  codesign rejects that metadata ("resource fork, Finder
# information, or similar detritus not allowed"), so clear it only from the
# iOS source tree and the build output used by this release.
if command -v xattr >/dev/null 2>&1; then
	/usr/bin/xattr -cr "$project_root/ios" 2>/dev/null || true
	if [ -d "$derived_data_path" ]; then
		/usr/bin/xattr -cr "$derived_data_path" 2>/dev/null || true
	fi
fi

marketing_version=$(xcodebuild \
	-project "$project_file" \
	-scheme "$scheme" \
	-configuration "$configuration" \
	-showBuildSettings 2>/dev/null |
	awk -F ' = ' '$1 ~ /MARKETING_VERSION/ { print $2; exit }')

[ -n "$marketing_version" ] || marketing_version=unknown

echo "开始归档 DSH Anywhere ${marketing_version}（Build ${build_number}）..."
xcodebuild \
	-project "$project_file" \
	-scheme "$scheme" \
	-configuration "$configuration" \
	-destination 'generic/platform=iOS' \
	-derivedDataPath "$derived_data_path" \
	-archivePath "$archive_path" \
	-allowProvisioningUpdates \
	-authenticationKeyPath "$asc_key_path" \
	-authenticationKeyID "$asc_key_id" \
	-authenticationKeyIssuerID "$asc_issuer_id" \
	CURRENT_PROJECT_VERSION="$build_number" \
	archive

echo "导出可上传的 IPA..."
xcodebuild \
	-exportArchive \
	-archivePath "$archive_path" \
	-exportPath "$export_path" \
	-exportOptionsPlist "$export_options" \
	-allowProvisioningUpdates \
	-authenticationKeyPath "$asc_key_path" \
	-authenticationKeyID "$asc_key_id" \
	-authenticationKeyIssuerID "$asc_issuer_id"

ipa_path=$(find "$export_path" -maxdepth 1 -type f -name '*.ipa' -print -quit)
[ -n "$ipa_path" ] || {
	echo "导出完成但没有找到 IPA：$export_path" >&2
	exit 1
}

echo "上传到 TestFlight：$ipa_path"
xcrun altool \
	--upload-app \
	-f "$ipa_path" \
	-t ios \
	--apiKey "$asc_key_id" \
	--apiIssuer "$asc_issuer_id"

echo "上传命令已完成。请在 App Store Connect 的 TestFlight 页面等待 Apple 处理构建。"
echo "归档：$archive_path"
echo "IPA：$ipa_path"
