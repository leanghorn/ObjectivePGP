//
//  Copyright (c) Marcin Krzyżanowski. All rights reserved.
//
//  THIS SOURCE CODE AND ANY ACCOMPANYING DOCUMENTATION ARE PROTECTED BY
//  INTERNATIONAL COPYRIGHT LAW. USAGE IS BOUND TO THE LICENSE AGREEMENT.
//  This notice may not be removed from this file.
//

//  MDC

#import "PGPModificationDetectionCodePacket.h"
#import "NSData+PGPUtils.h"
#import "PGPMacros+Private.h"
#import "PGPFoundation.h"

#import <CommonCrypto/CommonCrypto.h>

NS_ASSUME_NONNULL_BEGIN

@interface PGPModificationDetectionCodePacket ()

@property (nonatomic, readwrite) NSData *hashData;

@end

@implementation PGPModificationDetectionCodePacket

- (instancetype)initWithData:(NSData *)data {
    if (self = [self init]) {
        self->_hashData = [data pgp_SHA1];
    }
    return self;
}

- (instancetype)initWithFile:(NSURL *)fileURL prefix: (NSData *)prefixdata surfix: (NSData *) surfix {
    if (self = [self init]) {
        CFURLRef filePathURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)fileURL.path, kCFURLPOSIXPathStyle, (Boolean)false);
        CFReadStreamRef readStream = filePathURL ? CFReadStreamCreateWithFile(kCFAllocatorDefault, filePathURL) : NULL;
        BOOL didSucceed = readStream ? (BOOL)CFReadStreamOpen(readStream) : NO;
        if (didSucceed) {
            
            // Use default value for the chunk size for reading data.
            const size_t chunkSizeForReadingData = 4096;
            
            // Initialize the hash object
            CC_SHA1_CTX context;
            CC_SHA1_Init(&context);
            CC_SHA1_Update(&context, prefixdata.bytes, (CC_LONG)prefixdata.length);
            // Feed the data to the hash object.
            BOOL hasMoreData = YES;
            while (hasMoreData) {
                uint8_t buffer[chunkSizeForReadingData];
                CFIndex readBytesCount = CFReadStreamRead(readStream, (UInt8 *)buffer, (CFIndex)sizeof(buffer));
                if (readBytesCount == -1) {
                    break;
                } else if (readBytesCount == 0) {
                    hasMoreData = NO;
                } else {
                    CC_SHA1_Update(&context, buffer, (CC_LONG)readBytesCount);
                }
            }
            CC_SHA1_Update(&context, surfix.bytes, (CC_LONG)surfix.length);
            // Compute the hash digest
            unsigned char digest[CC_SHA1_DIGEST_LENGTH];
            CC_SHA1_Final(digest, &context);
            // Close the read stream.
            CFReadStreamClose(readStream);
            let outData = [NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
            self->_hashData = outData;
        }
        if (readStream) CFRelease(readStream);
        if (filePathURL)    CFRelease(filePathURL);
    }
    return self;
}
- (PGPPacketTag)tag {
    return PGPModificationDetectionCodePacketTag; // 19
}

- (NSUInteger)parsePacketBody:(NSData *)packetBody error:(NSError * __autoreleasing _Nullable *)error {
    NSUInteger position = [super parsePacketBody:packetBody error:error];

    // 5.14.  Modification Detection Code Packet (Tag 19)
    NSAssert(packetBody.length == CC_SHA1_DIGEST_LENGTH, @"A Modification Detection Code packet MUST have a length of 20 octets");

    self->_hashData = [packetBody subdataWithRange:(NSRange){position, CC_SHA1_DIGEST_LENGTH}];
    position = position + self.hashData.length;

    return position;
}

- (nullable NSData *)export:(NSError * __autoreleasing _Nullable *)error {
    return [PGPPacket buildPacketOfType:self.tag withBody:^NSData * {
        return [self.hashData subdataWithRange:(NSRange){0, CC_SHA1_DIGEST_LENGTH}]; // force limit to 20 octets
    }];
}

#pragma mark - isEqual

- (BOOL)isEqual:(id)other {
    if (self == other) { return YES; }
    if ([super isEqual:other] && [other isKindOfClass:self.class]) {
        return [self isEqualToDetectionCodePacket:other];
    }
    return NO;
}

- (BOOL)isEqualToDetectionCodePacket:(PGPModificationDetectionCodePacket *)packet {
    return PGPEqualObjects(self.hashData, packet.hashData);
}

- (NSUInteger)hash {
    NSUInteger prime = 31;
    NSUInteger result = [super hash];
    result = prime * result + self.hashData.hash;
    return result;
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(nullable NSZone *)zone {
    let _Nullable duplicate = PGPCast([super copyWithZone:zone], PGPModificationDetectionCodePacket);
    if (!duplicate) {
        return nil;
    }

    duplicate.hashData = self.hashData;
    return duplicate;
}

@end

NS_ASSUME_NONNULL_END
