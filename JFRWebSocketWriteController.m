//
//  JFRWebSocketWriteController.m
//  SimpleTest
//
//  Created by Adam Kaplan on 4/20/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import "JFRWebSocketWriteController.h"
#import "JFRLog.h"

@interface JFRWebSocketWriteController () <NSStreamDelegate>
/** Serial queue used for blocking I/O operations */
@property (nonatomic) dispatch_queue_t ioQueue;
@end

@implementation JFRWebSocketWriteController

@synthesize status = _status;

#pragma mark - Lifecycle

- (instancetype)initWithOutputStream:(NSOutputStream *)outputStream {
    
    if (outputStream.streamStatus != NSStreamStatusNotOpen) {
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
    self.outputStream.delegate = nil;
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
    [self.outputStream open];
}

- (void)disconnect {
    _status = JFRSocketControllerStatusClosing;
    
    dispatch_async(self.ioQueue, ^{
        [self.outputStream close];
        _status = JFRSocketControllerStatusClosed;
    });
    
    //dispatch_suspend(self.ioQueue);
}

- (void)writeString:(NSString *)string {
    NSAssert(_status == JFRSocketControllerStatusOpen, @"Writing to unopened stream");
    JFRLog(self, @"Writing string of length %lu: %@", string.length, string);

    dispatch_async(self.ioQueue, ^{
        [self writeFrameBuffer:(const uint8_t *)[string UTF8String] length:[string lengthOfBytesUsingEncoding:NSUTF8StringEncoding] opcode:JFROpCodeTextFrame];
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
    
    dispatch_async(self.ioQueue, ^{
        [self writeFrameBuffer:(const uint8_t *)[data bytes] length:[data length] opcode:opcode];
    });
}

- (void)writeRawData:(NSData *)data {
    NSAssert(_status == JFRSocketControllerStatusOpen, @"Writing to unopened stream");
    JFRLog(self, @"Writing raw data of length %lu", data.length);
    
    dispatch_async(self.ioQueue, ^{
        [self writeBuffer:(const uint8_t *)[data bytes] length:[data length]];
    });
}

#pragma mark - Private

- (void)p_configureOutputStream {
    self.outputStream.delegate = self;
    
    CFWriteStreamSetDispatchQueue((CFWriteStreamRef)self.outputStream, self.ioQueue);
    
    if (self.sslEnabled) {
        [self.outputStream setProperty:NSStreamSocketSecurityLevelKey forKey:NSStreamSocketSecurityLevelNegotiatedSSL];
        
        if (self.allowSelfSignedSSLCertificates) {
            NSDictionary *settings = @{ (NSString *)kCFStreamSSLValidatesCertificateChain: @NO,
                                        (NSString *)kCFStreamSSLValidatesCertificateChain: [NSNull null] };
            
            CFWriteStreamSetProperty((CFWriteStreamRef)self.outputStream, kCFStreamPropertySSLSettings, (CFDictionaryRef)settings);
        }
    }
    
    if(self.voipEnabled) {
        [self.outputStream setProperty:NSStreamNetworkServiceType forKey:NSStreamNetworkServiceTypeVoIP];
    }
}

/** Wraps buffer in a web socket frame with opcode, and sends it along to the wire.
 * @returns The total bytes written, which may be more than `length` due to the web socket protocol frame.
 *      If this value is negative, an error occurred.
 */
-(size_t)writeFrameBuffer:(const uint8_t *)buffer length:(const NSUInteger)length opcode:(const JFROpCode)code
{
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierIO,
             @"%s Wrong queue", __PRETTY_FUNCTION__);
    
    uint64_t offset = 2; // how many bytes do we need to skip for the header
    
    uint8_t *frameBuffer = malloc(sizeof(uint8_t) * length + JFRMaxFrameSize);
    frameBuffer[0] = JFRFinMask | code;
    
    // Encode data length per frame specification
    if (length < 126) {
        frameBuffer[1] = length;
        
    } else if (length <= UINT16_MAX) {
        frameBuffer[1] = 126;
        *((uint16_t *)(frameBuffer + offset)) = CFSwapInt16HostToBig((uint16_t)length);
        offset += sizeof(uint16_t);
        
    } else {
        frameBuffer[1] = 127;
        *((uint64_t *)(frameBuffer + offset)) = CFSwapInt64HostToBig((uint64_t)length);
        offset += sizeof(uint64_t);
    }
    
    // Mask payload to ensure proxys cannot introspect payload
    BOOL isMask = YES;
    if(isMask) {
        frameBuffer[1] |= JFRMaskMask;
        uint8_t *mask_key = frameBuffer + offset;
        SecRandomCopyBytes(kSecRandomDefault, sizeof(uint32_t), mask_key);
        offset += sizeof(uint32_t);
        
        for(size_t l = offset, r = 0; r < length; r++, l++) {
            frameBuffer[l] = buffer[r] ^ mask_key[r % sizeof(uint32_t)];
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
- (ssize_t)writeBuffer:(const uint8_t *)buffer length:(const size_t)length {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierIO,
             @"%s Wrong queue", __PRETTY_FUNCTION__);
    NSParameterAssert(buffer);
    NSParameterAssert(length);
    
    size_t total = 0;
    while (self.outputStream && total < length) {
        NSInteger written = [self.outputStream write:buffer+total maxLength:length-total];
        if (written < 0) {
            JFRLog(self, @"UNHANDLED ERROR %ld %@", [self.outputStream streamStatus], [self.outputStream streamError]);
            //[self doWriteError];
            return written;
        } else {
            JFRLog(self, @"wrote %lu bytes", written);
            total += written;
        }
    }
    return total;
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierIO,
             @"%s Wrong queue", __PRETTY_FUNCTION__);
    
    switch (eventCode) {
            
        case NSStreamEventNone:
            JFRLog(self, @"%p write stream unknown event", stream);
            break;
            
        case NSStreamEventOpenCompleted:
            JFRLog(self, @"%p write stream open", stream);
            _status = JFRSocketControllerStatusOpening;
            break;
            
        case NSStreamEventHasBytesAvailable:
        {
            JFRLog(self, @"%p write stream has bytes available", stream);
            NSAssert(false, @"output stream should not be readable");
            break;
        }
        case NSStreamEventHasSpaceAvailable:
        {
            JFRLog(self, @"%p write stream has space", stream);
            if (_status == JFRSocketControllerStatusOpening) {
                _status = JFRSocketControllerStatusOpen;
                [self.delegate websocketControllerDidConnect:self];
            }
//                [self p_processAvailableBytes];
            break;
        }
        case NSStreamEventErrorOccurred:
            JFRLog(self, @"%p write stream error", stream);
            [self.delegate websocketControllerDidDisconnect:self error:[stream streamError]];
            break;

        case NSStreamEventEndEncountered:
        {
            JFRLog(self, @"%p write stream end encountered", stream);
            [self.delegate websocketControllerDidDisconnect:self
                                                      error:[[self class] errorWithDetail:@"Connection lost." code:JFRCloseCodeNormal]];
            break;
        }
        default:
            JFRLog(self, @"%p write stream – unknown event", stream);
            break;
    }
}

@end
