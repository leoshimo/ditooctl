#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then echo 'Usage: formula.sh OWNER/REPO VERSION' >&2; exit 2; fi
ditoo_repo=$1
ditoo_version=${2#v}
case "$ditoo_repo" in *[!A-Za-z0-9_./-]*|/*|*..*) echo 'Invalid repository.' >&2; exit 2 ;; esac
case "$ditoo_repo" in */*) ;; *) echo 'Expected OWNER/REPO.' >&2; exit 2 ;; esac
case "$ditoo_version" in ''|*[!0-9A-Za-z.-]*) echo 'Invalid version.' >&2; exit 2 ;; esac
ditoo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ditoo_archive="ditooctl-$ditoo_version-macos-universal.tar.gz"
ditoo_digest=$(shasum -a 256 "$ditoo_root/dist/$ditoo_archive")
ditoo_sha=${ditoo_digest%% *}
cat <<EOF
class Ditooctl < Formula
  desc "Direct remote for the Divoom Ditoo pixel display"
  homepage "https://github.com/$ditoo_repo"
  url "https://github.com/$ditoo_repo/releases/download/v$ditoo_version/$ditoo_archive"
  sha256 "$ditoo_sha"
  license "MIT"
  depends_on :macos => :ventura

  def install
    bin.install "bin/ditooctl"
  end

  test do
    assert_equal "$ditoo_version", shell_output("#{bin}/ditooctl --version").strip
  end
end
EOF
