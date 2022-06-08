//
//  Copyright (c) Marcin Krzyżanowski. All rights reserved.
//
//  THIS SOURCE CODE AND ANY ACCOMPANYING DOCUMENTATION ARE PROTECTED BY
//  INTERNATIONAL COPYRIGHT LAW. USAGE IS BOUND TO THE LICENSE AGREEMENT.
//  This notice may not be removed from this file.
//

#import "PGPCryptoCFB.h"
#import "NSData+PGPUtils.h"
#import "NSMutableData+PGPUtils.h"
#import "PGPCryptoUtils.h"
#import "PGPS2K.h"
#import "PGPTypes.h"
#import "PGPMacros+Private.h"
#import "PGPLogging.h"

#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>

#import <openssl/aes.h>
#import <openssl/blowfish.h>
#import <openssl/camellia.h>
#import <openssl/cast.h>
#import <openssl/des.h>
#import <openssl/idea.h>
#import <openssl/sha.h>

#import "twofish.h"

NS_ASSUME_NONNULL_BEGIN

@implementation PGPCryptoCFB

+ (nullable NSData *)decryptData:(NSData *)encryptedData
                  sessionKeyData:(NSData *)sessionKeyData // s2k produceSessionKeyWithPassphrase
              symmetricAlgorithm:(PGPSymmetricAlgorithm)symmetricAlgorithm
                              iv:(NSData *)ivData
                         syncCFB:(BOOL)syncCFB
{
    return [self manipulateData:encryptedData sessionKeyData:sessionKeyData symmetricAlgorithm:symmetricAlgorithm iv:ivData syncCFB:syncCFB decrypt:YES];
}

+ (nullable NSData *)encryptData:(NSData *)encryptedData
                  sessionKeyData:(NSData *)sessionKeyData // s2k produceSessionKeyWithPassphrase
              symmetricAlgorithm:(PGPSymmetricAlgorithm)symmetricAlgorithm
                              iv:(NSData *)ivData
                         syncCFB:(BOOL)syncCFB
{
    return [self manipulateData:encryptedData sessionKeyData:sessionKeyData symmetricAlgorithm:symmetricAlgorithm iv:ivData syncCFB:syncCFB decrypt:NO];
}

#pragma mark - Private

