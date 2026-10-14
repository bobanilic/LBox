#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 6 -parse-as-library \
  LBox/RepoModels.swift LBox/FileOperations.swift LBox/AppFileWorker.swift \
  LBox/DownloadManager.swift LBox/RepositoryTransport.swift tests/QuickChecks.swift \
  -o "$test_dir/lbox-quick-checks"
"$test_dir/lbox-quick-checks"
