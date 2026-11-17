/* SPDX-License-Identifier: GPL-3.0-only
   Adapted from AltTab, copyright lwouis and contributors.
   Modified 2026-11-17 by glasss13: C focus bridge and bounded window discovery.
   See THIRD_PARTY.md for upstream source references and LICENSE for terms. */
#include "WindowBridge.h"
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <string.h>
#include <time.h>

typedef AXError (*WindowFn)(AXUIElementRef, CGWindowID *);
typedef CGError (*FrontFn)(ProcessSerialNumber *, CGWindowID, uint32_t);
typedef CGError (*PostFn)(ProcessSerialNumber *, uint8_t *);
typedef uint32_t (*ConnectionFn)(void);
typedef CFStringRef (*ActiveDisplayFn)(uint32_t);
typedef uint64_t (*ActiveSpaceFn)(uint32_t, CFStringRef);
typedef CFArrayRef (*WindowSpacesFn)(uint32_t, int, CFArrayRef);
typedef CGError (*SpaceFrontFn)(uint32_t, uint64_t, ProcessSerialNumber);
typedef CFArrayRef (*DisplaySpacesFn)(uint32_t);
typedef CFArrayRef (*WindowsFn)(uint32_t, intptr_t, CFArrayRef, intptr_t, intptr_t *, intptr_t *);
typedef AXUIElementRef (*RemoteElementFn)(CFDataRef);
static WindowFn windowFn;
static FrontFn frontFn;
static PostFn postFn;
static ConnectionFn connectionFn;
static ActiveDisplayFn activeDisplayFn;
static ActiveSpaceFn activeSpaceFn;
static WindowSpacesFn windowSpacesFn;
static SpaceFrontFn spaceFrontFn;
static DisplaySpacesFn displaySpacesFn;
static WindowsFn windowsFn;
static RemoteElementFn remoteElementFn;
static dispatch_once_t once;

static void loadSymbols(void) {
    dispatch_once(&once, ^{
        void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        windowFn = (WindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
        remoteElementFn = (RemoteElementFn)dlsym(RTLD_DEFAULT, "_AXUIElementCreateWithRemoteToken");
        if (sky) {
            frontFn = (FrontFn)dlsym(sky, "_SLPSSetFrontProcessWithOptions");
            postFn = (PostFn)dlsym(sky, "SLPSPostEventRecordTo");
            connectionFn = (ConnectionFn)dlsym(sky, "CGSMainConnectionID");
            activeDisplayFn = (ActiveDisplayFn)dlsym(sky, "CGSCopyActiveMenuBarDisplayIdentifier");
            activeSpaceFn = (ActiveSpaceFn)dlsym(sky, "CGSManagedDisplayGetCurrentSpace");
            windowSpacesFn = (WindowSpacesFn)dlsym(sky, "CGSCopySpacesForWindows");
            spaceFrontFn = (SpaceFrontFn)dlsym(sky, "SLSSpaceSetFrontPSN");
            displaySpacesFn = (DisplaySpacesFn)dlsym(sky, "CGSCopyManagedDisplaySpaces");
            windowsFn = (WindowsFn)dlsym(sky, "CGSCopyWindowsWithOptionsAndTags");
        }
    });
}

CGWindowID ATWindowID(AXUIElementRef element) {
    loadSymbols();
    CGWindowID window = 0;
    if (windowFn) windowFn(element, &window);
    return window;
}

CFArrayRef ATCopyAllWindowInfo(void) {
    loadSymbols();
    if (!connectionFn || !displaySpacesFn || !windowsFn)
        return CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    uint32_t connection = connectionFn();
    CFArrayRef displays = displaySpacesFn(connection);
    CFMutableArrayRef ids = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (displays) {
        for (CFIndex i = 0; i < CFArrayGetCount(displays); i++) {
            CFDictionaryRef display = CFArrayGetValueAtIndex(displays, i);
            CFArrayRef spaces = CFDictionaryGetValue(display, CFSTR("Spaces"));
            if (!spaces) continue;
            for (CFIndex j = 0; j < CFArrayGetCount(spaces); j++) {
                CFDictionaryRef space = CFArrayGetValueAtIndex(spaces, j);
                CFNumberRef id = CFDictionaryGetValue(space, CFSTR("id64"));
                if (id && !CFArrayContainsValue(ids, CFRangeMake(0, CFArrayGetCount(ids)), id)) CFArrayAppendValue(ids, id);
            }
        }
        CFRelease(displays);
    }
    intptr_t set = 0, clear = 0;
    CFArrayRef wids = CFArrayGetCount(ids) ? windowsFn(connection, 0, ids, 5, &set, &clear) : NULL;
    CFRelease(ids);
    // SkyLight returns CFNumbers; CoreGraphics expects raw CGWindowID values in a
    // callback-free CFArray (the same representation as CGWindowListCreate).
    CFMutableArrayRef rawIDs = CFArrayCreateMutable(NULL, 0, NULL);
    if (wids) {
        for (CFIndex i = 0; i < CFArrayGetCount(wids); i++) {
            int64_t wid = 0;
            CFNumberGetValue(CFArrayGetValueAtIndex(wids, i), kCFNumberSInt64Type, &wid);
            CFArrayAppendValue(rawIDs, (const void *)(uintptr_t)wid);
        }
    }
    CFArrayRef result = wids ? CGWindowListCreateDescriptionFromArray(rawIDs) : NULL;
    CFRelease(rawIDs);
    if (wids) CFRelease(wids);
    return result ? result : CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
}

static double monotonicSeconds(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec + time.tv_nsec / 1e9;
}

// A bounded, per-app traversal of the remote AX token space. Matching the window ID
// alone is insufficient: descendants have the same ID, so accept only AXWindow roots.
CFDictionaryRef ATCopyWindowElements(pid_t pid, CFArrayRef windowIDs) {
    loadSymbols();
    CFMutableDictionaryRef found = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!remoteElementFn || !windowFn || !CFArrayGetCount(windowIDs)) return found;
    CFMutableDataRef token = CFDataCreateMutable(NULL, 20);
    CFDataSetLength(token, 20);
    uint8_t *bytes = CFDataGetMutableBytePtr(token);
    memset(bytes, 0, 20);
    uint32_t magic = 0x636f636f;
    memcpy(bytes, &pid, 4); memcpy(bytes + 8, &magic, 4);
    double deadline = monotonicSeconds() + 0.12;
    for (uint64_t id = 0; id < 20000 && monotonicSeconds() < deadline; id++) {
        memcpy(bytes + 12, &id, 8);
        AXUIElementRef element = remoteElementFn(token);
        if (!element) continue;
        AXUIElementSetMessagingTimeout(element, 0.02);
        CGWindowID wid = 0;
        if (windowFn(element, &wid) == kAXErrorSuccess && wid) {
            int64_t value = wid;
            CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
            if (CFArrayContainsValue(windowIDs, CFRangeMake(0, CFArrayGetCount(windowIDs)), number) && !CFDictionaryContainsKey(found, number)) {
                CFTypeRef role = NULL;
                if (AXUIElementCopyAttributeValue(element, kAXRoleAttribute, &role) == kAXErrorSuccess && role && CFEqual(role, kAXWindowRole))
                    CFDictionarySetValue(found, number, element);
                if (role) CFRelease(role);
            }
            CFRelease(number);
        }
        CFRelease(element);
        if (CFDictionaryGetCount(found) == CFArrayGetCount(windowIDs)) break;
    }
    CFRelease(token);
    return found;
}

