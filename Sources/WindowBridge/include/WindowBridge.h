#pragma once
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
CGWindowID ATWindowID(AXUIElementRef element);
bool ATFocusWindow(pid_t pid, CGWindowID window);
CFArrayRef ATCopyAllWindowInfo(void) CF_RETURNS_RETAINED;
CFArrayRef ATCopyOrderedWindowIDs(void) CF_RETURNS_RETAINED;
CFDictionaryRef ATCopyWindowElements(pid_t pid, CFArrayRef windowIDs) CF_RETURNS_RETAINED;
