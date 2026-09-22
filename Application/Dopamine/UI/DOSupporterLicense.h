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

CFPropertyListRef MGCopyAnswer(CFStringRef property);

static NSString * const DORHSupporterLicenseDefaultsKey = @"DORHSupporter.LicenseCode";
static NSString * const DORHSupporterLicenseDidChangeNotification = @"DORHSupporter.LicenseDidChange";
static NSString * const DORHSupporterLicenseErrorDomain = @"DORHSupporterLicense";

static inline NSError *DORHSupporterLicenseError(NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:DORHSupporterLicenseErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description ?: @"Invalid supporter license"}];
}

//
// Hardware Identity: rh-hw-v1.
//
// UniqueChipID is used only in memory. The raw value is not persisted,
// displayed, logged, or used as a replacement for the legacy Device Code.
//
// Frozen protocol:
//   canonical ECID = 16-digit uppercase hexadecimal
//   SHA256("DopamineRH-HW-v1|" + canonical ECID)
//
// The protocol is independent of App version, Bundle ID, IDFV,
// installation path, and iOS version.
//
static inline NSDictionary<NSString *, id> *
DORHSupporterHardwareIdentityProbe(void)
{
    CFPropertyListRef rawAnswer =
        MGCopyAnswer(CFSTR("UniqueChipID"));

    if (!rawAnswer) {
        return @{
            @"available" : @NO,
            @"algorithm" : @"rh-hw-v1",
            @"hardware_id" : @"",
            @"hardware_hash" : @""
        };
    }

    id answer = (__bridge id)rawAnswer;

    if (![answer isKindOfClass:NSNumber.class]) {
        CFRelease(rawAnswer);

        return @{
            @"available" : @NO,
            @"algorithm" : @"rh-hw-v1",
            @"hardware_id" : @"",
            @"hardware_hash" : @""
        };
    }

    unsigned long long ecid =
        [(NSNumber *)answer unsignedLongLongValue];

    CFRelease(rawAnswer);

    if (ecid == 0) {
        return @{
            @"available" : @NO,
            @"algorithm" : @"rh-hw-v1",
            @"hardware_id" : @"",
            @"hardware_hash" : @""
        };
    }

    NSString *canonicalECID =
        [NSString stringWithFormat:@"%016llX", ecid];

    NSString *seed =
        [NSString stringWithFormat:
            @"DopamineRH-HW-v1|%@",
            canonicalECID];

    NSData *seedData =
        [seed dataUsingEncoding:NSUTF8StringEncoding];

    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};

    CC_SHA256(seedData.bytes,
              (CC_LONG)seedData.length,
              digest);

    NSMutableString *fullHash =
        [NSMutableString stringWithCapacity:64];

    for (NSUInteger i = 0;
         i < CC_SHA256_DIGEST_LENGTH;
         i++) {
        [fullHash appendFormat:@"%02X", digest[i]];
    }

    NSString *shortHex =
        [fullHash substringToIndex:32];

    NSMutableArray<NSString *> *groups =
        [NSMutableArray arrayWithCapacity:8];

    for (NSUInteger i = 0;
         i < shortHex.length;
         i += 4) {
        [groups addObject:
            [shortHex substringWithRange:
                NSMakeRange(i, 4)]];
    }

    NSString *hardwareID =
        [NSString stringWithFormat:
            @"D2-%@",
            [groups componentsJoinedByString:@"-"]];

    return @{
        @"available" : @YES,
        @"algorithm" : @"rh-hw-v1",
        @"hardware_id" : hardwareID,
        @"hardware_hash" : fullHash
    };
}

//
// Phase 2A Device Key feasibility probe.
//
// Fixed logical key tag. This tag must not change with App versions.
//
static NSString * const DORHSupporterDeviceKeyTag =
    @"com.dopaminerh.supporter.devicekey.v1";

static NSString * const DORHSupporterDeviceKeyAccessGroup =
    @"com.dopaminerh.supporter.devicekey";

