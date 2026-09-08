#!/bin/sh
set -eu
ditoo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ditoo_root"
swift build -c release --arch arm64 --arch x86_64 --product ditooctl >&2
ditoo_build=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
ditoo_version=$("$ditoo_build/ditooctl" --version)
if [ "$#" -gt 1 ]; then echo 'Usage: package.sh [EXPECTED_VERSION]' >&2; exit 2; fi
if [ "$#" -eq 1 ] && [ "${1#v}" != "$ditoo_version" ]; then
  echo "Tag version $1 differs from binary $ditoo_version" >&2; exit 1
fi
ditoo_name="ditooctl-$ditoo_version-macos-universal"
ditoo_stage="$ditoo_root/dist/$ditoo_name"
mkdir -p "$ditoo_stage/bin" "$ditoo_stage/scripts"
install -m 755 "$ditoo_build/ditooctl" "$ditoo_stage/bin/ditooctl"
codesign --force --sign - --identifier io.github.leoshimo.ditooctl "$ditoo_stage/bin/ditooctl" >&2
codesign --verify --strict "$ditoo_stage/bin/ditooctl"
lipo "$ditoo_stage/bin/ditooctl" -verify_arch arm64 x86_64
cp README.md LICENSE "$ditoo_stage/"
install -m 755 scripts/install.sh "$ditoo_stage/scripts/install.sh"
COPYFILE_DISABLE=1 tar -czf "dist/$ditoo_name.tar.gz" -C dist "$ditoo_name"
(cd dist && shasum -a 256 "$ditoo_name.tar.gz" > "$ditoo_name.tar.gz.sha256")
echo "$ditoo_root/dist/$ditoo_name.tar.gz"
