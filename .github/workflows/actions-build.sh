#!/bin/sh
zig build \
	-Doptimize=ReleaseSafe -Dglslc="$PWD/shaderc/bin/glslc" \
	-Dsuffix -Dstrip -Dtimestamp -Dtarget="$1"

