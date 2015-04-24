//
//  JFRWebSocketController.m
//  SimpleTest
//
//  Created by Adam Kaplan on 4/20/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import "JFRWebSocketController.h"

const void *const kJFRSocketReadControllerQueueIdentifierKey = "JFRSocketReadControllerQueueIdentifierKey";
// Dispatch Queue Property Values
const void *const kJFRSocketReadControllerQueueIdentifierIO  = "JFRSocketReadControllerQueueIdentifierIO";

static NSString *const kJFRErrorDomain = @"JFRWebSocket";


@implementation JFRWebSocketController

+ (NSError *)errorWithDetail:(NSString *)detail code:(NSInteger)code {
    static NSDictionary *EmptyUserInfo;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // User info dictionary with an explicit empty localized description. Otherwise NSError
        // will make up something random, which is sent off the the server (which will fail the cnxn)
        EmptyUserInfo = @{ NSLocalizedDescriptionKey: @"" };
    });
    
    NSDictionary *userInfo = EmptyUserInfo;
    if (detail) {
        userInfo = @{ NSLocalizedDescriptionKey: detail };
    }
    
    return [NSError errorWithDomain:kJFRErrorDomain code:code userInfo:userInfo];
}

@end
