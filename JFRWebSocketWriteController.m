//
//  JFRWebSocketWriteController.m
//  SimpleTest
//
//  Created by Adam Kaplan on 4/20/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import "JFRWebSocketWriteController.h"
#import "JFRLog.h"
#import <objc/runtime.h>

@interface JFRWebSocketWriteController ()
/** Serial queue used for blocking I/O operations */
@property (nonatomic) dispatch_queue_t ioQueue;

- (void)stream:(CFWriteStreamRef)stream handleEvent:(CFStreamEventType)eventCode;
@end

static void writeStreamCallback(CFWriteStreamRef stream, CFStreamEventType type, void *clientCallbackInfo) {
    @autoreleasepool {
        JFRWebSocketWriteController *self = (__bridge JFRWebSocketWriteController *)clientCallbackInfo; // should be retained as per configuration
        [self stream:stream handleEvent:type];
    }
}

@implementation JFRWebSocketWriteController

@synthesize status = _status;

#pragma mark - Instance Lifecycle

- (instancetype)initWithOutputStream:(CFWriteStreamRef)outputStream {
    
    if (CFWriteStreamGetStatus(outputStream) != kCFStreamStatusNotOpen) {
        NSAssert(false, @"The provided outputStream must be un-opened.");
        @throw NSInternalInconsistencyException;
        return nil;
    }
    
    if (self = [super init]) {
        _outputStream = outputStream;
        
        _ioQueue = dispatch_queue_create("com.vluxe.jetfire.socket.write", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_ioQueue, kJFRSocketReadControllerQueueIdentifierKey, (void*)kJFRSocketReadControllerQueueIdentifierIO, NULL);
        
        _status = JFRSocketControllerStatusNew;
    }
    return self;
}

- (void)dealloc {
    [self p_destroyOutputStream];
}

#pragma mark - API

- (void)connect {
    if (self.status != JFRSocketControllerStatusNew) {
        NSAssert(false, @"Re-using socket controllers is not currently supported");
        @throw NSInternalInconsistencyException;
        return;
    }
    
    _status = JFRSocketControllerStatusOpening;
    
    // Setup the input stream
    [self p_configureOutputStream];
    CFWriteStreamOpen(self.outputStream);
}

- (void)disconnect {
    JFRLog(self, @"Disconnecting write stream");

    [self writeCloseCode:JFRCloseCodeNormal reason:nil];
}


- (void)failWithCloseCode:(NSUInteger)code reason:(NSString *)reason {
    JFRLog(self, @"Failing write stream");
    
    [self writeCloseCode:code reason:reason failConnection:YES];
}

- (void)writeString:(NSString *)string {
    NSAssert(_status == JFRSocketControllerStatusOpen, @"Writing to unopened stream");
    //JFRLog(self, @"Writing string of length %lu: %@", string.length, string);
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        NSUInteger length = [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        [weakSelf writeFrameBuffer:(uint8_t *)[string UTF8String] length:length opcode:JFROpCodeTextFrame];
    });
}

- (void)writeData:(NSData *)data {
    [self writeData:data opcode:JFROpCodeBinaryFrame];
}

- (void)writePing:(NSData *)data {
    [self writeData:data opcode:JFROpCodePing];
}

- (void)writePong:(NSData *)data {
    [self writeData:data opcode:JFROpCodePong];
}

- (void)writeData:(NSData *)data opcode:(JFROpCode)opcode {
    NSAssert(_status == JFRSocketControllerStatusOpen, @"Writing to unopened stream");
    JFRLog(self, @"Writing data (opcode %lu) of length %lu", opcode, data.length);
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        [weakSelf writeFrameBuffer:(uint8_t *)[data bytes] length:[data length] opcode:opcode];
    });
}

- (void)writeCloseCode:(NSUInteger)code reason:(NSString *)reason {
    [self writeCloseCode:code reason:reason failConnection:NO];
}

