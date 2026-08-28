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

static inline NSString *DORHSupporterDeviceCode(void)
{
    static NSString *deviceCode = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *vendorID = UIDevice.currentDevice.identifierForVendor.UUIDString;
        if (vendorID.length == 0)
            return;

        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"com.opa334.Dopamine-roothide";
        NSString *seed = [NSString stringWithFormat:@"%@|%@", vendorID, bundleID];
        NSData *seedData = [seed dataUsingEncoding:NSUTF8StringEncoding];

        unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
        CC_SHA256(seedData.bytes, (CC_LONG)seedData.length, digest);

        NSMutableString *hex = [NSMutableString stringWithCapacity:32];
        for (NSUInteger i = 0; i < 16; i++)
            [hex appendFormat:@"%02X", digest[i]];

        NSMutableArray<NSString *> *groups = [NSMutableArray arrayWithCapacity:8];
        for (NSUInteger i = 0; i < hex.length; i += 4)
            [groups addObject:[hex substringWithRange:NSMakeRange(i, MIN((NSUInteger)4, hex.length - i))]];
        deviceCode = [groups componentsJoinedByString:@"-"];
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

static inline NSDictionary<NSString *, id> *DORHSupporterVerifyLicenseCode(NSString *licenseCode,
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

    NSString *currentDeviceCode = DORHSupporterDeviceCode();
    if (currentDeviceCode.length == 0) {
        if (error) *error = DORHSupporterLicenseError(7, @"Device identifier unavailable");
        return nil;
    }

    if (![device isEqualToString:currentDeviceCode]) {
        if (error) *error = DORHSupporterLicenseError(8, @"License is for another device");
        return nil;
    }

    return info;
}

static inline NSDictionary<NSString *, id> *DORHSupporterCurrentLicenseInfo(void)
{
    NSString *storedLicense = [NSUserDefaults.standardUserDefaults stringForKey:DORHSupporterLicenseDefaultsKey];
    if (storedLicense.length == 0)
        return nil;
    return DORHSupporterVerifyLicenseCode(storedLicense, NULL);
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
    NSDictionary *info = DORHSupporterVerifyLicenseCode(licenseCode, error);
    if (!info)
        return NO;

    NSString *trimmed = [licenseCode stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [NSUserDefaults.standardUserDefaults setObject:trimmed forKey:DORHSupporterLicenseDefaultsKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:DORHSupporterLicenseDidChangeNotification object:nil];
    return YES;
}

static inline void DORHSupporterRemoveLicense(void)
{
    [NSUserDefaults.standardUserDefaults removeObjectForKey:DORHSupporterLicenseDefaultsKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:DORHSupporterLicenseDidChangeNotification object:nil];
}
