//
//  DOSupporterLicense.h
//  Dopamine
//
//  RC7: offline supporter entitlement verification.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
@import Security;
#import <CommonCrypto/CommonDigest.h>

static NSString * const DORHSupporterLicenseDefaultsKey = @"DORHSupporter.LicenseCode";
static NSString * const DORHSupporterLicenseDidChangeNotification = @"DORHSupporter.LicenseDidChange";
static NSString * const DORHSupporterLicenseErrorDomain = @"DORHSupporterLicense";

//
// Persistence V2
//
// NSUserDefaults lives inside the app data container and can disappear when
// some installers rebuild that container during an update. Keep a second,
// signed-license-backed state outside the application container so normal
// DopamineRH upgrades do not require supporter activation again.
//
static NSString * const DORHSupporterPersistentDirectoryPath =
    @"/var/mobile/Library/Application Support/DopamineRH";
static NSString * const DORHSupporterPersistentStateFilename =
    @"supporter-state.plist";
static NSString * const DORHSupporterPersistentDeviceCodeKey =
    @"DeviceCode";
static NSString * const DORHSupporterPersistentLicenseCodeKey =
    @"LicenseCode";

static inline NSError *DORHSupporterLicenseError(NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:DORHSupporterLicenseErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description ?: @"Invalid supporter license"}];
}

