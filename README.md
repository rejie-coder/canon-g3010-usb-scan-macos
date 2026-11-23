# Canon PIXMA G3010 USB Scan for macOS

Scan paper documents over USB on an Intel Mac and save them as PDF, JPEG or PNG. This independent app includes the SANE scanner helper and works offline. Adjust the page corners and paper whitening before saving.

## Download and install

1. Download the Intel DMG from the [v1.2 release](https://github.com/rejie-coder/canon-g3010-usb-scan-macos/releases/tag/v1.2).
2. Open the disk image and drag **G3010 USB Scan** into Applications.
3. Connect the powered-on PIXMA G3010 over USB, open the app, click **Refresh**, place the page face down, and click **Scan page**.

Requires an Intel Mac running macOS 14 or later. USB scanning was tested on macOS Sonoma 14.8.9. The build uses a local ad hoc signature and has not been notarized. See [Apple’s per-app approval instructions](https://support.apple.com/en-us/102445).

## Build

Run `./build.sh` on an Intel Mac with the Xcode Swift compiler. Run `./package.sh` to build the disk image. The bundled helper can be rebuilt from the included dependency archives with `Driver/rebuild.sh`, a C toolchain, make and CMake.

## License

Copyright 2026 Rejinten Jayawardhana. The original Swift app, configuration and project scripts are licensed under the GNU General Public License, version 2 or (at your option) any later version (GPL-2.0-or-later). See [LICENSE](LICENSE).

SANE, libusb and libjpeg-turbo retain their upstream licenses and notices. See [third-party notices](Driver/Licenses) and the [corresponding sources](Driver/Sources). This software is based in part on the work of the Independent JPEG Group.