static inline BOOL
DORHSupporterDeviceKeyIsSecureEnclaveP256PrivateKey(SecKeyRef privateKey)
{
    if (!privateKey)
        return NO;

    CFDictionaryRef attributesRef =
        SecKeyCopyAttributes(privateKey);

    if (!attributesRef)
        return NO;

    NSDictionary *attributes =
        (__bridge NSDictionary *)attributesRef;

    id keyType =
        attributes[(__bridge id)kSecAttrKeyType];

    id keyClass =
        attributes[(__bridge id)kSecAttrKeyClass];

    NSNumber *keySize =
        attributes[(__bridge id)kSecAttrKeySizeInBits];

    id tokenID =
        attributes[(__bridge id)kSecAttrTokenID];

    BOOL valid =
        [keyType isEqual:(__bridge id)kSecAttrKeyTypeECSECPrimeRandom] &&
        [keyClass isEqual:(__bridge id)kSecAttrKeyClassPrivate] &&
        [keySize unsignedIntegerValue] == 256 &&
        [tokenID isEqual:(__bridge id)kSecAttrTokenIDSecureEnclave];

    CFRelease(attributesRef);

    return valid;
}

static inline NSData *
DORHSupporterCopyDevicePublicKeyData(SecKeyRef publicKey,
                                     NSString **failureStage,
                                     NSInteger *failureCode)
{
    if (failureStage)
        *failureStage = nil;

    if (failureCode)
        *failureCode = 0;

    if (!publicKey) {
        if (failureStage)
            *failureStage = @"export-public-key";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    CFErrorRef exportError = NULL;

    CFDataRef publicDataRef =
        SecKeyCopyExternalRepresentation(
            publicKey,
            &exportError);

    if (!publicDataRef) {
        NSInteger code =
            exportError
                ? (NSInteger)CFErrorGetCode(exportError)
                : -1;

        if (exportError)
            CFRelease(exportError);

        if (failureStage)
            *failureStage = @"export-public-key";

        if (failureCode)
            *failureCode = code;

        return nil;
    }

    if (exportError)
        CFRelease(exportError);

    NSData *publicData =
        CFBridgingRelease(publicDataRef);

    // P-256 ANSI X9.63 uncompressed public key:
    // 0x04 || X(32 bytes) || Y(32 bytes)
    if (publicData.length != 65) {
        if (failureStage)
            *failureStage = @"public-key-format";

        if (failureCode)
            *failureCode = (NSInteger)publicData.length;

        return nil;
    }

    return publicData;
}

static inline NSDictionary<NSString *, NSString *> *
DORHSupporterDeviceKeyFingerprint(NSData *publicData)
{
    if (publicData.length != 65)
        return nil;

    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};

    CC_SHA256(publicData.bytes,
              (CC_LONG)publicData.length,
              digest);

    NSMutableString *fullHash =
        [NSMutableString stringWithCapacity:64];

    for (NSUInteger i = 0;
         i < CC_SHA256_DIGEST_LENGTH;
         i++) {
        [fullHash appendFormat:@"%02X", digest[i]];
    }

    NSString *shortHex =
        [fullHash substringToIndex:32];

    NSMutableArray<NSString *> *groups =
        [NSMutableArray arrayWithCapacity:8];

    for (NSUInteger i = 0;
         i < shortHex.length;
         i += 4) {
        [groups addObject:
            [shortHex substringWithRange:
                NSMakeRange(i, 4)]];
    }

    NSString *fingerprint =
        [NSString stringWithFormat:
            @"K1-%@",
            [groups componentsJoinedByString:@"-"]];

    return @{
        @"fingerprint" : fingerprint,
        @"key_fingerprint" : fullHash
    };
}

