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
    NSDictionary* userInfo;
    if (detail) {
        userInfo = @{ NSLocalizedDescriptionKey: detail };
    }
    return [NSError errorWithDomain:kJFRErrorDomain code:code userInfo:userInfo];
}

@end