static uint64_t originSpaceIfCrossSpace(CGWindowID window) {
    if (!connectionFn || !activeDisplayFn || !activeSpaceFn || !windowSpacesFn || !spaceFrontFn) return 0;
    uint32_t connection = connectionFn();
    CFStringRef display = activeDisplayFn(connection);
    if (!display) return 0;
    uint64_t origin = activeSpaceFn(connection, display);
    CFRelease(display);
    int64_t value = window;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
    CFArrayRef ids = CFArrayCreate(NULL, (const void **)&number, 1, &kCFTypeArrayCallBacks);
    CFArrayRef spaces = windowSpacesFn(connection, 7, ids);
    CFRelease(ids); CFRelease(number);
    bool crossSpace = spaces && CFArrayGetCount(spaces) > 0;
    if (spaces) {
        for (CFIndex index = 0; index < CFArrayGetCount(spaces); index++) {
            uint64_t space = 0;
            CFNumberGetValue(CFArrayGetValueAtIndex(spaces, index), kCFNumberSInt64Type, &space);
            if (space == origin) crossSpace = false;
        }
        CFRelease(spaces);
    }
    return crossSpace ? origin : 0;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
bool ATFocusWindow(pid_t pid, CGWindowID window) {
    loadSymbols();
    if (!frontFn || !postFn) return false;
    ProcessSerialNumber psn = {0};
    if (GetProcessForPID(pid, &psn) != noErr) return false;
    uint64_t origin = originSpaceIfCrossSpace(window);
    ProcessSerialNumber previous = {0};
    if (origin && GetFrontProcess(&previous) != noErr) origin = 0;
    if (frontFn(&psn, window, 0x200) != kCGErrorSuccess) return false;
    // WindowServer may read 0x100 bytes despite the record's declared 0xf8 size.
    // The point is outside content so making the window key doesn't click its UI.
    uint8_t bytes[0x100] = {0};
    CGPoint point = CGPointMake(300000, 300000);
    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;
    memcpy(bytes + 0x10, &point, sizeof(point));
    memcpy(bytes + 0x20, &point, sizeof(point));
    memcpy(bytes + 0x3c, &window, sizeof(window));
    bytes[0x08] = 1;
    postFn(&psn, bytes);
    bytes[0x08] = 2;
    postFn(&psn, bytes);
    // Preserve the front app on the Space being left; the global front request can
    // otherwise change what macOS restores when the user returns to that Space.
    if (origin) spaceFrontFn(connectionFn(), origin, previous);
    return true;
}
#pragma clang diagnostic pop
