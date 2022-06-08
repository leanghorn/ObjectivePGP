//
//  Copyright (c) Marcin Krzyżanowski. All rights reserved.
//
//  THIS SOURCE CODE AND ANY ACCOMPANYING DOCUMENTATION ARE PROTECTED BY
//  INTERNATIONAL COPYRIGHT LAW. USAGE IS BOUND TO THE LICENSE AGREEMENT.
//  This notice may not be removed from this file.
//

#import "PGPCompressedPacket.h"
#import "NSData+compression.h"
#import "NSMutableData+PGPUtils.h"
#import "PGPMacros+Private.h"
#import "PGPFoundation.h"
#import "PGPLogging.h"
#import <bzlib.h>
#import <zlib.h>

NS_ASSUME_NONNULL_BEGIN

@interface PGPCompressedPacket ()

@property (nonatomic, readwrite) PGPCompressionAlgorithm compressionType;
@property (nonatomic, copy, readwrite) NSData *decompressedData;
@property (nonatomic, copy, readwrite) NSURL *fileURL;

@end

@implementation PGPCompressedPacket

- (instancetype)initWithData:(NSData *)data type:(PGPCompressionAlgorithm)type {
    if (self = [self init]) {
        _decompressedData = [data copy];
        _compressionType = type;
    }
    return self;
}

- (instancetype)initWithFile:(NSURL *)fileURL type:(PGPCompressionAlgorithm)type {
    if (self = [self init]) {
        _fileURL = fileURL;
        _compressionType = type;
    }
    return self;
}
- (PGPPacketTag)tag {
    return PGPCompressedDataPacketTag;
}

- (NSUInteger)parsePacketBody:(NSData *)packetBody error:(NSError * __autoreleasing _Nullable *)error {
    NSUInteger position = [super parsePacketBody:packetBody error:error];

    // - One octet that gives the algorithm used to compress the packet.
    [packetBody getBytes:&_compressionType length:sizeof(_compressionType)];
    position = position + 1;

    // - Compressed data, which makes up the remainder of the packet.
    let compressedData = [packetBody subdataWithRange:(NSRange){position, packetBody.length - position}];
    position = position + compressedData.length;

    switch (self.compressionType) {
        case PGPCompressionZIP:
            self.decompressedData = [compressedData zipDecompressed:error];
            break;
        case PGPCompressionZLIB:
            self.decompressedData = [compressedData zlibDecompressed:error];
            break;
        case PGPCompressionBZIP2:
            self.decompressedData = [compressedData bzip2Decompressed:error];
            break;

        default:
            if (error) {
                *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{ NSLocalizedDescriptionKey: @"This type of compression is not supported" }];
            }
            break;
    }

    return position;
}

