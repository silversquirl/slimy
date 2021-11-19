#!/bin/sh
zig build \
	-Drelease-safe -Dglslc="$PWD/shaderc/bin/glslc" \
	-Dsuffix -Dstrip -Dtimestamp -Dtarget="$1"

