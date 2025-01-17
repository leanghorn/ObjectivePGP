//
//  Copyright (c) Marcin Krzyżanowski. All rights reserved.
//
//  THIS SOURCE CODE AND ANY ACCOMPANYING DOCUMENTATION ARE PROTECTED BY
//  INTERNATIONAL COPYRIGHT LAW. USAGE IS BOUND TO THE LICENSE AGREEMENT.
//  This notice may not be removed from this file.
//

#import "PGPPacket.h"
#import "PGPPacket+Private.h"
#import "PGPPacketHeader.h"
#import "NSData+PGPUtils.h"

#import "PGPLogging.h"
#import "PGPMacros+Private.h"

NS_ASSUME_NONNULL_BEGIN

@implementation PGPPacket

- (instancetype)init {
    if ((self = [super init])) {
        _tag = PGPInvalidPacketTag;
    }
    return self;
}

+ (nullable instancetype)packetWithBody:(NSData *)bodyData {
    PGPAssertClass(bodyData, NSData);

    id packet = [[self.class alloc] init];

    NSError *error = nil;
    if ([packet respondsToSelector:@selector(parsePacketBody:error:)]) {
        [packet parsePacketBody:bodyData error:&error];
    } else {
        return nil;
    }

    if (error) {
        return nil;
    }

    return packet;
}

- (NSUInteger)parsePacketBody:(NSData *)packetBody error:(NSError * __autoreleasing _Nullable *)error {
    PGPAssertClass(packetBody, NSData);
    return 0;
}

- (nullable NSData *)export:(NSError * __autoreleasing _Nullable *)error {
    [NSException raise:@"MissingExportMethod" format:@"export: selector not overriden"];
    return nil;
}

#pragma mark - isEqual

- (BOOL)isEqual:(id)other {
    if (self == other) { return YES; }
    if ([other isKindOfClass:self.class]) {
        return [self isEqualToPacket:other];
    }
    return NO;
}

- (BOOL)isEqualToPacket:(PGPPacket *)packet {
    return self.tag == packet.tag && self.indeterminateLength == packet.indeterminateLength;
}

- (NSUInteger)hash {
    NSUInteger prime = 31;
    NSUInteger result = 1;
    result = prime * result + self.tag;
    result = prime * result + (NSUInteger)self.indeterminateLength;
    return result;
}

#pragma mark - Packet header

// 4.2.  Packet Headers
/// Parse packet header and body, and return body. Parse packet header and read the followed data (packet body)
+ (nullable NSData *)readPacketBody:(NSData *)data headerLength:(UInt32 *)headerLength consumedBytes:(nullable NSUInteger *)consumedBytes packetTag:(nullable PGPPacketTag *)tag indeterminateLength:(nullable BOOL *)indeterminateLength {
    NSParameterAssert(headerLength);

    UInt8 headerByte = 0;
    [data getBytes:&headerByte range:(NSRange){0, 1}];

    BOOL isPGPHeader = !!(headerByte & PGPHeaderPacketTagAllwaysSet);
    BOOL isNewFormat = !!(headerByte & PGPHeaderPacketTagNewFormat);

    if (!isPGPHeader) {
        // not a valida data, skip the whole data.
        if (consumedBytes) {
            *consumedBytes = data.length;
        }
        return nil;
    }

    PGPPacketHeader *header = nil;
    if (isNewFormat) {
        header = [PGPPacketHeader newFormatHeaderFromData:data];
    } else {
        header = [PGPPacketHeader oldFormatHeaderFromData:data];
    }

    if (header.isIndeterminateLength) {
        // overwrite header body length
        header.bodyLength = (UInt32)data.length - header.headerLength;
    }

    if (header.bodyLength + header.headerLength > data.length) {
      PGPLogWarning(@"Invalid packet header.");
      // not a valida data, skip the whole data.
      if (consumedBytes) {
        *consumedBytes = data.length;
      }
      return nil;
    }

    *headerLength = header.headerLength;
    if (tag) { *tag = header.packetTag; }
    if (indeterminateLength) { *indeterminateLength = header.isIndeterminateLength; }

    if (header.isPartialLength && !header.isIndeterminateLength) {
        // Partial data starts with length octets offset (right after the packet header byte)
        let partialData = [data subdataWithRange:(NSRange){header.headerLength - 1, data.length - (header.headerLength - 1)}];
        NSUInteger partialConsumedBytes = 0;
        let concatenatedData = [PGPPacket readPartialData:partialData consumedBytes:&partialConsumedBytes];
        if (consumedBytes) {
            *consumedBytes = partialConsumedBytes + 1;
        }
        return concatenatedData;
    }

    if (consumedBytes) {
        *consumedBytes = header.bodyLength + header.headerLength;
    }
    return [data subdataWithRange:(NSRange){header.headerLength, header.bodyLength}];
}

