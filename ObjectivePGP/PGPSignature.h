//
//  PGPSignature.h
//  ObjectivePGP
//
//  Created by Marcin Krzyzanowski on 30/01/15.
//  Copyright (c) 2015 Marcin Krzyżanowski. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "PGPSignatureSubpacket.h"
#import "PGPSignaturePacket.h"
#import "PGPKeyID.h"
#import "PGPKey.h"
#import "PGPUser.h"

@interface PGPSignature : NSObject
@property (assign) PGPSignatureType type;
@property (copy) NSDate *creationDate;
@property (copy) PGPKeyID *issuerKeyID;
@property (strong, readonly) PGPSignaturePacket *packet;

- (instancetype)initWithPacket:(PGPSignaturePacket *)packet NS_DESIGNATED_INITIALIZER;
- (UInt16) computeSignatureHashOverKey:(PGPKey *)key user:(PGPUser *)user error:(NSError * __autoreleasing *)error;
@end

NSData *buildDataToSign(PGPSignatureType type, NSUInteger version, PGPKey *key, PGPUser *user, NSData *userAttribute, NSData *data, NSError * __autoreleasing *error);