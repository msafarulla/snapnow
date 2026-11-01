#ifndef SNAPNOW_NATIVE_H_
#define SNAPNOW_NATIVE_H_

#include <flutter_linux/flutter_linux.h>

// Registers the Linux side of the `snaplite/native` method channel (the macOS app's Swift SnapLiteNative).
// Phase 1 implements prefs, beep, open/reveal, screen-access and toast; capture/recording/OCR/clipboard/share
// return null for now so the editor degrades gracefully instead of throwing MissingPluginException.
void snapnow_native_register(FlBinaryMessenger* messenger);

#endif  // SNAPNOW_NATIVE_H_