static inline NSData *
DORHSupporterSignWithDeviceKey(SecKeyRef privateKey,
                               NSData *message,
                               NSInteger *failureCode)
{
    if (failureCode)
        *failureCode = 0;

    if (!privateKey || !message) {
        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    CFErrorRef signError = NULL;

    CFDataRef signatureRef =
        SecKeyCreateSignature(
            privateKey,
            kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
            (__bridge CFDataRef)message,
            &signError);

    if (!signatureRef) {
        NSInteger code =
            signError
                ? (NSInteger)CFErrorGetCode(signError)
                : -1;

        if (signError)
            CFRelease(signError);

        if (failureCode)
            *failureCode = code;

        return nil;
    }

    if (signError)
        CFRelease(signError);

    return CFBridgingRelease(signatureRef);
}

static inline BOOL
DORHSupporterVerifyDeviceKeySignature(SecKeyRef publicKey,
                                      NSData *message,
                                      NSData *signature,
                                      NSInteger *failureCode)
{
    if (failureCode)
        *failureCode = 0;

    if (!publicKey || !message || !signature) {
        if (failureCode)
            *failureCode = -1;

        return NO;
    }

    CFErrorRef verifyError = NULL;

    BOOL valid =
        SecKeyVerifySignature(
            publicKey,
            kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
            (__bridge CFDataRef)message,
            (__bridge CFDataRef)signature,
            &verifyError);

    if (!valid) {
        NSInteger code =
            verifyError
                ? (NSInteger)CFErrorGetCode(verifyError)
                : -1;

        if (verifyError)
            CFRelease(verifyError);

        if (failureCode)
            *failureCode = code;

        return NO;
    }

    if (verifyError)
        CFRelease(verifyError);

    return YES;
}

static inline BOOL
DORHSupporterDeviceKeySignatureSelfTest(SecKeyRef privateKey,
                                        SecKeyRef publicKey,
                                        NSString **failureStage,
                                        NSInteger *failureCode)
{
    if (failureStage)
        *failureStage = nil;

    if (failureCode)
        *failureCode = 0;

    NSData *message =
        [@"DopamineRH-DeviceKey-Probe-v1"
            dataUsingEncoding:NSUTF8StringEncoding];

    NSInteger code = 0;

    NSData *signature =
        DORHSupporterSignWithDeviceKey(
            privateKey,
            message,
            &code);

    if (!signature) {
        if (failureStage)
            *failureStage = @"sign";

        if (failureCode)
            *failureCode = code;

        return NO;
    }

    if (!DORHSupporterVerifyDeviceKeySignature(
            publicKey,
            message,
            signature,
            &code)) {
        if (failureStage)
            *failureStage = @"verify-self-test";

        if (failureCode)
            *failureCode = code;

        return NO;
    }

    return YES;
}

static inline SecKeyRef
DORHSupporterCopyOrCreateDevicePrivateKey(BOOL *created,
                                          NSString **failureStage,
                                          NSInteger *failureCode)
{
    if (created)
        *created = NO;

    if (failureStage)
        *failureStage = nil;

    if (failureCode)
        *failureCode = 0;

    NSData *tagData =
        [DORHSupporterDeviceKeyTag dataUsingEncoding:NSUTF8StringEncoding];

    if (tagData.length == 0) {
        if (failureStage)
            *failureStage = @"tag";

        if (failureCode)
            *failureCode = -1;

        return NULL;
    }

    NSDictionary *query = @{
        (__bridge id)kSecClass :
            (__bridge id)kSecClassKey,
        (__bridge id)kSecAttrKeyType :
            (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeyClass :
            (__bridge id)kSecAttrKeyClassPrivate,
        (__bridge id)kSecAttrApplicationTag :
            tagData,
        (__bridge id)kSecAttrAccessGroup :
            DORHSupporterDeviceKeyAccessGroup,
        (__bridge id)kSecReturnRef :
            @YES
    };

    CFTypeRef existingItem = NULL;

    OSStatus lookupStatus =
        SecItemCopyMatching(
            (__bridge CFDictionaryRef)query,
            &existingItem);

    if (lookupStatus == errSecSuccess) {
        if (!existingItem) {
            if (failureStage)
                *failureStage = @"lookup-empty";

            if (failureCode)
                *failureCode = -1;

            return NULL;
        }

        // SecItemCopyMatching returned a retained reference.
        // The caller owns it and must CFRelease().
        return (SecKeyRef)existingItem;
    }

    if (lookupStatus != errSecItemNotFound) {
        if (existingItem)
            CFRelease(existingItem);

        if (failureStage)
            *failureStage = @"lookup";

        if (failureCode)
            *failureCode = (NSInteger)lookupStatus;

        return NULL;
    }

    CFErrorRef accessError = NULL;

    SecAccessControlRef accessControl =
        SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAccessControlPrivateKeyUsage,
            &accessError);

    if (!accessControl) {
        NSInteger code =
            accessError
                ? (NSInteger)CFErrorGetCode(accessError)
                : -1;

        if (accessError)
            CFRelease(accessError);

        if (failureStage)
            *failureStage = @"access-control";

        if (failureCode)
            *failureCode = code;

        return NULL;
    }

    if (accessError)
        CFRelease(accessError);

    NSDictionary *privateAttributes = @{
        (__bridge id)kSecAttrIsPermanent :
            @YES,
        (__bridge id)kSecAttrApplicationTag :
            tagData,
        (__bridge id)kSecAttrAccessGroup :
            DORHSupporterDeviceKeyAccessGroup,
        (__bridge id)kSecAttrAccessControl :
            (__bridge id)accessControl
    };

    NSDictionary *attributes = @{
        (__bridge id)kSecAttrKeyType :
            (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeySizeInBits :
            @256,
        (__bridge id)kSecAttrTokenID :
            (__bridge id)kSecAttrTokenIDSecureEnclave,
        (__bridge id)kSecPrivateKeyAttrs :
            privateAttributes
    };

    CFErrorRef createError = NULL;

    SecKeyRef privateKey =
        SecKeyCreateRandomKey(
            (__bridge CFDictionaryRef)attributes,
            &createError);

    CFRelease(accessControl);

    if (!privateKey) {
        NSInteger code =
            createError
                ? (NSInteger)CFErrorGetCode(createError)
                : -1;

        if (createError)
            CFRelease(createError);

        if (failureStage)
            *failureStage = @"create-key";

        if (failureCode)
            *failureCode = code;

        return NULL;
    }

    if (createError)
        CFRelease(createError);

    if (created)
        *created = YES;

    // SecKeyCreateRandomKey follows the Create Rule.
    // The caller owns the returned key and must CFRelease().
    return privateKey;
}

static inline NSDictionary<NSString *, id> *
DORHSupporterDeviceKeyProbeFailure(NSString *stage, NSInteger errorCode)
{
    return @{
        @"available" : @NO,
        @"algorithm" : @"p256",
        @"storage" : @"Secure Enclave",
        @"tag" : DORHSupporterDeviceKeyTag,
        @"fingerprint" : @"",
        @"key_fingerprint" : @"",
        @"created" : @NO,
        @"signature_self_test" : @NO,
        @"stage" : stage ?: @"unknown",
        @"error_code" : @(errorCode)
    };
}

static inline NSDictionary<NSString *, id> *
DORHSupporterDeviceKeyProbe(void)
{
    BOOL created = NO;
    NSString *privateKeyFailureStage = nil;
    NSInteger privateKeyFailureCode = 0;

    SecKeyRef privateKey =
        DORHSupporterCopyOrCreateDevicePrivateKey(
            &created,
            &privateKeyFailureStage,
            &privateKeyFailureCode);

    if (!privateKey) {
        return DORHSupporterDeviceKeyProbeFailure(
            privateKeyFailureStage,
            privateKeyFailureCode);
    }

    if (!DORHSupporterDeviceKeyIsSecureEnclaveP256PrivateKey(privateKey)) {
        CFRelease(privateKey);

        return DORHSupporterDeviceKeyProbeFailure(
            @"secure-enclave-key-validation",
            -2);
    }

    SecKeyRef publicKey =
        SecKeyCopyPublicKey(privateKey);

    if (!publicKey) {
        CFRelease(privateKey);

        return DORHSupporterDeviceKeyProbeFailure(
            @"copy-public-key",
            -1);
    }

    NSString *publicDataFailureStage = nil;
    NSInteger publicDataFailureCode = 0;

    NSData *publicData =
        DORHSupporterCopyDevicePublicKeyData(
            publicKey,
            &publicDataFailureStage,
            &publicDataFailureCode);

    if (!publicData) {
        CFRelease(publicKey);
        CFRelease(privateKey);

        return DORHSupporterDeviceKeyProbeFailure(
            publicDataFailureStage,
            publicDataFailureCode);
    }

    NSString *selfTestFailureStage = nil;
    NSInteger selfTestFailureCode = 0;

    if (!DORHSupporterDeviceKeySignatureSelfTest(
            privateKey,
            publicKey,
            &selfTestFailureStage,
            &selfTestFailureCode)) {
        CFRelease(publicKey);
        CFRelease(privateKey);

        return DORHSupporterDeviceKeyProbeFailure(
            selfTestFailureStage,
            selfTestFailureCode);
    }

    NSDictionary<NSString *, NSString *> *fingerprintInfo =
        DORHSupporterDeviceKeyFingerprint(publicData);

    NSString *fingerprint =
        fingerprintInfo[@"fingerprint"];

    NSString *fullHash =
        fingerprintInfo[@"key_fingerprint"];

    CFRelease(publicKey);
    CFRelease(privateKey);

    return @{
        @"available" : @YES,
        @"algorithm" : @"p256",
        @"storage" : @"Secure Enclave",
        @"tag" : DORHSupporterDeviceKeyTag,
        @"fingerprint" : fingerprint,
        @"key_fingerprint" : fullHash,
        @"created" : @(created),
        @"signature_self_test" : @YES,
        @"stage" : @"ready",
        @"error_code" : @0
    };
}

//
// Phase 3A Device Proof protocol: RHC1 / RHP1 v1.
//
// RHC1 is a server-generated, single-use challenge. The client treats the
// exact canonical RHC1 bytes as immutable protocol input. RHP1 binds that
// exact challenge to rh-hw-v1, the Device Key public-key fingerprint, and a
// possession proof produced by the existing Secure Enclave private key.
//
// This layer deliberately does not define RH2 entitlement semantics.
//
static NSString * const DORHSupporterRHC1Audience =
    @"com.dopaminerh.supporter.device-proof";

static NSString * const DORHSupporterRHP1SignatureAlgorithm =
    @"ecdsa-p256-sha256-x962";

static NSString * const DORHSupporterRHP1SigningDomain =
    @"DopamineRH-RHP1-Sign-v1";

static const NSUInteger DORHSupporterRHC1MaximumWireBytes = 1024;
static const NSUInteger DORHSupporterRHP1MaximumWireBytes = 4096;
static const long long DORHSupporterRHC1MaximumLifetimeSeconds = 900;

static inline NSString *
DORHSupporterSHA256UpperHex(NSData *data)
{
    if (!data)
        return nil;

    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};

    CC_SHA256(data.bytes,
              (CC_LONG)data.length,
              digest);

    NSMutableString *hex =
        [NSMutableString stringWithCapacity:64];

    for (NSUInteger i = 0;
         i < CC_SHA256_DIGEST_LENGTH;
         i++) {
        [hex appendFormat:@"%02X", digest[i]];
    }

    return hex;
}

static inline BOOL
DORHSupporterIsUppercaseHexString(NSString *value,
                                  NSUInteger expectedLength)
{
    if (![value isKindOfClass:NSString.class] ||
        value.length != expectedLength)
        return NO;

    static NSCharacterSet *invalidCharacters = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        invalidCharacters =
            [[NSCharacterSet characterSetWithCharactersInString:
                @"0123456789ABCDEF"] invertedSet];
    });

    return
        [value rangeOfCharacterFromSet:invalidCharacters].location ==
        NSNotFound;
}