// Read partial data. Part by part and return concatenated body data
+ (NSData *)readPartialData:(NSData *)data consumedBytes:(NSUInteger *)consumedBytes {
    BOOL hasMoreData = YES;
    NSUInteger offset = 0;
    let accumulatedData = [NSMutableData dataWithCapacity:data.length];

    while (hasMoreData) {
        BOOL isPartial = NO;
        NSUInteger partBodyLength = 0;
        UInt8  partLengthOctets = 0;

        // length + body
        let partData = [data subdataWithRange:(NSRange){offset, data.length - offset}];
        [PGPPacketHeader getLengthFromNewFormatOctets:partData bodyLength:&partBodyLength bytesCount:&partLengthOctets isPartial:&isPartial];

        // the last Body Length header can be a zero-length header.
        // in that case just skip it.
        if (partBodyLength > 0) {
            partBodyLength = MIN(partBodyLength, data.length - offset);

            // Append just body. Skip the length bytes.
            let partBodyData = [data subdataWithRange:(NSRange){offset + partLengthOctets, partBodyLength}];
            [accumulatedData appendData:partBodyData];
        }

        // move to next part
        offset = offset + partLengthOctets + partBodyLength;
        hasMoreData = isPartial;
    }

    *consumedBytes = offset;
    return accumulatedData;
}

#pragma mark - Build

+ (NSData *)buildPacketOfType:(PGPPacketTag)tag withBody:(NS_NOESCAPE NSData *(^)(void))body {
    return [self buildPacketOfType:tag isOld:NO withBody:body];
}

+ (NSData *)buildPacketOfType:(PGPPacketTag)tag isOld:(BOOL)isOld withBody:(NS_NOESCAPE NSData *(^)(void))body {
    // 4.2.2.  New Format Packet Lengths
    let data = [NSMutableData data];
    let bodyData = body();

    UInt8 packetTag = 0;

    // Bit 7 -- Always one
    packetTag |= PGPHeaderPacketTagAllwaysSet;

    // Bit 6 -- New packet format if set
    if (!isOld) {
        packetTag |= PGPHeaderPacketTagNewFormat;
    }

    if (isOld) {
        // Bits 5-2 -- packet tag
        packetTag |= (tag << 4) >> 2;

        // Bits 1-0 -- length-type
        UInt64 bodyLength = bodyData.length;
        if (bodyLength < 0xFF) {
            // 0 - The packet has a one-octet length.  The header is 2 octets long.
            packetTag |= 0;
        } else if (bodyLength <= 0xFFFF) {
            // 1 - The packet has a two-octet length.  The header is 3 octets long.
            packetTag |= 1;
        } else if (bodyLength <= 0xFFFFFFFF) {
            // 2 - The packet has a four-octet length.  The header is 5 octets long.
            packetTag |= 2;
        } else {
            // 3 - The packet is of indeterminate length.
            // In general, an implementation SHOULD NOT use indeterminate-length packets except where the end of the data will be clear from the context
            packetTag |= 3;
            NSAssert(NO, @"In general, an implementation SHOULD NOT use indeterminate-length packets");
        }
    } else {
        // Bits 5-0 -- packet tag
        packetTag |= tag;
    }

    // write ptag
    [data appendBytes:&packetTag length:1];

    // write header
    if (isOld) {
        [data appendData:[PGPPacketHeader buildOldFormatLengthDataForData:bodyData]];
    } else {
        [data appendData:[PGPPacketHeader buildNewFormatLengthDataForData:bodyData]];
    }

    // write packet body
    [data appendData:bodyData];

    return data;
}

+ (BOOL)buildPacketOfType:(PGPPacketTag)tag withData:(nullable NSData*)data file:(NSURL *(^)(void))file {
    return [self buildPacketOfType:tag isOld:NO withData:data file:file];
}

