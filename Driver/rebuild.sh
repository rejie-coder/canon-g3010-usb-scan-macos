#!/bin/bash
# Private build directory keeps the scanner independent of global package installations.
set -euo pipefail
export LC_ALL=C
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d /tmp/g3010-driver.XXXXXX)
trap 'rm -rf "$work"' EXIT
prefix="$work/runtime"
(cd "$here/Sources" && shasum -a 256 -c SHA256SUMS)
cd "$work"
for archive in "$here"/Sources/*.tar.*; do tar xf "$archive"; done
cd libusb-1.0.30
./configure --prefix="$prefix" --disable-shared --enable-static
make -j6
make install
cd "$work"
cmake -S libjpeg-turbo-3.2.1 -B jpeg-build -DCMAKE_INSTALL_PREFIX="$prefix" -DENABLE_SHARED=OFF -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build jpeg-build -j 6
cmake --install jpeg-build
cd sane-backends-1.4.0
CPPFLAGS="-I$prefix/include" LDFLAGS="-L$prefix/lib" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" \
USB_CFLAGS="-I$prefix/include/libusb-1.0" USB_LIBS="-L$prefix/lib -lusb-1.0 -framework IOKit -framework CoreFoundation -framework Security" \
BACKENDS=pixma PRELOADABLE_BACKENDS=pixma ./configure --prefix="$prefix" --enable-static --disable-shared --disable-dynamic --disable-nls --without-snmp --without-avahi --without-gphoto2 --with-usb --disable-locking
make -C lib -j6
make -C sanei -j6
make -C backend dll-preload.h
make -C backend libdll_preload_la-dll.lo CFLAGS='-O2 -Wno-error=incompatible-function-pointer-types'
make -C backend -j6
make -C frontend -j6 scanimage LIBS='-lusb-1.0 -framework CoreFoundation -framework IOKit -framework Security'
strip -S frontend/scanimage
install -m 755 frontend/scanimage "$here/scanimage"