// key binary string representation of key to be used to decrypt the ciphertext.
+ (nullable NSData *)manipulateData:(NSData *)encryptedData
                     sessionKeyData:(NSData *)sessionKeyData // s2k produceSessionKeyWithPassphrase
                 symmetricAlgorithm:(PGPSymmetricAlgorithm)symmetricAlgorithm
                                 iv:(NSData *)ivData
                            syncCFB:(BOOL)syncCFB // weird OpenPGP CFB
                            decrypt:(BOOL)decrypt
{
    NSAssert(sessionKeyData.length > 0, @"Missing session key");
    NSAssert(encryptedData.length > 0, @"Missing data");
    NSAssert(ivData.length > 0, @"Missing IV");

    if (ivData.length == 0 || sessionKeyData.length == 0 || encryptedData.length == 0) {
        PGPLogDebug(@"Invalid input to encrypt/decrypt.");
        return nil;
    }

    NSUInteger keySize = [PGPCryptoUtils keySizeOfSymmetricAlgorithm:symmetricAlgorithm];
    NSUInteger blockSize = [PGPCryptoUtils blockSizeOfSymmetricAlhorithm:symmetricAlgorithm];
    NSAssert(keySize <= 32, @"Invalid key size");
    NSAssert(sessionKeyData.length >= keySize, @"Invalid session key.");

    let ivDataBytes = (uint8_t *)[NSMutableData dataWithData:ivData].mutableBytes;
    let encryptedBytes = (const uint8_t *)encryptedData.bytes;
    var decryptedData = [NSMutableData dataWithLength:encryptedData.length];
    let outBuffer = (uint8_t *)decryptedData.mutableBytes;
    let outBufferLength = decryptedData.length;

    // decrypt with CFB
    switch (symmetricAlgorithm) {
        case PGPSymmetricAES128:
        case PGPSymmetricAES192:
        case PGPSymmetricAES256: {
            AES_KEY aes_key;
            AES_set_encrypt_key(sessionKeyData.bytes, (int)keySize * 8, &aes_key);

            if (syncCFB) {
                decryptedData = [[PGPCryptoCFB openPGP_CFB_decrypt:encryptedData blockSize:blockSize iv:ivData cipherEncrypt:^NSData * _Nullable(NSData * _Nonnull data) {
                    let output = [NSMutableData dataWithLength:data.length];
                    AES_encrypt(data.bytes, output.mutableBytes, &aes_key);
                    return output;
                }] copy];
            } else {
                int blocksNum = 0;
                AES_cfb128_encrypt(encryptedBytes, outBuffer, outBufferLength, &aes_key, ivDataBytes, &blocksNum, decrypt ? AES_DECRYPT : AES_ENCRYPT);
            }
            memset(&aes_key, 0, sizeof(AES_KEY));
        } break;
        case PGPSymmetricIDEA: {
            let encrypt_key = calloc(1, sizeof(IDEA_KEY_SCHEDULE));
            idea_set_encrypt_key(sessionKeyData.bytes, encrypt_key);

            if (syncCFB) {
                decryptedData = [[PGPCryptoCFB openPGP_CFB_decrypt:encryptedData blockSize:blockSize iv:ivData cipherEncrypt:^NSData * _Nullable(NSData * _Nonnull data) {
                    let output = [NSMutableData dataWithLength:data.length];
                    idea_ecb_encrypt(data.bytes, output.mutableBytes, encrypt_key);
                    return output;
                }] copy];
            } else {
                IDEA_KEY_SCHEDULE decrypt_key;
                idea_set_decrypt_key(encrypt_key, &decrypt_key);

                int num = 0;
                idea_cfb64_encrypt(encryptedBytes, outBuffer, outBufferLength, decrypt ? &decrypt_key : encrypt_key, ivDataBytes, &num, decrypt ? CAST_DECRYPT : CAST_ENCRYPT);
                memset(&decrypt_key, 0, sizeof(IDEA_KEY_SCHEDULE));
            }

            memset(encrypt_key, 0, sizeof(IDEA_KEY_SCHEDULE));
            free(encrypt_key);
        } break;
        case PGPSymmetricTripleDES: {
            DES_key_schedule *keys = calloc(3, sizeof(DES_key_schedule));
            for (NSUInteger n = 0; n < 3; ++n) {
                DES_set_key((DES_cblock *)(void *)(sessionKeyData.bytes + n * 8), &keys[n]);
            }
            pgp_defer {
                if (keys) {
                    memset(keys, 0, 3 * sizeof(DES_key_schedule));
                    free(keys);
                }
            };

            if (syncCFB) {
                decryptedData = [[PGPCryptoCFB openPGP_CFB_decrypt:encryptedData blockSize:blockSize iv:ivData cipherEncrypt:^NSData * _Nullable(NSData * _Nonnull data) {
                    let output = [NSMutableData dataWithLength:data.length];
                    DES_ecb_encrypt((unsigned char (*)[8])data.bytes, output.mutableBytes, keys, DES_ENCRYPT);
                    return output;
                }] copy];
            } else {
                int blocksNum = 0;
                DES_ede3_cfb64_encrypt(encryptedBytes, outBuffer, outBufferLength, &keys[0], &keys[1], &keys[2], (DES_cblock *)(void *)ivDataBytes, &blocksNum, decrypt ? DES_DECRYPT : DES_ENCRYPT);
            }

        } break;
        case PGPSymmetricCAST5: {
            // initialize
            CAST_KEY encrypt_key;
            CAST_set_key(&encrypt_key, MIN((int)keySize, (int)sessionKeyData.length), sessionKeyData.bytes);

            if (syncCFB) {
                decryptedData = [[PGPCryptoCFB openPGP_CFB_decrypt:encryptedData blockSize:blockSize iv:ivData cipherEncrypt:^NSData * _Nullable(NSData * _Nonnull data) {
                    let output = [NSMutableData dataWithLength:data.length];
                    CAST_ecb_encrypt(data.bytes, output.mutableBytes, &encrypt_key, CAST_ENCRYPT);
                    return output;
                }] copy];
            } else {
                int num = 0; //    how much of the 64bit block we have used
                CAST_cfb64_encrypt(encryptedBytes, outBuffer, outBufferLength, &encrypt_key, ivDataBytes, &num, decrypt ? CAST_DECRYPT : CAST_ENCRYPT);
            }

            memset(&encrypt_key, 0, sizeof(CAST_KEY));
        } break;
        case PGPSymmetricBlowfish: {
            BF_KEY encrypt_key;
            BF_set_key(&encrypt_key, MIN((int)keySize, (int)sessionKeyData.length), sessionKeyData.bytes);

            if (syncCFB) {
                decryptedData = [[PGPCryptoCFB openPGP_CFB_decrypt:encryptedData blockSize:blockSize iv:ivData cipherEncrypt:^NSData * _Nullable(NSData * _Nonnull data) {
                    let output = [NSMutableData dataWithLength:data.length];
                    BF_ecb_encrypt(data.bytes, output.mutableBytes, &encrypt_key, BF_ENCRYPT);
                    return output;
                }] copy];
            } else {
                int num = 0; //    how much of the 64bit block we have used
                BF_cfb64_encrypt(encryptedBytes, outBuffer, outBufferLength, &encrypt_key, ivDataBytes, &num, decrypt ? BF_DECRYPT : BF_ENCRYPT);
            }

            memset(&encrypt_key, 0, sizeof(BF_KEY));
        } break;
        case PGPSymmetricTwofish256: {
            static dispatch_once_t twoFishInit;
            dispatch_once(&twoFishInit, ^{ Twofish_initialise(); });

            let xkey = calloc(1, sizeof(Twofish_key));
            Twofish_prepare_key((uint8_t *)sessionKeyData.bytes, (int)sessionKeyData.length, xkey);

            if (syncCFB) {
                decryptedData = [[PGPCryptoCFB openPGP_CFB_decrypt:encryptedData blockSize:blockSize iv:ivData cipherEncrypt:^NSData * _Nullable(NSData * _Nonnull data) {
                    let output = [NSMutableData dataWithLength:data.length];
                    Twofish_encrypt(xkey, (uint8_t *)data.bytes, output.mutableBytes);
                    return output;
                }] copy];
            } else {
                if (decrypt) {
                    // decrypt
                    NSMutableData *decryptedOutMutableData = encryptedData.mutableCopy;
                    var ciphertextBlock = [NSData dataWithData:ivData];
                    let plaintextBlock = [NSMutableData dataWithLength:blockSize];
                    for (NSUInteger index = 0; index < encryptedData.length; index += blockSize) {
                        Twofish_encrypt(xkey, (uint8_t *)ciphertextBlock.bytes, plaintextBlock.mutableBytes);
                        ciphertextBlock = [encryptedData subdataWithRange:(NSRange){index, MIN(blockSize, decryptedOutMutableData.length - index)}];
                        [decryptedOutMutableData XORWithData:plaintextBlock index:index];
                    }
                    decryptedData = decryptedOutMutableData;
                } else {
                    // encrypt
                    NSMutableData *encryptedOutMutableData = encryptedData.mutableCopy; // input plaintext
                    var plaintextBlock = [NSData dataWithData:ivData];
                    let ciphertextBlock = [NSMutableData dataWithLength:blockSize];
                    for (NSUInteger index = 0; index < encryptedData.length; index += blockSize) {
                        Twofish_encrypt(xkey, (uint8_t *)plaintextBlock.bytes, ciphertextBlock.mutableBytes);
                        [encryptedOutMutableData XORWithData:ciphertextBlock index:index];
                        plaintextBlock = [encryptedOutMutableData subdataWithRange:(NSRange){index, MIN(blockSize, encryptedOutMutableData.length - index)}]; // ciphertext.copy;
                    }
                    decryptedData = encryptedOutMutableData;
                }
            }

            memset(xkey, 0, sizeof(Twofish_key));
            free(xkey);
        } break;
        case PGPSymmetricPlaintext:
            PGPLogWarning(@"Can't decrypt plaintext");
            decryptedData = [NSMutableData dataWithData:encryptedData];
            break;
        default:
            PGPLogWarning(@"Unsupported cipher.");
            return nil;
    }

    return decryptedData;
}

