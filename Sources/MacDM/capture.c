// Legacy window-capture shim: CGWindowListCreateImage is unavailable in the
// macOS 27 SDK headers but still present in CoreGraphics, and capturing your
// OWN window never required Screen Recording permission. Resolved dynamically
// so the Swift sources stay buildable on both old and new SDKs.
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>

CGImageRef macdm_capture_window(uint32_t wid) {
    typedef CGImageRef (*CreateImageFn)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);
    CreateImageFn fn = (CreateImageFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (!fn) return NULL;
    return fn(CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)wid,
              kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
}