+ (BOOL)buildPacketOfType:(PGPPacketTag)tag isOld:(BOOL)isOld withData:(nullable NSData*)data file:(NSURL *(^)(void))file {
    // 4.2.2.  New Format Packet Lengths
    let dataFile = file();
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:dataFile.path error:NULL];
    unsigned long long fileSize = [attributes fileSize];
    UInt8 packetTag = 0;

    // Bit 7 -- Always one
    packetTag |= PGPHeaderPacketTagAllwaysSet;

    // Bit 6 -- New packet format if set
    if (!isOld) {
        packetTag |= PGPHeaderPacketTagNewFormat;
    }

    if (isOld) {
        // Bits 5-2 -- packet tag
        packetTag |= (tag << 4) >> 2;

        // Bits 1-0 -- length-type
        UInt64 bodyLength = (UInt64)fileSize;
        if (bodyLength < 0xFF) {
            // 0 - The packet has a one-octet length.  The header is 2 octets long.
            packetTag |= 0;
        } else if (bodyLength <= 0xFFFF) {
            // 1 - The packet has a two-octet length.  The header is 3 octets long.
            packetTag |= 1;
        } else if (bodyLength <= 0xFFFFFFFF) {
            // 2 - The packet has a four-octet length.  The header is 5 octets long.
            packetTag |= 2;
        } else {
            // 3 - The packet is of indeterminate length.
            // In general, an implementation SHOULD NOT use indeterminate-length packets except where the end of the data will be clear from the context
            packetTag |= 3;
            NSAssert(NO, @"In general, an implementation SHOULD NOT use indeterminate-length packets");
        }
    } else {
        // Bits 5-0 -- packet tag
        packetTag |= tag;
    }

    // write ptag
    if (data) {
        fileSize += data.length;
    }
    NSData *dataFileSize;
    // write header
    if (isOld) {
        dataFileSize = [PGPPacketHeader buildOldFormatLengthDataForDataLength:fileSize];
    } else {
        dataFileSize = [PGPPacketHeader buildNewFormatLengthDataForDataLength:fileSize];
    }
    //NSString *fileName = [NSString stringWithFormat:@"pre-%@", dataFile.lastPathComponent];
    NSString *fileName = [NSString stringWithFormat:@"pre-%llu", fileSize];
    NSString *newFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    [[NSFileManager defaultManager] createFileAtPath:newFilePath contents:nil attributes:nil];
    CFURLRef readFilePathURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)dataFile.path, kCFURLPOSIXPathStyle, (Boolean)false);
    CFReadStreamRef readStream = readFilePathURL ? CFReadStreamCreateWithFile(kCFAllocatorDefault, readFilePathURL) : NULL;
    BOOL didSucceed = readStream ? (BOOL)CFReadStreamOpen(readStream) : NO;
    CFURLRef writeFilePathURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)newFilePath, kCFURLPOSIXPathStyle, (Boolean)false);
    CFWriteStreamRef writeStream = writeFilePathURL ? CFWriteStreamCreateWithFile(kCFAllocatorDefault, writeFilePathURL) : NULL;
    BOOL didWriteSucceed = writeStream ? (BOOL)CFWriteStreamOpen(writeStream) : NO;
    if (didSucceed && didWriteSucceed) {
        // Use default value for the chunk size for reading data.
        const size_t chunkSizeForReadingData = 4096;
        // Feed the data to the hash object.
        BOOL hasMoreData = YES;
        // write header
        let headerData = [NSMutableData data];
        [headerData appendBytes:&packetTag length:1];
        [headerData appendData:dataFileSize];
        if (data) {
            [headerData appendData:data];
        }
        CFWriteStreamWrite(writeStream, headerData.bytes, headerData.length);
        while (hasMoreData) {
            uint8_t buffer[chunkSizeForReadingData];
            CFIndex readBytesCount = CFReadStreamRead(readStream, (UInt8 *)buffer, (CFIndex)sizeof(buffer));
            if (readBytesCount == -1) {
                break;
            } else if (readBytesCount == 0) {
                hasMoreData = NO;
            } else {
                CFWriteStreamWrite(writeStream, buffer, readBytesCount);
            }
        }
        // Close the read/write stream.
        CFReadStreamClose(readStream);
        CFWriteStreamClose(writeStream);
        // Proceed if the read operation succeeded.
        didSucceed = !hasMoreData;
    }
    if (readStream) CFRelease(readStream);
    if (readFilePathURL)    CFRelease(readFilePathURL);
    if (writeStream) CFRelease(writeStream);
    if (writeFilePathURL)    CFRelease(writeFilePathURL);
    
    //NSURL *newFileURL = [NSURL fileURLWithPath:newFilePath];
    [[NSFileManager defaultManager] removeItemAtPath:dataFile.path error:nil];
    [[NSFileManager defaultManager] copyItemAtPath:newFilePath toPath:dataFile.path error:nil];
//    [[NSFileManager defaultManager] replaceItemAtURL:dataFile withItemAtURL: newFileURL backupItemName:nil options:0 resultingItemURL:nil error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:newFilePath error:nil];
    return YES;
}

#pragma mark - NSCopying

- (id)copyWithZone:(nullable NSZone *)zone {
    PGPPacket *duplicate = [[self.class allocWithZone:zone] init];
    duplicate.tag = self.tag;
    duplicate.indeterminateLength = self.indeterminateLength;
    return duplicate;
}

@end

NS_ASSUME_NONNULL_END
