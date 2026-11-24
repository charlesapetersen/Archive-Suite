#import "KeychainQuery.h"

// The app's existing items live in the file-based Keychain, which can ask to unlock a keychain
// even with an LAContext that disallows interaction. Search only unlocked keychains, and disable
// item authorization dialogs for the duration of the lookup. KeychainHelper serializes its operations.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static CFMutableArrayRef CopyUnlockedKeychains(CFDictionaryRef query) {
    CFArrayRef searchList = CFDictionaryGetValue(query, kSecMatchSearchList);
    if (searchList) {
        CFRetain(searchList);
    } else if (SecKeychainCopySearchList(&searchList) != errSecSuccess) {
        return NULL;
    }
    if (!searchList) { return NULL; }
    CFMutableArrayRef unlocked = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex index = 0; index < CFArrayGetCount(searchList); index++) {
        SecKeychainRef keychain = (SecKeychainRef)CFArrayGetValueAtIndex(searchList, index);
        SecKeychainStatus status;
        if (SecKeychainGetStatus(keychain, &status) == errSecSuccess && (status & kSecUnlockStateStatus)) {
            CFArrayAppendValue(unlocked, keychain);
        }
    }
    CFRelease(searchList);
    return unlocked;
}

CFTypeRef ArchiveCopyKeychainItemQuietly(CFDictionaryRef query) {
    Boolean wasAllowed;
    if (SecKeychainGetUserInteractionAllowed(&wasAllowed) != errSecSuccess
        || SecKeychainSetUserInteractionAllowed(false) != errSecSuccess) { return NULL; }

    CFTypeRef result = NULL;
    CFMutableArrayRef unlocked = CopyUnlockedKeychains(query);
    if (unlocked && CFArrayGetCount(unlocked) > 0) {
        CFMutableDictionaryRef quietQuery = CFDictionaryCreateMutableCopy(NULL, 0, query);
        CFDictionarySetValue(quietQuery, kSecMatchSearchList, unlocked);
        OSStatus status = SecItemCopyMatching(quietQuery, &result);
        if (status != errSecSuccess && result) {
            CFRelease(result);
            result = NULL;
        }
        CFRelease(quietQuery);
    }
    if (unlocked) { CFRelease(unlocked); }
    SecKeychainSetUserInteractionAllowed(wasAllowed);
    return result;
}
#pragma clang diagnostic pop