- (void)writeCloseCode:(NSUInteger)code reason:(NSString *)reason failConnection:(BOOL)failConnection {
    if (_status != JFRSocketControllerStatusOpen) {
        NSLog(@"Attempt to write to unopened stream");
        return;
    }
    //NSAssert(_status == JFRSocketControllerStatusOpen || _status == JFRSocketControllerStatusClosing, @"Writing to unopened stream");
    JFRLog(self, @"Writing close packet with code %lu, %@", code, reason);

    _status = JFRSocketControllerStatusClosingHandshakeInitiated;
    
    uint8_t *buffer = NULL;
    size_t length = 0;
    if (code != JFRCloseCodeNoStatusReceived) {
        length = sizeof(uint16_t);
        if (reason.length) {
            length += [reason lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        }
        
        buffer = malloc(sizeof(uint8_t) * length);
        *(uint16_t*)buffer = CFSwapInt16HostToBig(code);
        
        if (reason.length) {
            memcpy(buffer + sizeof(uint16_t), [reason UTF8String], length - sizeof(uint16_t));
        }
    }
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.ioQueue, ^{
        [weakSelf writeFrameBuffer:buffer length:length opcode:JFROpCodeConnectionClose];
        
        if (buffer) {
            free(buffer);
        }
        
        _status = JFRSocketControllerStatusClosingHandshakeComplete;
        
        if (failConnection) {
            [self p_destroyOutputStream];
        }
        
        NSError *closeError = [[weakSelf class] errorWithDetail:reason code:code];
        [weakSelf.delegate websocketController:weakSelf shouldCloseWithError:closeError];
    });
}

- (void)writeRawData:(NSData *)data {
    NSAssert(_status == JFRSocketControllerStatusOpen, @"Writing to unopened stream");
    JFRLog(self, @"Writing raw data of length %lu", data.length);
    
    dispatch_async(self.ioQueue, ^{
        [self writeBuffer:(const UInt8 *)[data bytes] length:[data length]];
    });
}

#pragma mark -
#pragma mark Private

/** Wraps buffer in a web socket frame with opcode, and sends it along to the wire.
 * @returns The total bytes written, which may be more than `length` due to the web socket protocol frame.
 *      If this value is negative, an error occurred.
 */
-(CFIndex)writeFrameBuffer:(const UInt8 *)buffer length:(const CFIndex)length opcode:(const JFROpCode)code
{
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierIO,
             @"%s Wrong queue", __PRETTY_FUNCTION__);
    
    UInt64 offset = 2; // how many bytes do we need to skip for the header

    UInt8 *frameBuffer = malloc(sizeof(UInt8) * length + JFRMaxFrameSize);
    frameBuffer[0] = JFRFinMask | code;
    
    // Encode data length per frame specification
    if (length < 126) {
        frameBuffer[1] = length;
        
    } else if (length <= UINT16_MAX) {
        frameBuffer[1] = 126;
        *((UInt16 *)(frameBuffer + offset)) = CFSwapInt16HostToBig((UInt16)length);
        offset += sizeof(UInt16);
        
    } else {
        frameBuffer[1] = 127;
        *((UInt64 *)(frameBuffer + offset)) = CFSwapInt64HostToBig((UInt64)length);
        offset += sizeof(UInt64);
    }
    
    // Mask payload to ensure proxys cannot introspect payload
    BOOL isMask = YES;
//    if (code == JFROpCodeConnectionClose && length < 2) {
//        // Must only include mask key on a close frame if a "close reason" is provided. The 16-bit
//        // close code is not to be masked.
//        isMask = NO;
//    }
    if(isMask) {
        frameBuffer[1] |= JFRMaskMask;
        UInt8 *mask_key = frameBuffer + offset;
        SecRandomCopyBytes(kSecRandomDefault, sizeof(UInt32), mask_key);
        offset += sizeof(UInt32);
        
        for(size_t l = offset, r = 0; r < length; r++, l++) {
            frameBuffer[l] = buffer[r] ^ mask_key[r % sizeof(UInt32)];
        }
    } else {
        memcpy(frameBuffer + offset, buffer, length);
    }

    // Write all data
    return [self writeBuffer:frameBuffer length:offset + length];
}

/** Writes the buffer directly to the output stream, blocking as needed until all bytes are written or an error occurs
 * @returns the number of bytes written. If return value is negative, an error occurred.
 */