+ (BOOL)encryptFileURL:(NSURL *)encryptedFileURL
        destinationURL:(NSURL *)destinationURL
            prefixData:(NSData *)prefixData
        sessionKeyData:(NSData *)sessionKeyData // s2k produceSessionKeyWithPassphrase
    symmetricAlgorithm:(PGPSymmetricAlgorithm)symmetricAlgorithm
                    iv:(NSData *)ivData
               syncCFB:(BOOL)syncCFB
{
    return [self manipulateFileURL:encryptedFileURL destinationURL:destinationURL prefixData:prefixData sessionKeyData:sessionKeyData symmetricAlgorithm:symmetricAlgorithm iv:ivData syncCFB:syncCFB decrypt:NO];
}

#pragma mark - Private

// key binary string representation of key to be used to decrypt the ciphertext.
+ (BOOL)manipulateFileURL:(NSURL *)encryptedFileURL
           destinationURL:(NSURL *)destinationURL
           prefixData:(NSData *)prefixData
           sessionKeyData:(NSData *)sessionKeyData // s2k produceSessionKeyWithPassphrase
       symmetricAlgorithm:(PGPSymmetricAlgorithm)symmetricAlgorithm
                       iv:(NSData *)ivData
                  syncCFB:(BOOL)syncCFB // weird OpenPGP CFB
                  decrypt:(BOOL)decrypt
{
    NSAssert(sessionKeyData.length > 0, @"Missing session key");
    // NSAssert(encryptedData.length > 0, @"Missing data");
    NSAssert(ivData.length > 0, @"Missing IV");

    if (ivData.length == 0 || sessionKeyData.length == 0) {
        PGPLogDebug(@"Invalid input to encrypt/decrypt.");
        return NO;
    }

    NSUInteger keySize = [PGPCryptoUtils keySizeOfSymmetricAlgorithm:symmetricAlgorithm];
    NSUInteger blockSize = [PGPCryptoUtils blockSizeOfSymmetricAlhorithm:symmetricAlgorithm];
    NSAssert(keySize <= 32, @"Invalid key size");
    NSAssert(sessionKeyData.length >= keySize, @"Invalid session key.");
    
    NSError *error;
    let ivDataBytes = (uint8_t *)[NSMutableData dataWithData:ivData].mutableBytes;
    if (symmetricAlgorithm >=7 && symmetricAlgorithm <= 9) {
        AES_KEY aes_key;
        AES_set_encrypt_key(sessionKeyData.bytes, (int)keySize * 8, &aes_key);
        if (syncCFB) {
            NSData *encryptedData = [NSData dataWithContentsOfURL:encryptedFileURL options:0 error:&error];
            NSData *decryptedData = [[PGPCryptoCFB openPGP_CFB_decrypt:encryptedData blockSize:blockSize iv:ivData cipherEncrypt:^NSData * _Nullable(NSData * _Nonnull data) {
                let output = [NSMutableData dataWithLength:data.length];
                AES_encrypt(data.bytes, output.mutableBytes, &aes_key);
                return output;
            }] copy];
            BOOL isSuccess = [decryptedData writeToFile:destinationURL.path atomically:YES];
            return isSuccess;
        } else {
            int blocksNum = 0;
            [[NSFileManager defaultManager] createFileAtPath:destinationURL.path contents:nil attributes:nil];
            CFURLRef readFilePathURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)encryptedFileURL.path, kCFURLPOSIXPathStyle, (Boolean)false);
            CFReadStreamRef readStream = readFilePathURL ? CFReadStreamCreateWithFile(kCFAllocatorDefault, readFilePathURL) : NULL;
            BOOL didSucceed = readStream ? (BOOL)CFReadStreamOpen(readStream) : NO;
            CFURLRef writeFilePathURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)destinationURL.path, kCFURLPOSIXPathStyle, (Boolean)false);
            CFWriteStreamRef writeStream = writeFilePathURL ? CFWriteStreamCreateWithFile(kCFAllocatorDefault, writeFilePathURL) : NULL;
            BOOL didWriteSucceed = writeStream ? (BOOL)CFWriteStreamOpen(writeStream) : NO;
            if (didSucceed && didWriteSucceed) {
                // Use default value for the chunk size for reading data.
                const size_t chunkSizeForReadingData = blockSize;
                // Feed the data to the hash object.
                BOOL hasMoreData = YES;
                BOOL firstRead = YES;
                NSMutableData* combindData = [NSMutableData data];
                while (hasMoreData) {
                    uint8_t buffer[chunkSizeForReadingData];
                    CFIndex readBytesCount;
                    if (firstRead) {
                        if (prefixData.length > blockSize) {
                            
                            NSUInteger length = [prefixData length];
                            NSUInteger chunkSize = blockSize;
                            NSUInteger offset = 0;
                            do {
                                NSUInteger thisChunkSize = length - offset > chunkSize ? chunkSize : length - offset;
                                NSData* chunk = [NSData dataWithBytesNoCopy:(char *)[prefixData bytes] + offset
                                                                     length:thisChunkSize
                                                               freeWhenDone:NO];
                                offset += thisChunkSize;
                                // do something with chunk
                                if (offset < length) {
                                    uint8_t data[chunkSizeForReadingData];
                                    [chunk getBytes:&data length:chunk.length];
                                    uint8_t outChunkBuffer[thisChunkSize];
                                    AES_cfb128_encrypt(data, outChunkBuffer, thisChunkSize, &aes_key, ivDataBytes, &blocksNum, decrypt ? AES_DECRYPT : AES_ENCRYPT);
                                    CFWriteStreamWrite(writeStream, outChunkBuffer, thisChunkSize);
                                } else {
                                    [combindData appendData:chunk];
                                }
                                
                            } while (offset < length);
                        }
                        NSUInteger length = blockSize - combindData.length;
                        uint8_t firstBuffer[length];
                        readBytesCount = CFReadStreamRead(readStream, (UInt8 *)firstBuffer, (CFIndex)sizeof(firstBuffer));
                        NSData *firstChunkData =[NSData dataWithBytes:&firstBuffer length:readBytesCount];
                        [combindData appendData:firstChunkData];
                        [combindData getBytes:&buffer length:combindData.length];
                        firstRead = NO;
                    } else {
                        readBytesCount = CFReadStreamRead(readStream, (UInt8 *)buffer, (CFIndex)sizeof(buffer));
                    }
                    if (readBytesCount == -1) {
                        break;
                    } else if (readBytesCount == 0) {
                        hasMoreData = NO;
                    } else {
                        NSUInteger outChunkBufferLength = sizeof(buffer);
                        uint8_t outChunkBuffer[outChunkBufferLength];
                        AES_cfb128_encrypt(buffer, outChunkBuffer, outChunkBufferLength, &aes_key, ivDataBytes, &blocksNum, decrypt ? AES_DECRYPT : AES_ENCRYPT);
                        CFWriteStreamWrite(writeStream, outChunkBuffer, outChunkBufferLength);
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
//            NSFileHandle *readFileHandle = [NSFileHandle fileHandleForReadingAtPath: encryptedFileURL.path];
//            NSFileHandle *writeFileHandle = [NSFileHandle fileHandleForWritingAtPath: destinationURL.path];
//            BOOL hasMoreData = YES;
//            while(hasMoreData) {
//                // NSData *data = [readFileHandle readDataOfLength: sizeof(AES_KEY)];
//                NSData *data = [readFileHandle readDataOfLength: blockSize];
//                NSUInteger length = data.length;
//                if(length > 0) {
//                    uint8_t* chunkBytes = (uint8_t *)data.bytes;
//                    NSMutableData *decryptedChunkData = [NSMutableData dataWithLength:data.length];
//                    u_int8_t* outChunkBuffer = (uint8_t *)decryptedChunkData.mutableBytes;
//                    NSUInteger outChunkBufferLength = decryptedChunkData.length;
//                    AES_cfb128_encrypt(chunkBytes, outChunkBuffer, outChunkBufferLength, &aes_key, ivDataBytes, &blocksNum, decrypt ? AES_DECRYPT : AES_ENCRYPT);
//                    [writeFileHandle writeData:decryptedChunkData];
//                } else {
//                    hasMoreData = NO;
//                }
//            }
//            [readFileHandle closeFile];
//            [writeFileHandle closeFile];
            memset(&aes_key, 0, sizeof(AES_KEY));
            return YES;
        }
    }
    NSData *encryptedData = [NSData dataWithContentsOfURL:encryptedFileURL options:0 error:&error];
    let encryptedBytes = (const uint8_t *)encryptedData.bytes;
    var decryptedData = [NSMutableData dataWithLength:encryptedData.length];
    let outBuffer = (uint8_t *)decryptedData.mutableBytes;
    let outBufferLength = decryptedData.length;
    
    // decrypt with CFB
    switch (symmetricAlgorithm) {
        case PGPSymmetricAES128:
        case PGPSymmetricAES192:
        case PGPSymmetricAES256: {
        } break;
        case PGPSymmetricIDEA: {
            let encrypt_key = calloc(1, sizeof(IDEA_KEY_SCHEDULE));
            idea_set_encrypt_key(sessionKeyData.bytes, encrypt_key);

            if (syncCFB) {
                decryptedData = [[PGPCryptoCFB openPGP_CFB_decrypt:encryptedData blockSize:blockSize iv:ivData cipherEncrypt:^NSData * _Nullable(NSData * _Nonnull data) {
                    let output = [NSMutableData dataWithLength:data.length];
                    idea_ecb_encrypt(data.bytes, output.mutableBytes, encrypt_key);
                    return output;
                }] copy];
            } else {
                IDEA_KEY_SCHEDULE decrypt_key;
                idea_set_decrypt_key(encrypt_key, &decrypt_key);

                int num = 0;
                idea_cfb64_encrypt(encryptedBytes, outBuffer, outBufferLength, decrypt ? &decrypt_key : encrypt_key, ivDataBytes, &num, decrypt ? CAST_DECRYPT : CAST_ENCRYPT);
                memset(&decrypt_key, 0, sizeof(IDEA_KEY_SCHEDULE));
            }

            memset(encrypt_key, 0, sizeof(IDEA_KEY_SCHEDULE));
            free(encrypt_key);
        } break;
        case PGPSymmetricTripleDES: {
            DES_key_schedule *keys = calloc(3, sizeof(DES_key_schedule));
            for (NSUInteger n = 0; n < 3; ++n) {
                DES_set_key((DES_cblock *)(void *)(sessionKeyData.bytes + n * 8), &keys[n]);
            }
            pgp_defer {
                if (keys) {
                    memset(keys, 0, 3 * sizeof(DES_key_schedule));
                    free(keys);
                }
            };

            if (syncCFB) {
                decryptedData = [[PGPCryptoCFB openPGP_CFB_decrypt:encryptedData blockSize:blockSize iv:ivData cipherEncrypt:^NSData * _Nullable(NSData * _Nonnull data) {
                    let output = [NSMutableData dataWithLength:data.length];
                    DES_ecb_encrypt((unsigned char (*)[8])data.bytes, output.mutableBytes, keys, DES_ENCRYPT);
                    return output;
                }] copy];
            } else {
                int blocksNum = 0;
                DES_ede3_cfb64_encrypt(encryptedBytes, outBuffer, outBufferLength, &keys[0], &keys[1], &keys[2], (DES_cblock *)(void *)ivDataBytes, &blocksNum, decrypt ? DES_DECRYPT : DES_ENCRYPT);
            }

        } break;
        case PGPSymmetricCAST5: {
            // initialize
            CAST_KEY encrypt_key;
            CAST_set_key(&encrypt_key, MIN((int)keySize, (int)sessionKeyData.length), sessionKeyData.bytes);

            if (syncCFB) {
                decryptedData = [[PGPCryptoCFB openPGP_CFB_decrypt:encryptedData blockSize:blockSize iv:ivData cipherEncrypt:^NSData * _Nullable(NSData * _Nonnull data) {
                    let output = [NSMutableData dataWithLength:data.length];
                    CAST_ecb_encrypt(data.bytes, output.mutableBytes, &encrypt_key, CAST_ENCRYPT);
                    return output;
                }] copy];
            } else {
                int num = 0; //    how much of the 64bit block we have used
                CAST_cfb64_encrypt(encryptedBytes, outBuffer, outBufferLength, &encrypt_key, ivDataBytes, &num, decrypt ? CAST_DECRYPT : CAST_ENCRYPT);
            }

            memset(&encrypt_key, 0, sizeof(CAST_KEY));
        } break;
        case PGPSymmetricBlowfish: {
            BF_KEY encrypt_key;
            BF_set_key(&encrypt_key, MIN((int)keySize, (int)sessionKeyData.length), sessionKeyData.bytes);

            if (syncCFB) {
                decryptedData = [[PGPCryptoCFB openPGP_CFB_decrypt:encryptedData blockSize:blockSize iv:ivData cipherEncrypt:^NSData * _Nullable(NSData * _Nonnull data) {
                    let output = [NSMutableData dataWithLength:data.length];
                    BF_ecb_encrypt(data.bytes, output.mutableBytes, &encrypt_key, BF_ENCRYPT);
                    return output;
                }] copy];
            } else {
                int num = 0; //    how much of the 64bit block we have used
                BF_cfb64_encrypt(encryptedBytes, outBuffer, outBufferLength, &encrypt_key, ivDataBytes, &num, decrypt ? BF_DECRYPT : BF_ENCRYPT);
            }

            memset(&encrypt_key, 0, sizeof(BF_KEY));
        } break;
        case PGPSymmetricTwofish256: {
            static dispatch_once_t twoFishInit;
            dispatch_once(&twoFishInit, ^{ Twofish_initialise(); });

            let xkey = calloc(1, sizeof(Twofish_key));
            Twofish_prepare_key((uint8_t *)sessionKeyData.bytes, (int)sessionKeyData.length, xkey);

            if (syncCFB) {
                decryptedData = [[PGPCryptoCFB openPGP_CFB_decrypt:encryptedData blockSize:blockSize iv:ivData cipherEncrypt:^NSData * _Nullable(NSData * _Nonnull data) {
                    let output = [NSMutableData dataWithLength:data.length];
                    Twofish_encrypt(xkey, (uint8_t *)data.bytes, output.mutableBytes);
                    return output;
                }] copy];
            } else {
                if (decrypt) {
                    // decrypt
                    NSMutableData *decryptedOutMutableData = encryptedData.mutableCopy;
                    var ciphertextBlock = [NSData dataWithData:ivData];
                    let plaintextBlock = [NSMutableData dataWithLength:blockSize];
                    for (NSUInteger index = 0; index < encryptedData.length; index += blockSize) {
                        Twofish_encrypt(xkey, (uint8_t *)ciphertextBlock.bytes, plaintextBlock.mutableBytes);
                        ciphertextBlock = [encryptedData subdataWithRange:(NSRange){index, MIN(blockSize, decryptedOutMutableData.length - index)}];
                        [decryptedOutMutableData XORWithData:plaintextBlock index:index];
                    }
                    decryptedData = decryptedOutMutableData;
                } else {
                    // encrypt
                    NSMutableData *encryptedOutMutableData = encryptedData.mutableCopy; // input plaintext
                    var plaintextBlock = [NSData dataWithData:ivData];
                    let ciphertextBlock = [NSMutableData dataWithLength:blockSize];
                    for (NSUInteger index = 0; index < encryptedData.length; index += blockSize) {
                        Twofish_encrypt(xkey, (uint8_t *)plaintextBlock.bytes, ciphertextBlock.mutableBytes);
                        [encryptedOutMutableData XORWithData:ciphertextBlock index:index];
                        plaintextBlock = [encryptedOutMutableData subdataWithRange:(NSRange){index, MIN(blockSize, encryptedOutMutableData.length - index)}]; // ciphertext.copy;
                    }
                    decryptedData = encryptedOutMutableData;
                }
            }

            memset(xkey, 0, sizeof(Twofish_key));
            free(xkey);
        } break;
        case PGPSymmetricPlaintext:
            PGPLogWarning(@"Can't decrypt plaintext");
            decryptedData = [NSMutableData dataWithData:encryptedData];
            break;
        default:
            PGPLogWarning(@"Unsupported cipher.");
            return NO;
    }
    if (decryptedData == nil) {
        return NO;
    }
    BOOL isSuccess = [decryptedData writeToFile:destinationURL.path atomically:YES];
    return isSuccess;
}

