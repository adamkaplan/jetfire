//
//  TestOperation.m
//  SimpleTest
//
//  Created by Adam Kaplan on 4/14/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import "TestOperation.h"
#import "JFRWebSocket.h"
#import "TestWebSocket.h"
#import "TestCase.h"

static NSString *testAgent;

@interface TestOperation () <JFRWebSocketDelegate>
@property (nonatomic) BOOL isExecuting;
@property (nonatomic) BOOL isFinished;
@end

@implementation TestOperation

+ (void)initialize {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        testAgent = [NSBundle bundleForClass:[self class]].bundleIdentifier;
        NSAssert(testAgent, @"Unable to find bundle identifier");
    });
}

- (instancetype)initWithTestCase:(TestCase *)testCase command:(NSString *)command {
    if (self = [super init]) {
        _testCase = testCase;
        NSMutableDictionary *params = [NSMutableDictionary dictionary];
        params[@"agent"] = testAgent;
        if (testCase.number) {
            params[@"case"] = testCase.number;
        }
        
        _socket = [TestWebSocket testSocketForCommand:command parameters:params];
        _socket.delegate = self;
    }
    return self;
}

- (BOOL)isConcurrent {
    return YES;
}

- (void)main {
    self.isExecuting = YES;
    if (self.startDelayTimeInterval > 0.) {
        [NSThread sleepForTimeInterval:self.startDelayTimeInterval];
    }
    [self.socket connect];
}

- (void)setExecuting:(BOOL)executing finished:(BOOL)finished {
    [self willChangeValueForKey:@"isExecuting"];
    [self willChangeValueForKey:@"isFinished"];
    
    self.isExecuting = executing;
    self.isFinished = finished;
    
    [self didChangeValueForKey:@"isFinished"];
    [self didChangeValueForKey:@"isExecuting"];
}

- (void)done {
    [self.socket disconnect];
}

- (void)dealloc {
    self.socket.delegate = nil;
    self.socket = nil;
}

#pragma mark -

- (void)websocketDidConnect:(JFRWebSocket*)socket {
    NSLog(@"[client] connected");
}

- (void)websocketDidDisconnect:(JFRWebSocket *)socket error:(NSError *)error {
    NSString *reason = error ? [error localizedDescription] : @"cleanly";
    NSLog(@"[client] disconnected %@", reason);
    
    self.socket.lastError = error;
    self.socket.delegate = nil;
    [self setExecuting:NO finished:YES];
}

- (void)websocket:(JFRWebSocket *)socket didReceiveMessage:(NSString *)string {
    //NSLog(@"[client] received message [%@]", string);
    NSLog(@"[client] received message");
    
    self.socket.receivedText = string;
    if (self.mimic) {
        [self.socket writeString:string];
    }
}

- (void)websocket:(JFRWebSocket *)socket didReceiveData:(NSData *)data {
    //NSLog(@"[client] received data %@", data);
    NSLog(@"[client] received data");
    
    self.socket.receivedData = data;
    if (self.mimic) {
        [self.socket writeData:data];
    }
}

- (void)websocketDidReceivePing:(JFRWebSocket *)socket {
    NSLog(@"[client] ping!");
    
    self.socket.receivedPing = YES;
}

@end
