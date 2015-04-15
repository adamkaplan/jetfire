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
//Exposed method for connecting to URL provided in init method.
- (void)connect
{
//    if(self.isCreated) {
//        JFRLog(self, @"already connected.");
//        return;
//    }
//    self.isCreated = YES;
    CFReadStreamRef readStream = NULL;
    CFWriteStreamRef writeStream = NULL;
    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)self.url.host, [[self port] intValue], &readStream, &writeStream);
    
    self.readController = [[JFRWebSocketReadController alloc] initWithInputStream:(__bridge  NSInputStream *)readStream];
    self.readController.delegate = self;
    self.readController.voipEnabled = self.voipEnabled;
    self.readController.allowSelfSignedSSLCertificates = self.selfSignedSSL;
    [self.readController connect];
    
    self.writeController = [[JFRWebSocketWriteController alloc] initWithOutputStream:(__bridge NSOutputStream *)writeStream];
    self.writeController.delegate = self;
    self.writeController.voipEnabled = self.voipEnabled;
    self.writeController.allowSelfSignedSSLCertificates = self.selfSignedSSL;
    [self.writeController connect];
}
/////////////////////////////////////////////////////////////////////////////
- (void)disconnect
{
    [self.writeController disconnect];
    [self.readController disconnect];
}
/////////////////////////////////////////////////////////////////////////////
-(void)writeString:(NSString*)string
{
    [self.writeController writeString:string];
}
/////////////////////////////////////////////////////////////////////////////
-(void)writeData:(NSData*)data
{
    [self.writeController writeData:data];
}
/////////////////////////////////////////////////////////////////////////////
- (void)addHeader:(NSString*)value forKey:(NSString*)key
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
    
    JFRLog(self, @"connection request:\n%@", [[NSString alloc] initWithData:serializedRequest encoding:NSUTF8StringEncoding]);
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
    [self notifyDelegateDidDisconnectWithReason:error.localizedDescription code:error.code];
}

#pragma mark - JRFWebSocketReadControllerDelegate

- (void)websocketController:(JFRWebSocketController *)controller didReceiveData:(NSData *)data {
    [self notifyDelegateDidReceiveData:data];
}

- (void)websocketController:(JFRWebSocketController *)controller didReceiveMessage:(NSString *)string {
    [self notifyDelegateDidReceiveMessage:string];
}

- (void)websocketController:(JFRWebSocketReadController *)controller didReceivePing:(NSData *)ping {
    [self.writeController writePong:ping];
    [self notifyDelegateDidReceivePing];
}

#pragma mark - JRFWebSocketWriteControllerDelegate

#pragma mark - Connection Teardown

/////////////////////////////////////////////////////////////////////////////
-(void)terminateNetworkConnections
{
    JFRLog(self, @"Terminating all network connections");
//    if (self.outputStream) {
//        self.outputStream.delegate = nil;
//        
//        if (self.outputStream.streamStatus != NSStreamStatusClosed) {
//            [self.outputStream close];
//        }
//        
//        CFWriteStreamSetDispatchQueue((CFWriteStreamRef)self.outputStream, NULL);
//    }
}
///////////////////////////////////////////////////////////////////////////////
//// Use `immediateDisconnect` to terminate all network operations immediately. Note that self.isConnected will
//- (void)disconnectStream {
//    
//    NSAssert(dispatch_get_specific(DispatchQueueIdentifierKey) == DispatchQueueIdentifierIO, @"%s Wrong queue", __PRETTY_FUNCTION__);
//    
//    JFRLog(self, @"Disconnecting stream.");
//    [self terminateNetworkConnections];
//    _isConnected = NO;
//    
//    // Callers are required to notify the delegate that the connection has disconnected
//}
///////////////////////////////////////////////////////////////////////////////
//// Use `deferredDisconnectWithError:` to enqueue disconnection on the processing queue. This has the benefit of
//// terminating all network activity, but continuing to process any pending messages.
//- (void)disconnectStreamDeferredWithReason:(NSString *)reason code:(NSInteger)code {
//    
//    NSAssert(dispatch_get_specific(DispatchQueueIdentifierKey) == DispatchQueueIdentifierIO, @"%s Wrong queue", __PRETTY_FUNCTION__);
//
//    if (self.isConnected) {
//        
//        if (code == JFRCloseCodeNormal) {
//            JFRLog(self, @"Disconnecting cleanly.");
//        } else {
//            JFRLog(self, @"Disconnecting with error %ld - %@.", code, reason);
//        }
//        
//        // Notify delegate of disconnection after any pending frame parsing completes.
//        __weak typeof(self) weakSelf = self;
//        dispatch_async(self.parsingQueue, ^{
//            [weakSelf notifyDelegateDidDisconnectWithReason:reason code:code];
//        });
//    }
//    
//    [self terminateNetworkConnections];
//    _isConnected = NO;
//}
/////////////////////////////////////////////////////////////////////////////

