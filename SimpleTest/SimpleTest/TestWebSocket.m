//
//  TestWebSocket.m
//  SimpleTest
//
//  Created by Adam Kaplan on 4/13/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import "TestWebSocket.h"

@implementation TestWebSocket

+ (instancetype)testSocketForCommand:(NSString *)command {
    return [self testSocketForCommand:command parameters:nil];
}

+ (instancetype)testSocketForCommand:(NSString *)command parameters:(NSDictionary *)params {
    NSURL *const BaseUrl = [NSURL URLWithString:@"ws://localhost:9001"];
    
    NSMutableArray *queryItems = [NSMutableArray array];
    for (id key in params) {
        NSURLQueryItem *item = [NSURLQueryItem queryItemWithName:key value:params[key]];
        [queryItems addObject:item];
    }

    NSURLComponents *components = [[NSURLComponents alloc] initWithURL:BaseUrl resolvingAgainstBaseURL:NO];
    components.path = [@"/" stringByAppendingString:command];
    components.queryItems = queryItems;
    
    //NSLog(@"%@", components.URL);
    TestWebSocket *socket = [[self alloc] initWithURL:components.URL protocols:@[]];
    return socket;
}

@end
