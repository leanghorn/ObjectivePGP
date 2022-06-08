//
//  Copyright (c) Marcin Krzyżanowski. All rights reserved.
//
//  THIS SOURCE CODE AND ANY ACCOMPANYING DOCUMENTATION ARE PROTECTED BY
//  INTERNATIONAL COPYRIGHT LAW. USAGE IS BOUND TO THE LICENSE AGREEMENT.
//  This notice may not be removed from this file.
//

#import "PGPLiteralPacket.h"
#import "PGPTypes.h"
#import "PGPMacros+Private.h"
#import "PGPFoundation.h"

NS_ASSUME_NONNULL_BEGIN

@interface PGPLiteralPacket ()
@end

@implementation PGPLiteralPacket

- (instancetype)init {
    if (self = [super init]) {
        _format = PGPLiteralPacketBinary;
    }
    return self;
}

- (instancetype)initWithData:(NSData *)rawData {
    if (self = [self init]) {
        _literalRawData = [rawData copy];
    }
    return self;
}

- (instancetype)initWithFileURL:(NSURL *)fileURL {
    if (self = [self init]) {
        _fileURL = fileURL;
    }
    return self;
}

+ (PGPLiteralPacket *)literalPacket:(PGPLiteralPacketFormat)format withData:(NSData *)rawData {
    let literalPacket = [[PGPLiteralPacket alloc] initWithData:rawData];
    literalPacket.format = format;
    return literalPacket;
}

+ (PGPLiteralPacket *)literalPacket:(PGPLiteralPacketFormat)format withFileURL:(NSURL *)fileURL {
    let literalPacket = [[PGPLiteralPacket alloc] initWithFileURL:fileURL];
    literalPacket.format = format;
    return literalPacket;
}

- (PGPPacketTag)tag {
    return PGPLiteralDataPacketTag;
}

- (NSUInteger)parsePacketBody:(NSData *)packetBody error:(NSError * __autoreleasing _Nullable *)error {
    NSUInteger position = [super parsePacketBody:packetBody error:error];

    // A one-octet field that describes how the data is formatted.
    [packetBody getBytes:&_format range:(NSRange){position, 1}];
    position = position + 1;

    NSAssert(self.format == PGPLiteralPacketBinary || self.format == PGPLiteralPacketText || self.format == PGPLiteralPacketTextUTF8, @"Unkown data format");
    if (self.format != PGPLiteralPacketBinary && self.format != PGPLiteralPacketText && self.format != PGPLiteralPacketTextUTF8) {
        // skip
        return 1 + packetBody.length;
    }

    UInt8 filenameLength = 0;
    [packetBody getBytes:&filenameLength range:(NSRange){position, 1}];
    position = position + 1;

    // filename
    if (filenameLength > 0) {
        self.filename = [[NSString alloc] initWithData:[packetBody subdataWithRange:(NSRange){position, filenameLength}] encoding:NSUTF8StringEncoding];
        position = position + filenameLength;
    }

    // If the special name "_CONSOLE" is used, the message is considered to be "for your eyes only".

    // data date
    UInt32 creationTimestamp = 0;
    [packetBody getBytes:&creationTimestamp range:(NSRange){position, 4}];
    creationTimestamp = CFSwapInt32BigToHost(creationTimestamp);
    self.timestamp = [NSDate dateWithTimeIntervalSince1970:creationTimestamp];
    position = position + 4;
    let data = [packetBody subdataWithRange:(NSRange){position, packetBody.length - position}];

    switch (self.format) {
        case PGPLiteralPacketBinary:
        case PGPLiteralPacketText:
        case PGPLiteralPacketTextUTF8:
            // don't tamper the data, otherwise signature verification fails
            self.literalRawData = data;
            break;
        default:
            break;
    }

    return position;
}