/*
 * https://tools.ietf.org/html/rfc4880#section-13.9
 * In order to support weird resyncing we have to implement CFB mode ourselves
 */
+ (nullable NSData *)openPGP_CFB_decrypt:(NSData *)data blockSize:(NSUInteger)blockSize iv:(NSData *)ivData cipherEncrypt:(nullable NSData * _Nullable(^NS_NOESCAPE)(NSData *data))cipherEncrypt {
    let BS = blockSize;
    // 1. The feedback register (FR) is set to the IV, which is all zeros.
    var FR = [NSData dataWithData:ivData];
    // 2.  FR is encrypted to produce FRE (FR Encrypted). This is the encryption of an all-zero value.
    // var FRE = [NSMutableData dataWithLength:FR.length];
    var FRE = cipherEncrypt(FR);
    // 4. FR is loaded with C[1] through C[BS].
    FR = [data subdataWithRange:(NSRange){0,BS}];
    // 3. FRE is xored with the first BS octets of random data prefixed to the plaintext to produce C[1] through C[BS], the first BS octets of ciphertext.
    let prefix = [NSData xor:FRE d2:FR];
    // 5. FR is encrypted to produce FRE, the encryption of the first BS octets of ciphertext.
    FRE = cipherEncrypt(FR);
    // 6. The left two octets of FRE get xored with the next two octets of data that were prefixed to the plaintext. This produces C[BS+1] and C[BS+2], the next two octets of ciphertext.
    if (![[prefix subdataWithRange:(NSRange){BS - 2, 2}] isEqual:[NSData xor:[FRE subdataWithRange:(NSRange){0, 2}] d2:[data subdataWithRange:(NSRange){BS, 2}]]]) {
        PGPLogDebug(@"Bad OpenPGP CFB check value");
        return nil;
    }

    var plaintext = [NSMutableData data];
    var x = 2;
    while ((x + BS) < data.length) {
        let chunk = [data subdataWithRange:(NSRange){x, BS}];
        [plaintext appendData:[NSData xor:FRE d2:chunk]];
        FRE = cipherEncrypt(chunk);
        x += BS;
    }
    [plaintext appendData:[NSData xor:FRE d2:[data subdataWithRange:(NSRange){x, MIN(BS, data.length - x)}]]];
    plaintext = [NSMutableData dataWithData:[plaintext subdataWithRange:(NSRange){BS, plaintext.length - BS}]];

    let result = [NSMutableData data];
    [result appendData:prefix];
    [result appendData:[prefix subdataWithRange:(NSRange){BS - 2, 2}]];
    [result appendData:plaintext];

    return result;
}

@end

NS_ASSUME_NONNULL_END