static inline NSString *DORHSupporterBase64URLToBase64(NSString *value)
{
    NSString *base64 = [[value stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
        stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSUInteger remainder = base64.length % 4;
    if (remainder != 0)
        base64 = [base64 stringByPaddingToLength:base64.length + (4 - remainder)
                                      withString:@"="
                                 startingAtIndex:0];
    return base64;
}

static inline NSData *DORHSupporterDecodeBase64URL(NSString *value)
{
    if (value.length == 0)
        return nil;
    return [[NSData alloc] initWithBase64EncodedString:DORHSupporterBase64URLToBase64(value)
                                                options:0];
}

static inline NSString *DORHSupporterPersistentStatePath(void)
{
    return [DORHSupporterPersistentDirectoryPath
        stringByAppendingPathComponent:DORHSupporterPersistentStateFilename];
}

static inline NSMutableDictionary<NSString *, id> *DORHSupporterReadPersistentState(void)
{
    NSDictionary *state =
        [NSDictionary dictionaryWithContentsOfFile:DORHSupporterPersistentStatePath()];

    if (![state isKindOfClass:NSDictionary.class])
        return [NSMutableDictionary dictionary];

    return [state mutableCopy];
}

static inline BOOL DORHSupporterWritePersistentState(NSDictionary<NSString *, id> *state)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSError *directoryError = nil;
    BOOL directoryReady =
        [fileManager createDirectoryAtPath:DORHSupporterPersistentDirectoryPath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:&directoryError];

    if (!directoryReady) {
        NSLog(@"[Supporter] unable to create persistent directory: %@",
              directoryError);
        return NO;
    }

    BOOL written =
        [state writeToFile:DORHSupporterPersistentStatePath()
                atomically:YES];

    if (!written)
        NSLog(@"[Supporter] unable to write persistent supporter state");

    return written;
}

static inline NSString *DORHSupporterPersistentString(NSString *key)
{
    id value = DORHSupporterReadPersistentState()[key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static inline BOOL DORHSupporterSetPersistentString(NSString *key, NSString *value)
{
    NSMutableDictionary<NSString *, id> *state =
        DORHSupporterReadPersistentState();

    if (value.length != 0)
        state[key] = value;
    else
        [state removeObjectForKey:key];

    return DORHSupporterWritePersistentState(state);
}

static inline NSString *DORHSupporterEmbeddedDeviceCode(NSString *licenseCode)
{
    NSString *trimmed =
        [licenseCode stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];

    NSArray<NSString *> *parts =
        [trimmed componentsSeparatedByString:@"."];

    if (parts.count != 3 || ![parts[0] isEqualToString:@"RH1"])
        return nil;

    NSData *payload = DORHSupporterDecodeBase64URL(parts[1]);
    if (payload.length == 0)
        return nil;

    id object = [NSJSONSerialization JSONObjectWithData:payload
                                                options:0
                                                  error:nil];

    if (![object isKindOfClass:NSDictionary.class])
        return nil;

    NSDictionary<NSString *, id> *info = object;
    NSString *product = info[@"product"];
    NSString *device = info[@"device"];

    if (![product isKindOfClass:NSString.class] ||
        ![product isEqualToString:@"DopamineRH"] ||
        ![device isKindOfClass:NSString.class] ||
        device.length == 0)
        return nil;

    return device;
}

static inline NSDictionary<NSString *, id> *
DORHSupporterVerifyLicenseCodeForDevice(NSString *licenseCode,
                                        NSString *expectedDeviceCode,
                                        NSError **error);

static inline NSString *DORHSupporterDeviceCode(void)
{
    static NSString *deviceCode = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        // From V2 onward this is the canonical device identifier.
        deviceCode =
            DORHSupporterPersistentString(
                DORHSupporterPersistentDeviceCodeKey);

        if (deviceCode.length != 0)
            return;

        //
        // Migration path for already activated RC7 installations.
        //
        // If identifierForVendor changed during an update but the old license
        // survived in NSUserDefaults, the signed license itself still contains
        // the original device code. Verify that signed payload against its own
        // device value before adopting it.
        //
        NSString *legacyLicense =
            DORHSupporterPersistentString(
                DORHSupporterPersistentLicenseCodeKey);

        if (legacyLicense.length == 0) {
            legacyLicense =
                [NSUserDefaults.standardUserDefaults
                    stringForKey:DORHSupporterLicenseDefaultsKey];
        }

        NSString *legacyDevice =
            DORHSupporterEmbeddedDeviceCode(legacyLicense);

        if (legacyDevice.length != 0 &&
            DORHSupporterVerifyLicenseCodeForDevice(
                legacyLicense, legacyDevice, NULL) != nil) {

            deviceCode = legacyDevice;

            DORHSupporterSetPersistentString(
                DORHSupporterPersistentDeviceCodeKey,
                deviceCode);

            if (legacyLicense.length != 0) {
                DORHSupporterSetPersistentString(
                    DORHSupporterPersistentLicenseCodeKey,
                    legacyLicense);
            }

            return;
        }

        //
        // Fresh installation: preserve the legacy RC7 algorithm exactly,
        // then persist its result so later app updates cannot change it.
        //
        NSString *vendorID =
            UIDevice.currentDevice.identifierForVendor.UUIDString;

        if (vendorID.length == 0)
            return;

        NSString *bundleID =
            NSBundle.mainBundle.bundleIdentifier ?:
            @"com.opa334.Dopamine-roothide";

        NSString *seed =
            [NSString stringWithFormat:@"%@|%@", vendorID, bundleID];

        NSData *seedData =
            [seed dataUsingEncoding:NSUTF8StringEncoding];

        unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
        CC_SHA256(seedData.bytes,
                  (CC_LONG)seedData.length,
                  digest);

        NSMutableString *hex =
            [NSMutableString stringWithCapacity:32];

        for (NSUInteger i = 0; i < 16; i++)
            [hex appendFormat:@"%02X", digest[i]];

        NSMutableArray<NSString *> *groups =
            [NSMutableArray arrayWithCapacity:8];

        for (NSUInteger i = 0; i < hex.length; i += 4) {
            [groups addObject:
                [hex substringWithRange:
                    NSMakeRange(i,
                        MIN((NSUInteger)4,
                            hex.length - i))]];
        }

        deviceCode = [groups componentsJoinedByString:@"-"];

        DORHSupporterSetPersistentString(
            DORHSupporterPersistentDeviceCodeKey,
            deviceCode);
    });

    return deviceCode;
}

static inline SecKeyRef DORHSupporterCreatePublicKey(void)
{
    // P-256 uncompressed ANSI X9.63 public key. The matching private key is
    // intentionally kept outside the app/repository and is only used by the
    // offline issuer script.
    static NSString * const publicKeyBase64 =
        @"BCmHM/nGP4wG1hJ4mOedvUeRutsHgL+qGAAWpjTO/bD0qY4QraFv/hzsQTV0jxx7fod1yu9iAC0LHiVxW39cRBg=";
    NSData *publicKeyData = [[NSData alloc] initWithBase64EncodedString:publicKeyBase64 options:0];
    if (publicKeyData.length != 65)
        return nil;

    NSDictionary *attributes = @{
        (__bridge id)kSecAttrKeyType : (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeyClass : (__bridge id)kSecAttrKeyClassPublic,
        (__bridge id)kSecAttrKeySizeInBits : @256,
    };

    CFErrorRef error = NULL;
    SecKeyRef publicKey = SecKeyCreateWithData((__bridge CFDataRef)publicKeyData,
                                               (__bridge CFDictionaryRef)attributes,
                                               &error);
    if (error)
        CFRelease(error);
    return publicKey;
}

static inline NSDictionary<NSString *, id> *
DORHSupporterVerifyLicenseCodeForDevice(NSString *licenseCode,
                                        NSString *expectedDeviceCode,
                                        NSError **error)
{
    NSString *trimmed = [licenseCode stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@"."];
    if (parts.count != 3 || ![parts[0] isEqualToString:@"RH1"]) {
        if (error) *error = DORHSupporterLicenseError(1, @"Invalid license format");
        return nil;
    }

    NSData *payload = DORHSupporterDecodeBase64URL(parts[1]);
    NSData *signature = DORHSupporterDecodeBase64URL(parts[2]);
    if (payload.length == 0 || signature.length == 0) {
        if (error) *error = DORHSupporterLicenseError(2, @"Invalid license data");
        return nil;
    }

    SecKeyRef publicKey = DORHSupporterCreatePublicKey();
    if (!publicKey) {
        if (error) *error = DORHSupporterLicenseError(3, @"License verifier unavailable");
        return nil;
    }

    CFErrorRef verifyError = NULL;
    BOOL verified = SecKeyVerifySignature(publicKey,
                                          kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                                          (__bridge CFDataRef)payload,
                                          (__bridge CFDataRef)signature,
                                          &verifyError);
    CFRelease(publicKey);
    if (verifyError)
        CFRelease(verifyError);

    if (!verified) {
        if (error) *error = DORHSupporterLicenseError(4, @"Invalid license signature");
        return nil;
    }

    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:payload options:0 error:&jsonError];
    if (![object isKindOfClass:NSDictionary.class]) {
        if (error) *error = DORHSupporterLicenseError(5, @"Invalid license payload");
        return nil;
    }

    NSDictionary<NSString *, id> *info = (NSDictionary<NSString *, id> *)object;
    NSNumber *version = info[@"v"];
    NSString *product = info[@"product"];
    NSString *supporterID = info[@"sid"];
    NSString *device = info[@"device"];
    NSArray *entitlements = info[@"ent"];

    if (![version isKindOfClass:NSNumber.class] || version.integerValue != 1 ||
        ![product isKindOfClass:NSString.class] || ![product isEqualToString:@"DopamineRH"] ||
        ![supporterID isKindOfClass:NSString.class] || supporterID.length == 0 ||
        ![device isKindOfClass:NSString.class] || device.length == 0 ||
        ![entitlements isKindOfClass:NSArray.class] || ![entitlements containsObject:@"custom_glass"]) {
        if (error) *error = DORHSupporterLicenseError(6, @"Unsupported license payload");
        return nil;
    }

    if (expectedDeviceCode.length == 0) {
        if (error) *error = DORHSupporterLicenseError(7, @"Device identifier unavailable");
        return nil;
    }

    if (![device isEqualToString:expectedDeviceCode]) {
        if (error) *error = DORHSupporterLicenseError(8, @"License is for another device");
        return nil;
    }

    return info;
}


static inline NSDictionary<NSString *, id> *
DORHSupporterVerifyLicenseCode(NSString *licenseCode, NSError **error)
{
    return DORHSupporterVerifyLicenseCodeForDevice(
        licenseCode,
        DORHSupporterDeviceCode(),
        error);
}

static inline NSDictionary<NSString *, id> *DORHSupporterCurrentLicenseInfo(void)
{
    NSString *persistentLicense =
        DORHSupporterPersistentString(
            DORHSupporterPersistentLicenseCodeKey);

    NSString *legacyLicense =
        [NSUserDefaults.standardUserDefaults
            stringForKey:DORHSupporterLicenseDefaultsKey];

    NSArray<NSString *> *candidates =
        persistentLicense.length != 0 &&
        legacyLicense.length != 0 &&
        ![persistentLicense isEqualToString:legacyLicense]
            ? @[persistentLicense, legacyLicense]
            : (persistentLicense.length != 0
                ? @[persistentLicense]
                : (legacyLicense.length != 0
                    ? @[legacyLicense]
                    : @[]));

    for (NSString *license in candidates) {
        NSDictionary<NSString *, id> *info =
            DORHSupporterVerifyLicenseCode(license, NULL);

        if (!info)
            continue;

        // Keep both stores synchronized during the migration period.
        DORHSupporterSetPersistentString(
            DORHSupporterPersistentLicenseCodeKey,
            license);

        [NSUserDefaults.standardUserDefaults
            setObject:license
               forKey:DORHSupporterLicenseDefaultsKey];

        [NSUserDefaults.standardUserDefaults synchronize];

        return info;
    }

    return nil;
}

static inline BOOL DORHSupporterIsVerified(void)
{
    return DORHSupporterCurrentLicenseInfo() != nil;
}

static inline NSString *DORHSupporterCurrentID(void)
{
    NSString *supporterID = DORHSupporterCurrentLicenseInfo()[@"sid"];
    return [supporterID isKindOfClass:NSString.class] ? supporterID : nil;
}

static inline BOOL DORHSupporterStoreLicenseCode(NSString *licenseCode, NSError **error)
{
    NSDictionary *info =
        DORHSupporterVerifyLicenseCode(licenseCode, error);

    if (!info)
        return NO;

    NSString *trimmed =
        [licenseCode stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];

    BOOL persisted =
        DORHSupporterSetPersistentString(
            DORHSupporterPersistentLicenseCodeKey,
            trimmed);

    if (!persisted) {
        NSLog(@"[Supporter] persistent license write failed; using NSUserDefaults fallback");
    }

    [NSUserDefaults.standardUserDefaults
        setObject:trimmed
           forKey:DORHSupporterLicenseDefaultsKey];

    [NSUserDefaults.standardUserDefaults synchronize];

    [[NSNotificationCenter defaultCenter]
        postNotificationName:
            DORHSupporterLicenseDidChangeNotification
                      object:nil];

    return YES;
}

static inline void DORHSupporterRemoveLicense(void)
{
    //
    // Deliberately keep the stable DeviceCode. Removing entitlement should not
    // turn the same physical device into a new licensing identity.
    //
    DORHSupporterSetPersistentString(
        DORHSupporterPersistentLicenseCodeKey,
        nil);

    [NSUserDefaults.standardUserDefaults
        removeObjectForKey:DORHSupporterLicenseDefaultsKey];

    [NSUserDefaults.standardUserDefaults synchronize];

    [[NSNotificationCenter defaultCenter]
        postNotificationName:
            DORHSupporterLicenseDidChangeNotification
                      object:nil];
}