- (nullable NSData *)export:(NSError * __autoreleasing _Nullable *)error {
    @autoreleasepool {
        if (!self.literalRawData) {
            if (error) {
                *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{ NSLocalizedDescriptionKey: @"Missing literal data" }];
            }
            return nil;
        }

        pgpweakify(self);
        return [PGPPacket buildPacketOfType:self.tag withBody:^NSData * {
            pgpstrongify(self);

            let bodyData = [NSMutableData data];
            [bodyData appendBytes:&self->_format length:1];

            if (self.filename) {
                UInt8 filenameLength = (UInt8)[self.filename lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                [bodyData appendBytes:&filenameLength length:1];
                [bodyData appendBytes:[self.filename cStringUsingEncoding:NSUTF8StringEncoding] length:filenameLength];
            } else {
                UInt8 zero[] = {0x00};
                [bodyData appendBytes:&zero length:1];
            }

            if (self.timestamp) {
                UInt32 timestampBytes = (UInt32)[self.timestamp timeIntervalSince1970];
                timestampBytes = CFSwapInt32HostToBig(timestampBytes);
                [bodyData appendBytes:&timestampBytes length:4];
            } else {
                UInt8 zero4[] = {0, 0, 0, 0};
                [bodyData appendBytes:&zero4 length:4];
            }

            switch (self.format) {
                case PGPLiteralPacketText:
                case PGPLiteralPacketTextUTF8:
                case PGPLiteralPacketBinary: {
                    [bodyData appendData:self.literalRawData];
                }
                    break;
                default:
                    break;
            }

            return bodyData;
        }];
    }
}

- (nullable NSURL *)exportFile:(NSError * __autoreleasing _Nullable *)error {
    @autoreleasepool {
        NSString *fileName = [NSString stringWithFormat:@"tmp-encrytped-%@", self.fileURL.lastPathComponent];
        NSString *newFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
        NSURL *newFileURL = [NSURL fileURLWithPath:newFilePath];
        [[NSFileManager defaultManager] copyItemAtPath:self.fileURL.path toPath:newFilePath error:nil];
        NSMutableData* bodyData = [NSMutableData data];
        [bodyData appendBytes:&self->_format length:1];

        if (self.filename) {
            UInt8 filenameLength = (UInt8)[self.filename lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            [bodyData appendBytes:&filenameLength length:1];
            [bodyData appendBytes:[self.filename cStringUsingEncoding:NSUTF8StringEncoding] length:filenameLength];
        } else {
            UInt8 zero[1] = {0x00};
            [bodyData appendBytes:&zero length:1];
        }

        UInt8 zero4[4] = {0, 0, 0, 0};
        [bodyData appendBytes:&zero4 length:4];
        let isSuccess = [PGPPacket buildPacketOfType:self.tag withData:bodyData file:^NSURL * _Nonnull{
            return newFileURL;
        }];
        if (isSuccess) {
            return newFileURL;
        }
        return nil;
    }
}
#pragma mark - isEqual

- (BOOL)isEqual:(id)other {
    if (self == other) { return YES; }
    if ([super isEqual:other] && [other isKindOfClass:self.class]) {
        return [self isEqualToLiteralPacket:other];
    }
    return NO;
}

- (BOOL)isEqualToLiteralPacket:(PGPLiteralPacket *)packet {
    return  self.format == packet.format &&
            PGPEqualObjects(self.timestamp, packet.timestamp) &&
            PGPEqualObjects(self.filename, packet.filename) &&
            PGPEqualObjects(self.literalRawData, packet.literalRawData);
}

- (NSUInteger)hash {
    NSUInteger prime = 31;
    NSUInteger result = [super hash];
    result = prime * result + self.format;
    result = prime * result + self.timestamp.hash;
    result = prime * result + self.filename.hash;
    result = prime * result + self.literalRawData.hash;
    return result;
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(nullable NSZone *)zone {
    let _Nullable duplicate = PGPCast([super copyWithZone:zone], PGPLiteralPacket);
    if (!duplicate) {
        return nil;
    }

    duplicate.format = self.format;
    duplicate.timestamp = self.timestamp;
    duplicate.filename = self.filename;
    duplicate.literalRawData = self.literalRawData;
    return duplicate;
}

@end

NS_ASSUME_NONNULL_END