#pragma mark - Stream Processing Methods

/////////////////////////////////////////////////////////////////////////////
//-(void)writeError:(uint16_t)code
//{
//    JFRLog(self, @"Writing error code %d", code);
//    
//    if (self.ioQueue) {
//        __weak typeof(self) weakSelf = self;
//        dispatch_async(self.ioQueue, ^{
//            //uint16_t buffer[1] = { CFSwapInt16BigToHost(code) };
//            uint16_t networkCode = CFSwapInt16BigToHost(code);
//            [weakSelf dequeueWrite:[NSData dataWithBytes:&networkCode length:sizeof(uint16_t)] withCode:JFROpCodeConnectionClose];
//        });
//    }
//}
/////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////
//-(void)doWriteError
//{
//    NSError *error = [self.outputStream streamError];
//    if (error) {
//        [self disconnectStreamDeferredWithReason:error.localizedDescription code:error.code];
//    } else {
//        [self disconnectStreamDeferredWithReason:@"output stream error during write" code:2];
//    }
//}
/////////////////////////////////////////////////////////////////////////////
-(NSError*)errorWithDetail:(NSString*)detail code:(NSInteger)code
{
    NSDictionary* userInfo;
    if (detail) {
        userInfo = @{ NSLocalizedDescriptionKey: detail };
    }
    return [NSError errorWithDomain:errorDomain code:code userInfo:userInfo];
}

#pragma mark - Delegate Notification

/////////////////////////////////////////////////////////////////////////////
// Centralize all delegate communication for simplicity. Nice side effect is improved branch
// prediction by sharing the `responseToSelector` conditionals that don't usually change.
-(void)notifyDelegateDidConnect {
    if (![self.delegate respondsToSelector:@selector(websocketDidConnect:)]) {
        return;
    }
    
    dispatch_async(self.delegateQueue, ^{
        [self.delegate websocketDidConnect:self];
    });
}

-(void)notifyDelegateDidDisconnectWithReason:(NSString *)reason code:(NSInteger)code {
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

-(void)notifyDelegateDidReceiveMessage:(NSString *)message {
    if (![self.delegate respondsToSelector:@selector(websocket:didReceiveMessage:)]) {
        return;
    }
    
    dispatch_async(self.delegateQueue, ^{
        [self.delegate websocket:self didReceiveMessage:message];
    });
}

-(void)notifyDelegateDidReceiveData:(NSData *)data {
    if (![self.delegate respondsToSelector:@selector(websocket:didReceiveData:)]) {
        return;
    }
    
    dispatch_async(self.delegateQueue, ^{
        [self.delegate websocket:self didReceiveData:data];
    });
    
}

-(void)notifyDelegateDidReceivePing {
    if (![self.delegate respondsToSelector:@selector(websocketDidReceivePing:)]) {
        return;
    }
    
    dispatch_async(self.delegateQueue, ^{
        [self.delegate websocketDidReceivePing:self];
    });
}

/////////////////////////////////////////////////////////////////////////////
-(void)dealloc
{
    self.readController.delegate = nil;
    self.writeController.delegate = nil;
}
/////////////////////////////////////////////////////////////////////////////
@end
