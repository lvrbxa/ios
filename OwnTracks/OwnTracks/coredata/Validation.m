//
//  Validation.m
//  OwnTracks
//
//  Created by Christoph Krey on 13.11.23.
//  Copyright © 2023-2026 OwnTracks. All rights reserved.
//
//  改造版: JSONスキーマ検証（DSJSONSchemaValidation）を外し、JSONとして読むだけにした。

#import "Validation.h"
#import "OwnTracksLog.h"

@implementation Validation
static Validation *theInstance = nil;

+ (Validation *)sharedInstance {
    if (theInstance == nil) {
        theInstance = [[self alloc] init];
    }
    return theInstance;
}

- (id)validateMessageData:(NSData *)data {
    return [self parse:data];
}

- (id)validateMessagesData:(NSData *)data {
    return [self parse:data];
}

- (id)validateEncryptionData:(NSData *)data {
    return [self parse:data];
}

- (id)parse:(NSData *)data {
    if (!data || ![data isKindOfClass:[NSData class]]) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

@end
