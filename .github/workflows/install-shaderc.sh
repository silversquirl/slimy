#!/bin/sh -e
ci_page=https://storage.googleapis.com/shaderc/badges/build_link_linux_clang_release.html
latest_build=$(curl -sSL "$ci_page" | sed 's/.*url=\([^"]*\)".*/\1/;q')
curl -sSLo shaderc.tar.gz "$latest_build"
tar -xzf shaderc.tar.gz
mv install shaderc
