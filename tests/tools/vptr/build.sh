#!/bin/bash
# Builds vptr. Needs wayland-scanner, libwayland-client headers, and a C
# compiler. The protocol xml is vendored from wlr-protocols, MIT.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

XML=wlr-virtual-pointer-unstable-v1.xml
wayland-scanner client-header "$XML" wlr-virtual-pointer-unstable-v1-client-protocol.h
wayland-scanner private-code "$XML" wlr-virtual-pointer-unstable-v1-protocol.c

cc -O2 -o vptr vptr.c wlr-virtual-pointer-unstable-v1-protocol.c \
  $(pkg-config --cflags --libs wayland-client)

echo "built $(pwd)/vptr"
