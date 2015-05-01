/////////////////////////////////////////////////////////////////////////////
//
//  JFRWebSocket.m
//
//  Created by Austin and Dalton Cherry on 5/13/14.
//  Copyright (c) 2014 Vluxe. All rights reserved.
//
/////////////////////////////////////////////////////////////////////////////

#import "JFRWebSocket.h"
#import "JFRWebSocketReadController.h"
#import "JFRWebSocketWriteController.h"
#import "JFRWebSocketControllerDelegate.h"
#import "JFRLog.h"
#import "NSData+JFRBinaryInspection.h"

#if defined(TEST) || 1
static const BOOL kJFRSerializeCloseHandler = YES; // For testing, message processing need to be serial
#else
static const BOOL kJFRSerializeCloseHandler = NO;
#endif

@interface JFRWebSocket () <JFRWebSocketReadControllerDelegate, JFRWebSocketWriteControllerDelegate>
@property (atomic) NSDictionary *headers;
@property (nonatomic) NSURL *url;
@property (nonatomic) NSArray *optProtocols;
@property (nonatomic) JFRWebSocketReadController *readController;
@property (nonatomic) JFRWebSocketWriteController *writeController;
@end

//Constant Header Values.
static const CFStringRef headerWSUpgradeName        = CFSTR("Upgrade");
static const CFStringRef headerWSUpgradeValue       = CFSTR("websocket");
static const CFStringRef headerWSHostName           = CFSTR("Host");
static const CFStringRef headerWSConnectionName     = CFSTR("Connection");
static const CFStringRef headerWSConnectionValue    = CFSTR("Upgrade");
static const CFStringRef headerWSProtocolName       = CFSTR("Sec-WebSocket-Protocol");
static const CFStringRef headerWSVersionName        = CFSTR("Sec-Websocket-Version");
static const CFStringRef headerWSVersionValue       = CFSTR("13");
static const CFStringRef headerWSKeyName            = CFSTR("Sec-WebSocket-Key");
static const CFStringRef headerOriginName           = CFSTR("Origin");

static NSString *const errorDomain = @"JFRWebSocket";


@implementation JFRWebSocket

/////////////////////////////////////////////////////////////////////////////
//Default initializer
- (instancetype)initWithURL:(NSURL *)url protocols:(NSArray*)protocols
{
    NSParameterAssert(url);
    
    if(self = [super init]) {
        self.voipEnabled = NO;
        self.selfSignedSSL = NO;
        self.delegateQueue = dispatch_get_main_queue();
        self.url = url;
        self.optProtocols = protocols;
    }
    
    return self;
}
/////////////////////////////////////////////////////////////////////////////
- (void)dealloc {
    self.readController.delegate = nil;
    self.writeController.delegate = nil;
}
/////////////////////////////////////////////////////////////////////////////
//Exposed method for connecting to URL provided in init method.
- (void)connect
{
//    if(self.isCreated) {
//        JFRLog(JFRWarn, @"already connected.");
//        return;
//    }
//    self.isCreated = YES;
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)self.url.host, [[self port] intValue], &readStream, &writeStream);
    
    self.readController = [[JFRWebSocketReadController alloc] initWithInputStream:readStream];
    self.readController.delegate = self;
    self.readController.voipEnabled = self.voipEnabled;
    self.readController.allowSelfSignedSSLCertificates = self.selfSignedSSL;
    [self.readController connect];
    
    self.writeController = [[JFRWebSocketWriteController alloc] initWithOutputStream:writeStream];
    self.writeController.delegate = self;
    self.writeController.voipEnabled = self.voipEnabled;
    self.writeController.allowSelfSignedSSLCertificates = self.selfSignedSSL;
    [self.writeController connect];
}
/////////////////////////////////////////////////////////////////////////////
- (void)disconnect
{
    NSError *error = [JFRWebSocketController errorWithDetail:nil code:JFRCloseCodeNormal];
    [self websocketController:nil shouldCloseWithError:error];
}
/////////////////////////////////////////////////////////////////////////////
-(void)writeString:(NSString *)string
{
    [self.writeController writeString:string];
}
/////////////////////////////////////////////////////////////////////////////
-(void)writeData:(NSData *)data
{
    [self.writeController writeData:data];
}
/////////////////////////////////////////////////////////////////////////////
- (void)addHeader:(NSString *)value forKey:(NSString *)key
{
    // This method is not expected to be called often. Opt for the safety of immutability.
    NSMutableDictionary *mutableHeaders = self.headers ? [self.headers mutableCopy] : [NSMutableDictionary dictionary];
    mutableHeaders[key] = value;
    self.headers = [mutableHeaders copy];
}
/////////////////////////////////////////////////////////////////////////////