static inline NSString *
DORHSupporterEncodeBase64URL(NSData *data)
{
    if (!data)
        return nil;

    NSString *value =
        [data base64EncodedStringWithOptions:0];

    value =
        [[value stringByReplacingOccurrencesOfString:@"+"
                                          withString:@"-"]
            stringByReplacingOccurrencesOfString:@"/"
                                       withString:@"_"];

    while ([value hasSuffix:@"="])
        value = [value substringToIndex:value.length - 1];

    return value;
}

static inline NSDictionary<NSString *, id> *
DORHSupporterParseRHC1Challenge(NSData *challengeData,
                                NSString **failureStage,
                                NSInteger *failureCode)
{
    if (failureStage)
        *failureStage = nil;

    if (failureCode)
        *failureCode = 0;

    if (!challengeData || challengeData.length == 0) {
        if (failureStage)
            *failureStage = @"rhc1-empty";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    if (challengeData.length > DORHSupporterRHC1MaximumWireBytes) {
        if (failureStage)
            *failureStage = @"rhc1-size";

        if (failureCode)
            *failureCode = (NSInteger)challengeData.length;

        return nil;
    }

    NSString *wire =
        [[NSString alloc] initWithData:challengeData
                              encoding:NSUTF8StringEncoding];

    if (!wire) {
        if (failureStage)
            *failureStage = @"rhc1-utf8";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    NSError *jsonError = nil;
    id object =
        [NSJSONSerialization JSONObjectWithData:challengeData
                                        options:0
                                          error:&jsonError];

    if (![object isKindOfClass:NSDictionary.class]) {
        if (failureStage)
            *failureStage = @"rhc1-json";

        if (failureCode)
            *failureCode = jsonError ? jsonError.code : -1;

        return nil;
    }

    NSDictionary<NSString *, id> *info = object;

    if (info.count != 7) {
        if (failureStage)
            *failureStage = @"rhc1-fields";

        if (failureCode)
            *failureCode = (NSInteger)info.count;

        return nil;
    }

    NSString *type = info[@"type"];
    NSNumber *version = info[@"version"];
    NSString *challengeID = info[@"challenge_id"];
    NSString *nonce = info[@"nonce"];
    NSNumber *issuedAtNumber = info[@"issued_at"];
    NSNumber *expiresAtNumber = info[@"expires_at"];
    NSString *audience = info[@"audience"];

    if (![type isKindOfClass:NSString.class] ||
        ![type isEqualToString:@"RHC1"] ||
        ![version isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() ||
        version.longLongValue != 1 ||
        !DORHSupporterIsUppercaseHexString(challengeID, 32) ||
        !DORHSupporterIsUppercaseHexString(nonce, 64) ||
        ![issuedAtNumber isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)issuedAtNumber) == CFBooleanGetTypeID() ||
        ![expiresAtNumber isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)expiresAtNumber) == CFBooleanGetTypeID() ||
        ![audience isKindOfClass:NSString.class] ||
        ![audience isEqualToString:DORHSupporterRHC1Audience]) {
        if (failureStage)
            *failureStage = @"rhc1-values";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    long long issuedAt = issuedAtNumber.longLongValue;
    long long expiresAt = expiresAtNumber.longLongValue;

    if (issuedAt < 0 ||
        expiresAt <= issuedAt ||
        expiresAt - issuedAt > DORHSupporterRHC1MaximumLifetimeSeconds) {
        if (failureStage)
            *failureStage = @"rhc1-time";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    NSString *canonical =
        [NSString stringWithFormat:
            @"{\"type\":\"RHC1\",\"version\":1,\"challenge_id\":\"%@\",\"nonce\":\"%@\",\"issued_at\":%lld,\"expires_at\":%lld,\"audience\":\"%@\"}",
            challengeID,
            nonce,
            issuedAt,
            expiresAt,
            DORHSupporterRHC1Audience];

    NSData *canonicalData =
        [canonical dataUsingEncoding:NSUTF8StringEncoding];

    // Requiring byte-for-byte equality rejects alternate field order,
    // whitespace, duplicate keys, unknown keys, alternate number encodings,
    // BOMs, and other serializer-dependent representations.
    if (![challengeData isEqualToData:canonicalData]) {
        if (failureStage)
            *failureStage = @"rhc1-canonical";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    NSString *challengeHash =
        DORHSupporterSHA256UpperHex(challengeData);

    if (challengeHash.length != 64) {
        if (failureStage)
            *failureStage = @"rhc1-hash";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    return @{
        @"type" : @"RHC1",
        @"version" : @1,
        @"challenge_id" : challengeID,
        @"nonce" : nonce,
        @"issued_at" : @(issuedAt),
        @"expires_at" : @(expiresAt),
        @"audience" : DORHSupporterRHC1Audience,
        @"challenge_hash" : challengeHash,
        @"canonical_data" : challengeData
    };
}

static inline NSData *
DORHSupporterCreateRHP1Proof(NSData *challengeData,
                             NSString **failureStage,
                             NSInteger *failureCode)
{
    if (failureStage)
        *failureStage = nil;

    if (failureCode)
        *failureCode = 0;

    NSString *stage = nil;
    NSInteger code = 0;

    NSDictionary<NSString *, id> *challenge =
        DORHSupporterParseRHC1Challenge(
            challengeData,
            &stage,
            &code);

    if (!challenge) {
        if (failureStage)
            *failureStage = stage ?: @"rhc1";

        if (failureCode)
            *failureCode = code;

        return nil;
    }

    NSDictionary<NSString *, id> *hardware =
        DORHSupporterHardwareIdentityProbe();

    NSString *hardwareProtocol = hardware[@"algorithm"];
    NSString *hardwareHash = hardware[@"hardware_hash"];

    if (![hardware[@"available"] boolValue] ||
        ![hardwareProtocol isEqualToString:@"rh-hw-v1"] ||
        !DORHSupporterIsUppercaseHexString(hardwareHash, 64)) {
        if (failureStage)
            *failureStage = @"hardware-identity";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    BOOL created = NO;
    NSString *privateKeyFailureStage = nil;
    NSInteger privateKeyFailureCode = 0;

    SecKeyRef privateKey =
        DORHSupporterCopyOrCreateDevicePrivateKey(
            &created,
            &privateKeyFailureStage,
            &privateKeyFailureCode);

    if (!privateKey) {
        if (failureStage)
            *failureStage = privateKeyFailureStage ?: @"device-key";

        if (failureCode)
            *failureCode = privateKeyFailureCode;

        return nil;
    }

    if (!DORHSupporterDeviceKeyIsSecureEnclaveP256PrivateKey(privateKey)) {
        CFRelease(privateKey);

        if (failureStage)
            *failureStage = @"secure-enclave-key-validation";

        if (failureCode)
            *failureCode = -2;

        return nil;
    }

    SecKeyRef publicKey =
        SecKeyCopyPublicKey(privateKey);

    if (!publicKey) {
        CFRelease(privateKey);

        if (failureStage)
            *failureStage = @"copy-public-key";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    NSString *publicDataFailureStage = nil;
    NSInteger publicDataFailureCode = 0;

    NSData *publicData =
        DORHSupporterCopyDevicePublicKeyData(
            publicKey,
            &publicDataFailureStage,
            &publicDataFailureCode);

    if (!publicData) {
        CFRelease(publicKey);
        CFRelease(privateKey);

        if (failureStage)
            *failureStage = publicDataFailureStage ?: @"public-key";

        if (failureCode)
            *failureCode = publicDataFailureCode;

        return nil;
    }

    const uint8_t *publicBytes = publicData.bytes;

    if (publicData.length != 65 ||
        !publicBytes ||
        publicBytes[0] != 0x04) {
        CFRelease(publicKey);
        CFRelease(privateKey);

        if (failureStage)
            *failureStage = @"public-key-format";

        if (failureCode)
            *failureCode = (NSInteger)publicData.length;

        return nil;
    }

    NSDictionary<NSString *, NSString *> *fingerprintInfo =
        DORHSupporterDeviceKeyFingerprint(publicData);

    NSString *keyFingerprint =
        fingerprintInfo[@"key_fingerprint"];

    if (!DORHSupporterIsUppercaseHexString(keyFingerprint, 64)) {
        CFRelease(publicKey);
        CFRelease(privateKey);

        if (failureStage)
            *failureStage = @"key-fingerprint";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    NSString *publicKeyBase64URL =
        DORHSupporterEncodeBase64URL(publicData);

    if (publicKeyBase64URL.length == 0 ||
        [publicKeyBase64URL containsString:@"="]) {
        CFRelease(publicKey);
        CFRelease(privateKey);

        if (failureStage)
            *failureStage = @"public-key-encoding";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    NSString *challengeID = challenge[@"challenge_id"];
    NSString *challengeHash = challenge[@"challenge_hash"];

    NSString *unsignedWire =
        [NSString stringWithFormat:
            @"{\"type\":\"RHP1\",\"version\":1,\"challenge_id\":\"%@\",\"challenge_hash\":\"%@\",\"hardware_protocol\":\"rh-hw-v1\",\"hardware_hash\":\"%@\",\"key_fingerprint\":\"%@\",\"public_key\":\"%@\",\"signature_algorithm\":\"%@\"}",
            challengeID,
            challengeHash,
            hardwareHash,
            keyFingerprint,
            publicKeyBase64URL,
            DORHSupporterRHP1SignatureAlgorithm];

    NSData *unsignedData =
        [unsignedWire dataUsingEncoding:NSUTF8StringEncoding];

    NSData *domainData =
        [DORHSupporterRHP1SigningDomain
            dataUsingEncoding:NSASCIIStringEncoding];

    if (!unsignedData || !domainData) {
        CFRelease(publicKey);
        CFRelease(privateKey);

        if (failureStage)
            *failureStage = @"proof-canonical";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    NSMutableData *signedMessage =
        [NSMutableData dataWithCapacity:
            domainData.length + 1 + unsignedData.length];

    [signedMessage appendData:domainData];

    const uint8_t separator = 0;
    [signedMessage appendBytes:&separator length:1];
    [signedMessage appendData:unsignedData];

    NSInteger signFailureCode = 0;
    NSData *signature =
        DORHSupporterSignWithDeviceKey(
            privateKey,
            signedMessage,
            &signFailureCode);

    if (!signature) {
        CFRelease(publicKey);
        CFRelease(privateKey);

        if (failureStage)
            *failureStage = @"proof-sign";

        if (failureCode)
            *failureCode = signFailureCode;

        return nil;
    }

    // Verify the freshly generated proof locally before returning it. This is
    // not a server trust decision; it catches unexpected signing/key failures
    // while both retained key references are still available.
    NSInteger verifyFailureCode = 0;
    BOOL localSignatureValid =
        DORHSupporterVerifyDeviceKeySignature(
            publicKey,
            signedMessage,
            signature,
            &verifyFailureCode);

    if (!localSignatureValid) {
        CFRelease(publicKey);
        CFRelease(privateKey);

        if (failureStage)
            *failureStage = @"proof-self-verify";

        if (failureCode)
            *failureCode = verifyFailureCode;

        return nil;
    }

    NSString *signatureBase64URL =
        DORHSupporterEncodeBase64URL(signature);

    if (signatureBase64URL.length == 0 ||
        [signatureBase64URL containsString:@"="]) {
        CFRelease(publicKey);
        CFRelease(privateKey);

        if (failureStage)
            *failureStage = @"signature-encoding";

        if (failureCode)
            *failureCode = -1;

        return nil;
    }

    NSString *proofWire =
        [NSString stringWithFormat:
            @"{\"type\":\"RHP1\",\"version\":1,\"challenge_id\":\"%@\",\"challenge_hash\":\"%@\",\"hardware_protocol\":\"rh-hw-v1\",\"hardware_hash\":\"%@\",\"key_fingerprint\":\"%@\",\"public_key\":\"%@\",\"signature_algorithm\":\"%@\",\"signature\":\"%@\"}",
            challengeID,
            challengeHash,
            hardwareHash,
            keyFingerprint,
            publicKeyBase64URL,
            DORHSupporterRHP1SignatureAlgorithm,
            signatureBase64URL];

    NSData *proofData =
        [proofWire dataUsingEncoding:NSUTF8StringEncoding];

    CFRelease(publicKey);
    CFRelease(privateKey);

    if (!proofData ||
        proofData.length > DORHSupporterRHP1MaximumWireBytes) {
        if (failureStage)
            *failureStage = @"proof-size";

        if (failureCode)
            *failureCode = proofData ? (NSInteger)proofData.length : -1;

        return nil;
    }

    (void)created;

    return proofData;
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