- (nullable NSData *)export:(NSError * __autoreleasing _Nullable *)error {
    @autoreleasepool {
        let bodyData = [NSMutableData data];

        // - One octet that gives the algorithm used to compress the packet.
        [bodyData appendBytes:&_compressionType length:sizeof(_compressionType)];

        // - Compressed data, which makes up the remainder of the packet.
        NSData * _Nullable compressedData = nil;
        switch (self.compressionType) {
            case PGPCompressionZIP:
                compressedData = [self.decompressedData zipCompressed:error];
                break;
            case PGPCompressionZLIB:
                compressedData = [self.decompressedData zlibCompressed:error];
                break;
            case PGPCompressionBZIP2:
                compressedData = [self.decompressedData bzip2Compressed:error];
                break;
            default:
                if (error) {
                    *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{ NSLocalizedDescriptionKey: @"This type of compression is not supported" }];
                }
                return nil;
                break;
        }

        if (error && *error) {
            PGPLogDebug(@"Compression failed: %@", (*error).localizedDescription);
            return nil;
        }
        [bodyData pgp_appendData:compressedData];

        return [PGPPacket buildPacketOfType:self.tag withBody:^NSData * {
            return bodyData;
        }];
    }
}
/*
- (nullable NSURL *)exportFile:(NSError * __autoreleasing _Nullable *)error {
    @autoreleasepool {
        z_stream strm;
        strm.zalloc = Z_NULL;
        strm.zfree = Z_NULL;
        strm.opaque = Z_NULL;
        int ret = 0;
        ret = deflateInit(&strm, Z_DEFAULT_COMPRESSION);
        if (ret != Z_OK)
            return nil;
        NSString *fileName = [NSString stringWithFormat:@"compress-data"];
        NSString *newFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
        NSURL *newFileURL = [NSURL fileURLWithPath:newFilePath];
        [[NSFileManager defaultManager] createFileAtPath:newFilePath contents:nil attributes:nil];
        CFURLRef readFilePathURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)self.fileURL.path, kCFURLPOSIXPathStyle, (Boolean)false);
        CFReadStreamRef readStream = readFilePathURL ? CFReadStreamCreateWithFile(kCFAllocatorDefault, readFilePathURL) : NULL;
        BOOL didSucceed = readStream ? (BOOL)CFReadStreamOpen(readStream) : NO;
        CFURLRef writeFilePathURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)newFilePath, kCFURLPOSIXPathStyle, (Boolean)false);
        CFWriteStreamRef writeStream = writeFilePathURL ? CFWriteStreamCreateWithFile(kCFAllocatorDefault, writeFilePathURL) : NULL;
        BOOL didWriteSucceed = writeStream ? (BOOL)CFWriteStreamOpen(writeStream) : NO;
        if (didSucceed && didWriteSucceed) {
            // Use default value for the chunk size for reading data.
            const size_t chunkSizeForReadingData = 16384;
            
            CFWriteStreamWrite(writeStream, &_compressionType, sizeof(_compressionType));
            int flush;
            // Feed the data to the hash object.
            uInt CHUNK = 16384;
            unsigned char out[CHUNK];
            BOOL hasMoreData = YES;
            while (hasMoreData) {
                uint8_t buffer[chunkSizeForReadingData];
                CFIndex readBytesCount = CFReadStreamRead(readStream, (UInt8 *)buffer, (CFIndex)sizeof(buffer));
                if (readBytesCount == -1) {
                    break;
                } else if (readBytesCount == 0) {
                    hasMoreData = NO;
                } else {
                    uInt dataCount = (uInt)readBytesCount;
                    if (dataCount < CHUNK) {
                        flush = Z_FINISH;
                    } else {
                        flush = Z_NO_FLUSH;
                    }
                    strm.avail_in = dataCount;
                    strm.next_in = buffer;
                    // NSMutableData* compressed = [NSMutableData dataWithLength:data.length];
                    do {
                        strm.avail_out = CHUNK;
                        strm.next_out = out;
                        ret = deflate(&strm, flush);
                        if (ret == Z_STREAM_ERROR) {
                            CFReadStreamClose(readStream);
                            CFWriteStreamClose(writeStream);
                            // [[NSFileManager defaultManager] removeItemAtPath:newFilePath error:nil];
                            deflateEnd(&strm);
                            *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithCString:strm.msg ?: "compress file failed"  encoding:NSASCIIStringEncoding]}];
                            return nil;
                        }
                        @autoreleasepool {
                            NSData* outData = [NSData dataWithBytes:(const void *)out length:CHUNK - strm.avail_out];
                            CFWriteStreamWrite(writeStream, outData.bytes, outData.length);
//                            CFWriteStreamWrite(writeStream, out, CHUNK - strm.avail_out);
                        }
                    } while (strm.avail_out == 0);
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
        
        
        if (deflateEnd(&strm) != Z_OK) {
            if (error) {
                *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithCString:strm.msg ?: "deflateEnd failed"  encoding:NSASCIIStringEncoding]}];
            }
            [[NSFileManager defaultManager] removeItemAtPath:newFilePath error:nil];
            return nil;
        }
        if (error && *error) {
            PGPLogDebug(@"Compression failed: %@", (*error).localizedDescription);
            return nil;
        }
        let isSuccess = [PGPPacket buildPacketOfType:self.tag withData:nil file:^NSURL * _Nonnull{
            return newFileURL;
        }];
        if (isSuccess) {
            return newFileURL;
        }
        return nil;
    }
}
*/
//*
- (nullable NSURL *)exportFile:(NSError * __autoreleasing _Nullable *)error {
    @autoreleasepool {
        z_stream strm;
        strm.zalloc = Z_NULL;
        strm.zfree = Z_NULL;
        strm.opaque = Z_NULL;
        int ret = 0;
        ret = deflateInit(&strm, Z_DEFAULT_COMPRESSION);
        if (ret != Z_OK)
            return nil;
        NSString *fileName = [NSString stringWithFormat:@"compress-data"];
        NSString *newFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
        NSURL *newFileURL = [NSURL fileURLWithPath:newFilePath];
        [[NSFileManager defaultManager] createFileAtPath:newFilePath contents:nil attributes:nil];
        NSFileHandle *readFileHandle = [NSFileHandle fileHandleForReadingAtPath: self.fileURL.path];
        NSFileHandle *writeFileHandle = [NSFileHandle fileHandleForWritingAtPath: newFilePath];
        [writeFileHandle writeData:[NSData dataWithBytes:&_compressionType length:sizeof(_compressionType)]];
        unsigned char out[16384];
        uInt CHUNK = 16384;
        int flush;
        do {
            @autoreleasepool {
                NSData *data = [readFileHandle readDataOfLength:CHUNK];
                if (data.length < CHUNK) {
                    flush = Z_FINISH;
                } else {
                    flush = Z_NO_FLUSH;
                }
                strm.avail_in = (uInt)data.length;
                strm.next_in = (Bytef *)data.bytes;
                do {
                    strm.avail_out = CHUNK;
                    strm.next_out = out;
                    ret = deflate(&strm, flush);
                    if (ret == Z_STREAM_ERROR) {
                        [writeFileHandle closeFile];
                        [readFileHandle closeFile];
                        // [[NSFileManager defaultManager] removeItemAtPath:newFilePath error:nil];
                        deflateEnd(&strm);
                        *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithCString:strm.msg ?: "compress file failed"  encoding:NSASCIIStringEncoding]}];
                        return nil;
                    }
                    NSData* outData = [NSData dataWithBytes:(const void *)out length:CHUNK - strm.avail_out];
                    [writeFileHandle writeData:outData];
                } while (strm.avail_out == 0);
            }
        } while (flush != Z_FINISH);
        [writeFileHandle closeFile];
        [readFileHandle closeFile];
        if (deflateEnd(&strm) != Z_OK) {
            if (error) {
                *error = [NSError errorWithDomain:PGPErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithCString:strm.msg ?: "deflateEnd failed"  encoding:NSASCIIStringEncoding]}];
            }
            [[NSFileManager defaultManager] removeItemAtPath:newFilePath error:nil];
            return nil;
        }
        if (error && *error) {
            PGPLogDebug(@"Compression failed: %@", (*error).localizedDescription);
            return nil;
        }
        let isSuccess = [PGPPacket buildPacketOfType:self.tag withData:nil file:^NSURL * _Nonnull{
            return newFileURL;
        }];
        if (isSuccess) {
            return newFileURL;
        }
        return nil;
    }
}
//*/
#pragma mark - isEqual

- (BOOL)isEqual:(id)other {
    if (self == other) { return YES; }
    if ([super isEqual:other] && [other isKindOfClass:self.class]) {
        return [self isEqualToCompressedPacket:other];
    }
    return NO;
}

- (BOOL)isEqualToCompressedPacket:(PGPCompressedPacket *)packet {
    return  self.compressionType == packet.compressionType &&
            PGPEqualObjects(self.decompressedData, packet.decompressedData);
}

- (NSUInteger)hash {
    NSUInteger prime = 31;
    NSUInteger result = [super hash];
    result = prime * result + self.compressionType;
    result = prime * result + self.decompressedData.hash;
    return result;
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(nullable NSZone *)zone {
    let duplicate = PGPCast([super copyWithZone:zone], PGPCompressedPacket);
    PGPAssertClass(duplicate, PGPCompressedPacket)
    duplicate.compressionType = self.compressionType;
    duplicate.decompressedData = self.decompressedData;
    return duplicate;
}

@end

NS_ASSUME_NONNULL_END