#pragma mark - connect's internal supporting methods

- (NSNumber *)port {
    NSNumber *port = self.url.port;
    if (!port) {
        if ([self.url.scheme isEqualToString:@"wss"] || [self.url.scheme isEqualToString:@"https"]){
            port = @443;
        } else {
            port = @80;
        }
    }
    return port;
}

/////////////////////////////////////////////////////////////////////////////
//Uses CoreFoundation to build a HTTP request to send over TCP stream.
- (NSData *)createHTTPRequest
{
    CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, (CFStringRef)self.url.absoluteString, NULL);
    CFStringRef requestMethod = CFSTR("GET");
    CFHTTPMessageRef urlRequest = CFHTTPMessageCreateRequest(kCFAllocatorDefault,
                                                             requestMethod,
                                                             url,
                                                             kCFHTTPVersion1_1);
    CFRelease(url);
    
    NSNumber *port = [self port];
    
    CFHTTPMessageSetHeaderFieldValue(urlRequest, headerWSUpgradeName, headerWSUpgradeValue);
    
    CFHTTPMessageSetHeaderFieldValue(urlRequest, headerWSConnectionName, headerWSConnectionValue);
    
    CFHTTPMessageSetHeaderFieldValue(urlRequest, headerWSVersionName, headerWSVersionValue);
    
    CFHTTPMessageSetHeaderFieldValue(urlRequest, headerWSKeyName, (__bridge CFStringRef)[self generateWebSocketKey]);
    
    CFHTTPMessageSetHeaderFieldValue(urlRequest, headerOriginName, (__bridge CFStringRef)self.url.absoluteString);
    
    CFHTTPMessageSetHeaderFieldValue(urlRequest, headerWSHostName,
                                     (__bridge CFStringRef)[NSString stringWithFormat:@"%@:%@", self.url.host, port]);
    
    if(self.optProtocols.count) {
        NSString *protocols = [self.optProtocols componentsJoinedByString:@","];
        CFHTTPMessageSetHeaderFieldValue(urlRequest, headerWSProtocolName, (__bridge CFStringRef)protocols);
    }
    
    for(NSString *key in self.headers) {
        CFHTTPMessageSetHeaderFieldValue(urlRequest, (__bridge CFStringRef)key, (__bridge CFStringRef)self.headers[key]);
    }
    
    NSData *serializedRequest = (__bridge_transfer NSData *)(CFHTTPMessageCopySerializedMessage(urlRequest));
    CFRelease(urlRequest);
    
    JFRLog(JFRInfo, @"connection request:\n%@", [[NSString alloc] initWithData:serializedRequest encoding:NSUTF8StringEncoding]);
    return serializedRequest;
}
/////////////////////////////////////////////////////////////////////////////
//Random String of 16 lowercase chars, SHA1 and base64 encoded.
- (NSString *)generateWebSocketKey
{
    NSInteger seed = 16;
    NSMutableString *string = [NSMutableString stringWithCapacity:seed];
    for(int i = 0; i < seed; i++) {
        [string appendFormat:@"%C", (unichar)('a' + arc4random_uniform(25))];
    }
    return [[string dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
}

#pragma mark - JRFWebSocketControllerDelegate

- (void)websocketControllerDidConnect:(JFRWebSocketController *)controller {
    if (controller == self.writeController) {
        NSData *data = [self createHTTPRequest];
        [self.writeController writeRawData:data];
        [self notifyDelegateDidConnect];
    }
}

- (void)websocketControllerDidDisconnect:(JFRWebSocketController *)controller error:(NSError *)error {
    if (self.writeController.status != JFRSocketControllerStatusClosed || self.readController.status != JFRSocketControllerStatusClosed) {
        // If this delegate method was triggered while the connections are still open, it indicates a
        // transport-layer error. Per the RFC, ok to tear up the socket.
        [self.writeController disconnect];
        [self.readController disconnect];
    }
    [self notifyDelegateDidDisconnectWithReason:error.localizedDescription code:error.code];
}

// Fail the WS immediately (client close connection)
- (void)websocketController:(JFRWebSocketController *)controller shouldFailWithError:(NSError *)error {
    if (kJFRSerializeCloseHandler) {
        dispatch_async(self.delegateQueue, ^{
            [self.writeController failWithCloseCode:error.code reason:error.localizedDescription];
        });
    } else {
        [self.writeController failWithCloseCode:error.code reason:error.localizedDescription];
    }

}

// Close the WS with an error (server closes connection)
- (void)websocketController:(JFRWebSocketController *)controller shouldCloseWithError:(NSError *)error {
    // The close handshake requires that the client & server must both send AND recieve a close frame.

    void(^block)(void) = ^{
        if (kJFRSerializeCloseHandler) {
            dispatch_async(self.delegateQueue, ^{
                [self.writeController writeCloseCode:error.code reason:error.localizedDescription];
            });
        } else {
            [self.writeController writeCloseCode:error.code reason:error.localizedDescription];
        }
    };
    
    if (self.readController.status == JFRSocketControllerStatusClosed || self.writeController.status == JFRSocketControllerStatusClosed) {
        [self websocketControllerDidDisconnect:controller error:error];
        
    } else if (self.writeController.status == JFRSocketControllerStatusClosingHandshakeComplete) {
        // Client-initiated close. Wait for server close frame to complete handshake, or time out.
        [self.readController initiateCloseForTimeInterval:10.0];
        
    } else if (self.readController.status == JFRSocketControllerStatusClosingHandshakeComplete) {
        // Server-initiated close. Send close frame to complete handshake
        //[self.writeController writeCloseCode:error.code reason:error.localizedDescription];
        block();
        
    } else if (self.writeController.status == JFRSocketControllerStatusOpen) {
        // this is what happens if -disconnect is called (user requested close) during an open connection.
        //[self.writeController writeCloseCode:error.code reason:error.localizedDescription];
        block();
    }
}

#pragma mark - JRFWebSocketReadControllerDelegate

- (void)websocketController:(JFRWebSocketController *)controller didReceiveData:(NSData *)data {
    [self notifyDelegateDidReceiveData:data];
}

- (void)websocketController:(JFRWebSocketController *)controller didReceiveMessage:(NSString *)string {
    [self notifyDelegateDidReceiveMessage:string];
}

- (void)websocketController:(JFRWebSocketReadController *)controller didReceivePing:(NSData *)ping {
    if (kJFRSerializeCloseHandler) {
        dispatch_async(self.delegateQueue, ^{ [self.writeController writePong:ping]; });
    } else {
        [self.writeController writePong:ping];
    }
    
    [self notifyDelegateDidReceivePing];
}

#pragma mark - JRFWebSocketWriteControllerDelegate

#pragma mark - Connection Teardown

/////////////////////////////////////////////////////////////////////////////
- (void)terminateNetworkConnections
{
    JFRLog(JFRInfo, @"Terminating all network connections");
}

- (NSError *)errorWithDetail:(NSString *)detail code:(NSInteger)code
{
    NSDictionary *userInfo;
    if (detail) {
        userInfo = @{ NSLocalizedDescriptionKey: detail };
    }
    return [NSError errorWithDomain:errorDomain code:code userInfo:userInfo];
}

#pragma mark - Delegate Notification

// Centralize all delegate communication for simplicity. Nice side effect is improved branch
// prediction by sharing the `responseToSelector` conditionals that don't usually change.
- (void)notifyDelegateDidConnect {
    if (![self.delegate respondsToSelector:@selector(websocketDidConnect:)]) {
        return;
    }
    
    dispatch_async(self.delegateQueue, ^{
        [self.delegate websocketDidConnect:self];
    });
}

- (void)notifyDelegateDidDisconnectWithReason:(NSString *)reason code:(NSInteger)code {
    if (![self.delegate respondsToSelector:@selector(websocketDidDisconnect:error:)]) {
        return;
    }
    
    dispatch_async(self.delegateQueue, ^{
        NSError *error;
        if (code != JFRCloseCodeNormal) {
            error = [self errorWithDetail:reason code:code];
        }
        [self.delegate websocketDidDisconnect:self error:error];
    });
}

- (void)notifyDelegateDidReceiveMessage:(NSString *)message {
    if (![self.delegate respondsToSelector:@selector(websocket:didReceiveMessage:)]) {
        return;
    }
    
    dispatch_async(self.delegateQueue, ^{
        [self.delegate websocket:self didReceiveMessage:message];
    });
}

- (void)notifyDelegateDidReceiveData:(NSData *)data {
    if (![self.delegate respondsToSelector:@selector(websocket:didReceiveData:)]) {
        return;
    }
    
    dispatch_async(self.delegateQueue, ^{
        [self.delegate websocket:self didReceiveData:data];
    });
    
}

- (void)notifyDelegateDidReceivePing {
    if (![self.delegate respondsToSelector:@selector(websocketDidReceivePing:)]) {
        return;
    }
    
    dispatch_async(self.delegateQueue, ^{
        [self.delegate websocketDidReceivePing:self];
    });
}

@end