- (CFIndex)writeBuffer:(const UInt8 *)buffer length:(const CFIndex)length {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierIO,
             @"%s Wrong queue", __PRETTY_FUNCTION__);
    NSParameterAssert(buffer);
    NSParameterAssert(length);
    
    CFIndex total = 0;
    while (self.outputStream && total < length) {
        
        CFIndex written = CFWriteStreamWrite(self.outputStream, buffer + total, length - total);
        if (written < 0) {
            NSError *error = CFBridgingRelease(CFWriteStreamCopyError(self.outputStream));
            JFRLog(self, @"write error %ld %@", CFWriteStreamGetStatus(self.outputStream), error);
            [self p_destroyOutputStream];
            [self.delegate websocketController:self shouldCloseWithError:error];
            return -1;
        
        } else if (written == 0) {
            JFRLog(self, @"write stream full. Dropped %lu bytes on the floor", written);
            
        } else {
            JFRLog(self, @"wrote %lu bytes", written);
            total += written;
        }
    }
    return total;
}

- (void)stream:(CFWriteStreamRef)stream handleEvent:(CFStreamEventType)eventCode {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierIO,
             @"%s Wrong queue", __PRETTY_FUNCTION__);
    
    switch (eventCode) {
            
        case NSStreamEventOpenCompleted:
            JFRLog(self, @"%p write stream open", stream);
            
            _status = JFRSocketControllerStatusOpening;
            break;
            
        case NSStreamEventHasSpaceAvailable:
        {
            JFRLog(self, @"%p write stream has space", stream);
            
            if (_status == JFRSocketControllerStatusOpening) {
                _status = JFRSocketControllerStatusOpen;
                [self.delegate websocketControllerDidConnect:self];
            }
            break;
        }
        case NSStreamEventErrorOccurred:
        {
            NSError *error = (__bridge NSError *)CFWriteStreamCopyError(self.outputStream);
            JFRLog(self, @"%p write stream error: %@", stream, error);
            
            [self p_destroyOutputStream];
            [self.delegate websocketController:self shouldCloseWithError:error];
            break;
        }
        default:
            JFRLog(self, @"%p write stream – unknown event", stream);
            break;
    }
}

#pragma mark Stream Lifecycle

- (void)p_configureOutputStream {
    
    CFStreamClientContext context = {
        .version = 0,
        .info = (__bridge void *)(self),
        .retain = (void*(*)(void*))CFRetain,
        .release = (void(*)(void*))CFRelease,
        .copyDescription = NULL
    };
    
    CFWriteStreamSetClient(self.outputStream,
                           kCFStreamEventOpenCompleted | kCFStreamEventCanAcceptBytes | kCFStreamEventErrorOccurred,
                           writeStreamCallback, &context);
    
    CFWriteStreamSetDispatchQueue(self.outputStream, self.ioQueue);
    
    if (self.sslEnabled) {
        CFWriteStreamSetProperty(self.outputStream, kCFStreamPropertySocketSecurityLevel, kCFStreamSocketSecurityLevelNegotiatedSSL);
        
        if (self.allowSelfSignedSSLCertificates) {
            NSDictionary *settings = @{ (NSString *)kCFStreamSSLValidatesCertificateChain: @NO,
                                        (NSString *)kCFStreamSSLPeerName: [NSNull null] };
            
            CFWriteStreamSetProperty(self.outputStream, kCFStreamPropertySSLSettings, (CFDictionaryRef)settings);
        }
    }
    
    if(self.voipEnabled) {
        CFWriteStreamSetProperty(self.outputStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
    }
}

/** Closes the connection, removes the delegate to prevent further callbacks, de-registers from the
 * runloop (queue) and releases the work queue.
 */
- (void)p_destroyOutputStream {
    _status = JFRSocketControllerStatusClosed;
    
    CFWriteStreamRef stream = self.outputStream;
    if (stream) {
        CFRetain(stream); // ensure that the write stream will not disappear on us
        
        CFWriteStreamSetDispatchQueue(stream, NULL);
        CFWriteStreamSetClient(stream, kCFStreamEventNone, NULL, NULL);
        //CFWriteStreamClose(stream);
        
        CFRelease(stream);
        _outputStream = NULL;
    }
    
    //    _ioQueue = nil;
}

@end
