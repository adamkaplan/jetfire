//
//  JFRWebSocketReadController.m
//  SimpleTest
//
//  Created by Adam Kaplan on 4/20/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import "JFRWebSocketReadController.h"
#import "JFRLog.h"
#import <objc/runtime.h>

#import "NSData+JFRBinaryInspection.h"

//
static const void *const kJFRSocketReadControllerQueueIdentifierParsing = "JFRSocketReadControllerQueueIdentifierParsing";
// WebSocket HTTP Header Keys
static const CFStringRef kJFRHttpHeaderAcceptNameKey = CFSTR("Sec-WebSocket-Accept");

static const size_t kJFRReadBufferMax = 4096;

/** A wrapper object for tracking the state of a multi-frame response */
@interface JFRMultiFrameResponse : NSObject
@property (nonatomic) BOOL isFinished;
@property (nonatomic) JFROpCode opcode;
@property (nonatomic) BOOL isHeaderComplete;
@property (nonatomic) NSInteger bytesLeftInMessage;
@property (nonatomic) dispatch_data_t payloadData;
@property (nonatomic) NSInteger unicodeBytesToIgnore;
@property (nonatomic) NSUInteger fragmentCount;
@property (nonatomic) NSUInteger frameCount;
@end
@implementation JFRMultiFrameResponse @end

@interface JFRWebSocketReadController ()
/** Serial queue used for blocking I/O operations */
@property (nonatomic) dispatch_queue_t ioQueue;
/** Serial queue used for frame parsing and other input-related operations */
@property (nonatomic) dispatch_queue_t parsingQueue;
@property (nonatomic) NSMutableArray *messageStack;

- (void)stream:(CFReadStreamRef)stream handleEvent:(CFStreamEventType)eventCode;
@end


static void readStreamCallback(CFReadStreamRef stream, CFStreamEventType type, void *clientCallbackInfo) {
    @autoreleasepool {
        JFRWebSocketReadController *self = (__bridge JFRWebSocketReadController *)clientCallbackInfo; // should be retained as per configuration
        [self stream:stream handleEvent:type];
    }
}


@implementation JFRWebSocketReadController {
    // Unused header byte
    BOOL _hasHeaderByte;
    UInt8 _headerByte;
    // Frame fragments
    UInt64 _frameBytesRemaining;
    dispatch_data_t _frameFragment;
    //
}

@synthesize status = _status;

#pragma - Lifecycle

- (instancetype)initWithInputStream:(CFReadStreamRef)inputStream {
    
    if (CFReadStreamGetStatus(inputStream) != kCFStreamStatusNotOpen) {
        NSAssert(false, @"The provided inputStream must be un-opened.");
        @throw NSInternalInconsistencyException;
        return nil;
    }
    
    if (self = [super init]) {
        _messageStack = [NSMutableArray array];
        _inputStream = inputStream;
        _parsingQueue = dispatch_queue_create("com.vluxe.jetfire.parser.read", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_parsingQueue, kJFRSocketReadControllerQueueIdentifierKey, (void*)kJFRSocketReadControllerQueueIdentifierParsing, NULL);
        
        _ioQueue = dispatch_queue_create("com.vluxe.jetfire.socket.read", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_ioQueue, kJFRSocketReadControllerQueueIdentifierKey, (void*)kJFRSocketReadControllerQueueIdentifierIO, NULL);

        _status = JFRSocketControllerStatusNew;
    }
    return self;
}

- (void)dealloc {
    [self p_destroyInputStream];
}

#pragma - API

- (void)connect {
    if (self.status != JFRSocketControllerStatusNew) {
        NSAssert(false, @"Re-using socket controllers is not currently supported");
        @throw NSInternalInconsistencyException;
        return;
    }
    
    _status = JFRSocketControllerStatusOpening;
    
    // Setup the input stream
    [self p_configureInputStream];
    CFReadStreamOpen(self.inputStream);
}

- (void)disconnect {
//    _status = JFRSocketControllerStatusClosing;
    
//    __weak typeof(self) weakSelf = self;
//    dispatch_async(self.ioQueue, ^{
//        [weakSelf p_destroyOutputStream];
//    });
    
    //dispatch_suspend(self.ioQueue);
    
    _status = JFRSocketControllerStatusClosed;
}

- (void)initiateCloseForTimeInterval:(NSTimeInterval)interval {
    if (_status == JFRSocketControllerStatusClosingHandshakeInitiated
        || _status == JFRSocketControllerStatusClosingHandshakeComplete
        || _status == JFRSocketControllerStatusClosed) {
        return;
    }
    
    JFRLog(JFRInfo, @"Initiating hard close after %0.2fs", interval);

    _status = JFRSocketControllerStatusClosingHandshakeInitiated;
    
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), self.ioQueue, ^{
        JFRLog(JFRInfo, @"Hard close timeout expired after %0.2fs", interval);
        [weakSelf disconnect];
    });
}

#pragma mark - Private

- (void)p_configureInputStream {
    CFStreamClientContext context = {
        .version = 0,
        .info = (__bridge void *)(self),
        .retain = (void*(*)(void*))CFRetain,
        .release = (void(*)(void*))CFRelease,
        .copyDescription = NULL
    };
    
    CFReadStreamSetClient(self.inputStream, (kCFStreamEventOpenCompleted   | kCFStreamEventHasBytesAvailable
                                             | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered),
                          readStreamCallback, &context);
    
    CFReadStreamSetDispatchQueue(self.inputStream, self.ioQueue);
    
    if (self.sslEnabled) {
        CFReadStreamSetProperty(self.inputStream, kCFStreamPropertySocketSecurityLevel, kCFStreamSocketSecurityLevelNegotiatedSSL);
        
        if (self.allowSelfSignedSSLCertificates) {
            NSDictionary *settings = @{ (NSString *)kCFStreamSSLValidatesCertificateChain: @NO,
                                        (NSString *)kCFStreamSSLPeerName: [NSNull null] };
            
            CFReadStreamSetProperty(self.inputStream, kCFStreamPropertySSLSettings, (CFDictionaryRef)settings);
        }
    }
    
    if(self.voipEnabled) {
        CFReadStreamSetProperty(self.inputStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
    }
}

/** Closes the connection, removes the delegate to prevent further callbacks, de-registers from the
 * runloop (queue) and releases the work queue.
 */
- (void)p_destroyInputStream {
    _status = JFRSocketControllerStatusClosed;
    
    CFReadStreamRef stream = self.inputStream;
    if (stream) {
        CFRetain(stream); // ensure that the write stream will not disappear on us
        
        CFReadStreamSetDispatchQueue(stream, NULL);
        CFReadStreamSetClient(stream, kCFStreamEventNone, NULL, NULL);
        //CFReadStreamClose(stream);
        
        CFRelease(stream);
        _inputStream = NULL;
    }
}

#pragma mark - Input Processing

/**
 * There are some really crazy subtle edge cases when doing app-level framing of network bytes:
 * This buffer can represent any one of the following:
 *
 * # Existing Response? Unused Header Byte?     Fragment?   Meaning
 *----------------------------------------------------------------------------------------------
 * 1        YES                 NO                  NO      Buffer contains new frame, which is either next continuation frame
 *                                                              for `response`, or a control frame.
 *
 * 2        YES                 NO                  YES     Buffer contains contains more bytes for an unfinished frame, which is
 *                                                              either next continuation frame for `response`, or a control frame.
 *
 * 3        YES                 YES                 NO      Buffer is continuation of an incomplete WS frame header, which may be
 *                                                              either continuation frame for response or a new control frame.
 *
 * 4        YES                 YES                 YES     Error - Cannot have fragment with unused header byte.
 *
 * 5        NO                  YES                 YES     Error - Cannot have fragment with unused header byte.
 *
 * 6        NO                  YES                 NO      Buffer is continuation of an incomplete WS frame header.
 *                                                              (if OS socket buffer happened to contain only first header byte)
 *
 * 7        NO                  NO                  YES     Buffer contains more bytes for an unfinished frame.
 *
 * 8        NO                  NO                  NO      Buffer is the beginning of a new WS frame.
 */

/** This method deals with efficiently slurping bytes off of the internal input stream. It handles
 * only low level connection errors (i.e. reading on a closed socket)  */
- (void)p_processAvailableBytes:(CFReadStreamRef)stream {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierIO, @"%s Wrong queue", __PRETTY_FUNCTION__);
    
    JFRLog(JFRDebug, @"Reading from stream");
    
    UInt8 *buffer = NULL;
    CFIndex readBytes = 0;
    dispatch_data_t collector = dispatch_data_empty;
    
    buffer = malloc(sizeof(UInt8) * kJFRReadBufferMax);
    readBytes = CFReadStreamRead(stream, buffer, kJFRReadBufferMax);
    
    if (readBytes < 0) {
        JFRLog(JFRError, @"Input stream read error (code %ld) %@",
               CFReadStreamGetStatus(stream), CFBridgingRelease(CFReadStreamCopyError(stream)));
        free(buffer);
        // any already buffered data in `collector` still must be processed.
        // to be verified: the error here is reported to the delegate and handled there.
        
    } else if (readBytes == 0) {
        JFRLog(JFRWarn, @"No data returned from input stream. Connection is intact.");
        free(buffer);
        
    } else {
        JFRLog(JFRDebug, @"Read %ld bytes", readBytes);
        collector = dispatch_data_create(buffer, readBytes, self.parsingQueue, DISPATCH_DATA_DESTRUCTOR_FREE);
    }
    
    if (collector != dispatch_data_empty) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(self.parsingQueue, ^{
            [weakSelf p_processRawBuffers:collector];
        });
    }
}

/** This method traverses the collected sparse data regions, calling additional processing methods on each.
 * It collects any "leftover" frame fragments and persists them for the next call
 */
- (void)p_processRawBuffers:(dispatch_data_t)data {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierParsing, @"%s Wrong queue", __PRETTY_FUNCTION__);
    //NSParameterAssert(buffer);
    NSParameterAssert(data);
    
    if (!data || dispatch_data_get_size(data) == 0) {
        return;
    }
    
    if (self.status >= JFRSocketControllerStatusClosingHandshakeInitiated) {
        // Once close begins, ignore futher data per spec
        JFRLog(JFRWarn, @"Dropping frames because close handshake has begun");
        return;
    }

    
    
    // HANDLE FRAGMENT CASE 2,4,5,7 – If there is a fragment, prepend it to the new data first.
    size_t length = dispatch_data_get_size(data);
    if (_frameBytesRemaining) {
        if (_frameFragment) {
            dispatch_data_t subrange;
            
            if (_frameBytesRemaining == length) {
                subrange = data;
                _frameBytesRemaining = 0;
            }
            else if (_frameBytesRemaining > length) {
                subrange = dispatch_data_create_subrange(data, 0, length - _frameBytesRemaining);
                _frameBytesRemaining -= length;
            }
            else {
                subrange = dispatch_data_create_subrange(data, 0, _frameBytesRemaining);
                _frameBytesRemaining = 0;
            }

            JFRLog(JFRDebug, @"Fragment size is %ld, new data size is %ld", dispatch_data_get_size(_frameFragment), length);
            data = dispatch_data_create_concat(_frameFragment, subrange);
            _frameFragment = NULL;
        }
    }
    
    dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
        
        ssize_t bytesUsed = [self p_processRawRegion:region buffer:(const uint8_t *)buffer length:size];

        if (bytesUsed == 0) { // unable to find a complete frame.
            _frameFragment = data;
            return NO;
            
        } else if (bytesUsed < 0) { // something terrible happened
            //NSAssert(false, @"Fatal error while parsing data region (-1)");
            JFRLog(JFRError, @"Fatal error while parsing data region (-1)");
            [self p_destroyInputStream];
            NSError *error = [[self class] errorWithDetail:@"Unknown Read Error" code:JFRCloseCodeProtocolError];
            [self.delegate websocketController:self shouldCloseWithError:error];
            return NO; // error
            
        } else if (bytesUsed > size) { // parser ate more bytes than it was given
            NSAssert(false, @"Fatal error while parsing data region");
            JFRLog(JFRError, @"Fatal error while parsing data region");
            return NO; // error
            
        } else if (bytesUsed < size) { // there was a fragment, save it
            _frameFragment = dispatch_data_create_subrange(region, bytesUsed, size - bytesUsed);
            return NO;
            
        }
        
        // Return YES to continue processing ONLY if all bytes in the current region were used (bytesUsed == size).
        return YES;
    });
}

/** This method accepts a single raw buffer and extracts complete web socket frames from it, returning
 * the number of bytes actually used. The bytes used will be less than length if the buffer contains an
 * incomplete frame. It will also recognize if the HTTP handshake has not yet occured and look for that
 * packet first, if needed.
 * @returns the number of bytes from buffer that were actually used, or -1 on any error.
 */
- (ssize_t)p_processRawRegion:(dispatch_data_t)region buffer:(const uint8_t *)buffer length:(const size_t)length {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierParsing, @"%s Wrong queue", __PRETTY_FUNCTION__);
    NSParameterAssert(buffer);
    NSParameterAssert(length);
    if (length == 0 || buffer == NULL) {
        return -1;
    }
    
    ssize_t remainingLength = length;
    
    // Process the HTTP handshake packet if the websocket is not yet negotiated
    if (self.status == JFRSocketControllerStatusOpening) {
        ssize_t usedLength = [self p_processHttpHandshake:buffer length:remainingLength];
        if (usedLength >= 0) {
            _status = JFRSocketControllerStatusOpen;
            
        } else { // Incomplete or invalid HTTP header
            return -1;
        }
        
        // splice-out the HTTP packet.
        size_t nextIndex = usedLength + 1;
        if (remainingLength - (ssize_t)nextIndex < 0) {
            NSAssert(false, @"HTTP packet processor swallowed too many bytes");
            return -1;
        }
        buffer += nextIndex;
        remainingLength -= nextIndex;
        JFRLog(JFRDebug, @"Read stream had %lu bytes remaining after HTTP handshake)", remainingLength);
    }
    
    // Process any websocket frames received
    size_t regionOffset = 0;
    while (remainingLength > 0) { // cannot process a frame with < 2 bytes (hard minimum for header)
        JFRLog(JFRBinary, @"About to process frame:\n%@",
               [[NSData dataWithBytesNoCopy:(void *)buffer length:remainingLength freeWhenDone:NO] binaryString]);
        
        ssize_t usedLength = [self p_processWebSocketFrameRegion:region offset:regionOffset buffer:buffer length:remainingLength];
        if (usedLength < 0) {
            return -1;
        }
        else if (usedLength == 0) {
            break; // remaining length will be saved for later.
        }
        
        regionOffset += usedLength;
        buffer += usedLength;
        remainingLength -= usedLength;
    }
    
    // Stream errors must be processed after any buffered data to ensure that any server-sent close
    // frames are properly processed. If the server DID send a close code, the work enqueued here
    // won't need to do anything else.
//    if (connectionClosed) {
//        dispatch_async(self.ioQueue, ^{
//            [self disconnectStreamDeferredWithReason:@"Read stream closed, unexpected." code:JFRCloseCodeNoStatusReceived];
//        });
//    }
    
    if (remainingLength < 0) {
        return -1;
    }
    return length - remainingLength;
}

/** This method is the heart of the web socket reader. It expects a raw byte buffer containing 0 or more
 * web socket frames. The method will parse out and validate in turn, all of the frames it can find.
 * Valid complete websocket messages and errors both trigger side effects via delegate notifications.
 * @param region the data region to which `buffer` belongs
 * @param offset the offset to `buffer` within `region`
 * @param buffer the current data buffer to process
 * @param length the length  of buffer to process
 * @returns The number of bytes written. If this value is negative, an error occurred
 */
- (ssize_t)p_processWebSocketFrameRegion:(dispatch_data_t)region offset:(const size_t)regionOffset buffer:(const uint8_t *)buffer length:(const size_t)length {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierParsing, @"%s Wrong queue", __PRETTY_FUNCTION__);
    NSParameterAssert(buffer);
    NSParameterAssert(length);
    if (length == 0) {
        return 0;
    }
    
    if (self.status >= JFRSocketControllerStatusClosingHandshakeInitiated) {
        // Once close begins, ignore futher data per spec
        JFRLog(JFRWarn, @"Dropping frames because close handshake has begun");
        return -1;
    }
    
    /* RFC-6455 Framing Specification
     0                   1                   2                   3
     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
     +-+-+-+-+-------+-+-------------+-------------------------------+
     |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
     |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
     |N|V|V|V|       |S|             |   (if payload len==126/127)   |
     | |1|2|3|       |K|             |                               |
     +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
     |     Extended payload length continued, if payload len == 127  |
     + - - - - - - - - - - - - - - - +-------------------------------+
     |                               |Masking-key, if MASK set to 1  |
     +-------------------------------+-------------------------------+
     | Masking-key (continued)       |          Payload Data         |
     +-------------------------------- - - - - - - - - - - - - - - - +
     :                     Payload Data continued ...                :
     + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
     |                     Payload Data continued ...                |
     +---------------------------------------------------------------+
     */
    
    JFRMultiFrameResponse *response;
    if (_messageStack.count) {
        response = [_messageStack lastObject];
    }
    
    
    // Check if a multi-frame response is in progress.
    if (response && response.bytesLeftInMessage > 0) {
        dispatch_data_t additionalData;
        if (response.bytesLeftInMessage >= length) {
            additionalData = dispatch_data_create_subrange(region, regionOffset, length);
            response.bytesLeftInMessage -= length;
        }
        else {
            additionalData = dispatch_data_create_subrange(region, regionOffset, response.bytesLeftInMessage);
            response.bytesLeftInMessage = 0;
        }
        
        // Validate unicode fragment
        if (response.opcode == JFROpCodeTextFrame) {
            ssize_t result = [self p_validateUnicode:additionalData continuationBytes:response.unicodeBytesToIgnore];
            if (result < 0) {
                _status = JFRSocketControllerStatusClosingHandshakeComplete;
                
                [_messageStack removeAllObjects];
                
                NSError *error = [[self class] errorWithDetail:@"Invalid unicode in string encoding" code:JFRCloseCodeEncoding];
                [self.delegate websocketController:self shouldFailWithError:error];
            } else {
                response.unicodeBytesToIgnore = result;
            }
        }
        
        response.payloadData = dispatch_data_create_concat(response.payloadData, additionalData);
        
        JFRLog(JFRDebug, @"Continuing existing response. Payload is now %lu. Expecting %lu more bytes.",
               dispatch_data_get_size(response.payloadData), response.bytesLeftInMessage);
        NSAssert(response.bytesLeftInMessage >= 0, @"Bytes left in message cannot be negative (%ld)", response.bytesLeftInMessage);
        
        if (response.bytesLeftInMessage <= 0 && response.isFinished) {
            const void *frameBuffer = NULL;
            size_t frameSize = 0;
            dispatch_data_t tempData = dispatch_data_create_map(response.payloadData, &frameBuffer, &frameSize);
            [self p_processWebSocketMessage:(uint8_t *)frameBuffer length:frameSize opcode:response.opcode];
            tempData = nil;
            
            [_messageStack removeLastObject];
        }
        
        return dispatch_data_get_size(additionalData);
    }
    
    // Fin - Indicates that this is the final fragment in a message. The first fragment MAY also be the final fragment.
    BOOL isFin = NO;
    // rsv1,2,3 - MUST be 0 unless an extension is negotiated that defines meanings for non-zero values.
    UInt8 rsvBits = 0;
    // Opcode - Defines the interpretation of the "Payload data".  If an unknown opcode is received. See opcodes constants.
    JFROpCode receivedOpcode = 0;

    BOOL isControlFrame = NO;
    size_t offset = 0;
    
    // HANDLE CASE 8 - New start or continuation frame with at least 2 header bytes.
    // HANDLE CASE 1 - Data is either a new continuation frame for response, new control frame.
    if (response && !response.isHeaderComplete) {
        isFin = response.isFinished;
        receivedOpcode = response.opcode & JFROpCodeMask;
        
        isControlFrame = JFROpCodeIsControl(receivedOpcode);
    }
    else {
        isFin = buffer[0] & JFRFinMask;
        rsvBits = buffer[0] & JFRRSVMask;
        receivedOpcode = buffer[0] & JFROpCodeMask;
        
        isControlFrame = JFROpCodeIsControl(receivedOpcode);
        offset++;
        
        // Handle error case - rsv negotiation is currently not supported by this project.
        if(rsvBits) {
            [_messageStack removeAllObjects];
            
            NSError *error = [[self class] errorWithDetail:@"rsv data is not currently supported" code:JFRCloseCodeProtocolError];
            [self.delegate websocketController:self shouldCloseWithError:error];
            return -1;
        }
        
        // Handle error case - unrecognized opcode (either invalid or new/unrecognized)
        if(!JFROpCodeIsValid(receivedOpcode)) {
            [_messageStack removeAllObjects];
            
            NSError *error = [[self class] errorWithDetail:[NSString stringWithFormat:@"unknown opcode: 0x%hhx", receivedOpcode]
                                                      code:JFRCloseCodeProtocolError];
            [self.delegate websocketController:self shouldCloseWithError:error];
            return -1;
        }
        
        // Handle error case - continuation frame without previous non-continuation frame
        if (!response && receivedOpcode == JFROpCodeContinueFrame) {
            [_messageStack removeAllObjects];
            
            NSError *error = [[self class] errorWithDetail:@"continue frame before non-continue frame"
                                                      code:JFRCloseCodeProtocolError];
            [self.delegate websocketController:self shouldCloseWithError:error];
            return -1;
        }
        
        // Handle error case - expected continuation frame, but received non-continuation frame.
        // Note that it is OK to receive a control frame in-between continuation frames (and they cannot be fragmented)
        if (!isControlFrame && response && receivedOpcode != JFROpCodeContinueFrame) {
            [_messageStack removeAllObjects];
            
            NSString *reason = [NSString stringWithFormat:@"expected either continuation or control frame, "
                                @"received frame with opcode 0x%hhx", receivedOpcode];
            NSError *error = [[self class] errorWithDetail:reason code:JFRCloseCodeProtocolError];
            [self.delegate websocketController:self shouldCloseWithError:error];
            return -1;
        }
        // A control frame which occurs in-between continuation frames must be processed immediately.
        else if (isControlFrame && response) {
            JFRLog(JFRInfo, @"Received control frame between continuation frames");
            response = nil;
        }
        
        // Handle error case - control frames must not be fragmented
        if (isControlFrame && !isFin) {
            [_messageStack removeAllObjects];
            
            NSError *error = [[self class] errorWithDetail:@"Control frame must not be fragmented" code:JFRCloseCodeProtocolError];
            [self.delegate websocketController:self shouldCloseWithError:error];
            return -1;
        }
        
        if (length == 1) {
            if (isControlFrame) { // control frame cannot be part of a fragment
                JFRMultiFrameResponse *thisResponse = [JFRMultiFrameResponse new];
                thisResponse.isFinished = isFin;
                thisResponse.opcode = receivedOpcode;
                thisResponse.isHeaderComplete = NO;
                [_messageStack addObject:thisResponse];
            }
            else {
                response.isFinished = isFin;
                response.opcode = receivedOpcode;
                response.isHeaderComplete = NO;
            }
            
            return length;
        }
    }

    //
    // Now process the second byte! (which may be the first byte if only first byte came last time)
    //
    
    // Mask - Defines whether the "Payload data" is masked. If true, masking-key is present.
    const BOOL isMasked = JFRMaskMask & buffer[offset];
    // Payloan Length - The length of the "Payload data", in bytes: if 0-125, that is the payload length.
    // If 126, the following 2 bytes interpreted as a 16-bit unsigned integer are the payload length.
    // If 127, the following 8 bytes interpreted as a 64-bit unsigned integer are the payload length.
    const uint8_t payloadLen = JFRPayloadLenMask & buffer[offset];
    
    ++offset;
    
    // Handle error case - masked data & rsv are currently not supported by this project...
    if(isMasked) {
        [_messageStack removeAllObjects];
        
        NSError *error = [[self class] errorWithDetail:@"masked server packets violate framing specification." code:JFRCloseCodeProtocolError];
        [self.delegate websocketController:self shouldCloseWithError:error];
        return -1;
    }
    
    // Handle error case - All control frames MUST have a payload length of 125 bytes or less
    if(isControlFrame && payloadLen > 125) {
        [_messageStack removeAllObjects];
        
        NSString *errorReason = @"All control frames MUST have a payload length of 125 bytes or less.";
        NSError *error = [[self class] errorWithDetail:errorReason code:JFRCloseCodeProtocolError];
        [self.delegate websocketController:self shouldCloseWithError:error];
        return -1;
    }
    
    // Handle Opcode - Server disconnected
    if(receivedOpcode == JFROpCodeConnectionClose) {
        NSInteger codeOffset = sizeof(uint16_t); // skip the original 2-byte web socket header
        NSString *closeReason;
        
        // Determine appropriate server close code
        uint16_t code = JFRCloseCodeNoStatusReceived; // optional status code not received
        if(payloadLen > 1) {
             code = CFSwapInt16BigToHost(*(uint16_t *)(buffer + codeOffset));
             if(code < 1000 || (code > 1003 && code < 1007) || (code > 1011 && code < 3000)) {
                 code = JFRCloseCodeProtocolError;
             }
             codeOffset += sizeof(uint16_t);
            
            // TODO: handle close code TCP fragmentation.
            
             // Determine appropriate server close reason, if provided
             NSInteger reasonLength = payloadLen - sizeof(uint16_t); // account for the 2-byte reason code
             if(reasonLength > 0) {
                 closeReason = [[NSString alloc] initWithBytes:(void *)(buffer + codeOffset)
                                                        length:reasonLength
                                                      encoding:NSUTF8StringEncoding];
                 if (!closeReason) {
                     code = JFRCloseCodeEncoding; // close reason was invalid string
                 }
             }
         }
        
        if (response) { [_messageStack removeLastObject]; }
        
        // Server initiated the closing handshake or has accepted ours. Either way, we're done.
        //_status = JFRSocketControllerStatusClosingHandshakeComplete;
        NSError *error = [[self class] errorWithDetail:closeReason code:code];
        [self.delegate websocketController:self shouldCloseWithError:error];
        return payloadLen + sizeof(uint16_t); // add back in the original 2-byte web socket frame header
    }
    
    // Compute actual payload length: can be either 8-bit, 16-bit ot 64-bit.
    NSInteger framePayloadLength = payloadLen;  // 8-bit
    if(payloadLen == 127) {                     // 64-bit
        framePayloadLength = CFSwapInt64BigToHost(*(UInt64 *)(buffer+offset));
        offset += sizeof(UInt64);
        
    } else if(payloadLen == 126) {              // 16-bit
        framePayloadLength = CFSwapInt16BigToHost(*(UInt16 *)(buffer+offset) );
        offset += sizeof(UInt16);
    }

    // Detect incomplete frame OR detect additional frames in buffer
    // A) frame payload length = remaining buffer length :: Frame is entirely contained within buffer & additional frames are NOT present
    // B) frame payload length < remaining buffer length :: Frame is entirely contained within buffer & additional frame are present
    // C) frame payload length > remaining buffer length :: Frame is NOT entirely contained within buffer & additional bytes are needed
    
    ssize_t remainingBufferLength = length - offset; // remaining bytes in the buffer
    ssize_t remainingLengthAfterFrame = remainingBufferLength - framePayloadLength; // portion of remaining bytes which are beyond this frame
    BOOL frameIsIncomplete = remainingLengthAfterFrame < 0; // the buffer does not contain the data to satisfy this frame.
    
    // Create response model if one is needed.
    if(!response && (frameIsIncomplete || !isFin)) { // C
        response = [JFRMultiFrameResponse new];
        response.opcode = receivedOpcode;
        
        // The current data buffer will be collected below – after checking to ensure that this is not a pong frame
        [_messageStack addObject:response];
    }
    
    // Handle multi-frame or multi-part messages with payload
    // If message is incomplete, save a copy of the data frame payload and shove it into the multi-frame response object.
    if (response) {
        // First, update the response state to account for the new frame / additional data
        response.isFinished = isFin;
        response.isHeaderComplete = YES;
        
        if (frameIsIncomplete) {
            response.bytesLeftInMessage = -remainingLengthAfterFrame;
            response.fragmentCount++;
        } else {
            response.frameCount++;
        }
        
        // Next concatenate any new data to the payload
        size_t additionalPayloadLength = framePayloadLength;
        if (additionalPayloadLength > length - offset) {
            additionalPayloadLength = length - offset;
        }
        
        dispatch_data_t additionalPayloadData = dispatch_data_create(buffer + offset, additionalPayloadLength, self.parsingQueue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        if (response.payloadData) {
            response.payloadData = dispatch_data_create_concat(response.payloadData, additionalPayloadData);
        } else {
            response.payloadData = additionalPayloadData;
        }
        
        if (response.opcode == JFROpCodeTextFrame) {
            ssize_t result = [self p_validateUnicode:additionalPayloadData continuationBytes:response.unicodeBytesToIgnore];
            if (result < 0) {
                _status = JFRSocketControllerStatusClosingHandshakeComplete;
                
                [_messageStack removeAllObjects];
                
                NSError *error = [[self class] errorWithDetail:@"Invalid unicode in string encoding" code:JFRCloseCodeEncoding];
                [self.delegate websocketController:self shouldFailWithError:error];
            } else {
                response.unicodeBytesToIgnore = result;
            }
        }
    
        // Second, if the multi-frame fragmented message is finished and there is no missing data
        if (response.bytesLeftInMessage == 0 && isFin) {
            if (_messageStack.count) { [_messageStack removeLastObject]; }

            const void *frameBuffer = NULL;
            size_t frameSize = 0;
            dispatch_data_t tempData = dispatch_data_create_map(response.payloadData, &frameBuffer, &frameSize);
            [self p_processWebSocketMessage:(uint8_t *)frameBuffer length:frameSize opcode:response.opcode];
            tempData = nil;
        }
    } else if (isFin) { // Single-frame message finished
        [self p_processWebSocketMessage:buffer+offset length:framePayloadLength opcode:receivedOpcode];
        if (response && _messageStack.count) { [_messageStack removeLastObject]; }
    }
    
    if (remainingLengthAfterFrame > 0) {
        return length - remainingLengthAfterFrame;
    } else {
        return length; // every byte has been consumed (and more is needed!)
    }
}

/** Quick unicode streaming validator for dispatch_data.
 * @param data the data region to validate
 * @param continuationBytes number of continuation bytes to expect at the start of the data region
 * @returns a negative number if the region does not contain valid unicode. A positive number between
 *          0 and 3 representing any missing unicode sequence bytes (i.e. if the last character is
 *          incomplete).
 */
- (ssize_t)p_validateUnicode:(dispatch_data_t)data continuationBytes:(size_t)continuationBytes {
    
    __block ssize_t bytesToIgnore = continuationBytes;
    
    dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
        
        const size_t lastIndex = size - 1;
        
        size_t remainingSequenceBytes = bytesToIgnore;

        size_t currentIndex = 0;
        while (currentIndex <= lastIndex) {
            const uint8_t byte = ((const uint8_t *)buffer)[currentIndex];
            
            if (remainingSequenceBytes == 3) {      // First continuation byte in Four byte sequence cannot be > 0x80
                if ((byte & 0xF0) != 0x80) {
                    bytesToIgnore = -1;
                    return NO;
                }
                remainingSequenceBytes--;
            }
            else if (remainingSequenceBytes > 0) {
                if ((byte & 0xC0) != 0x80) {        // Continuation byte    10xxxxxx
                    bytesToIgnore = -1;
                    return NO;
                }
                remainingSequenceBytes--;
            }
            else {
                if ((byte & 0x80) == 0x0) {         // Once byte sequence   01xxxxxx
                    remainingSequenceBytes = 0;
                    
                } else if ((byte & 0xE0) == 0xC0) { // Two byte sequence    110xxxxx
                    remainingSequenceBytes = 1;
                    
                } else if ((byte & 0xF0) == 0xE0) { // Three byte sequence  1110xxxx
                    remainingSequenceBytes = 2;
                    
                // ((byte & 0xF8) == 0xF0)          // Four byte sequence   11110xxx
                } else if (byte == 0xF4) {          // Must be 11110100 to stay under UTF-8 upper limit of 0x10FFFF
                    remainingSequenceBytes = 3;
                    
                }
                else {
                    bytesToIgnore = -1;
                    return NO;
                }
            }
            
            currentIndex++;
        }
        
        bytesToIgnore = remainingSequenceBytes;
        return YES;
    });
    
    return bytesToIgnore;
}

- (void)p_processWebSocketMessage:(const uint8_t *)buffer length:(size_t)length opcode:(uint8_t)opcode {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierParsing,
             @"%s Wrong queue", __PRETTY_FUNCTION__);
    NSAssert(buffer != NULL || length == 0, @"Empty buffer, but non-empty buffer length specified");
    if (buffer == NULL && length != 0) {
        return;
    }
    
    switch (opcode) {
            
        case JFROpCodePing:
        {
            NSData *data = [[NSData alloc] initWithBytes:buffer length:length];
            [self.delegate websocketController:self didReceivePing:data];
            break;
        }
        case JFROpCodeTextFrame:
        {
            NSString *str = [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
            if(!str) {
                NSError *error = [[self class] errorWithDetail:@"Failed to decode text message" code:JFRCloseCodeEncoding];
                [self.delegate websocketController:self shouldCloseWithError:error];
                return;
            }
            [self.delegate websocketController:self didReceiveMessage:str];
            break;
        }
        case JFROpCodeBinaryFrame:
        {
            NSData *data = [[NSData alloc] initWithBytes:buffer length:length];
            [self.delegate websocketController:self didReceiveData:data];
            break;
        }
        case JFROpCodePong:
        {
            JFRLog(JFRDebug, @"Got pong frame: %@",
                   [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding]);
        }
    }
}

#pragma mark - HTTP Handshake Processing

/** This method attempts to locate and extract an HTTP packet from the start of a raw buffer.
 * @param remainingOffset On `true` return, contains the next offset in buffer after the HTTP packet.
 *      On `false` return, contains 0, meanins the HTTP packet was incomplete.
 * @returns The number of bytes that were used to construct and validate the HTTP packet. A negative
 *      number indicates packet validation failure. A positive number indicates additional unprocessed
 *      bytes remain beyond the HTTP packet.
 */
- (ssize_t)p_processHttpHandshake:(const uint8_t *)buffer length:(size_t)length {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierParsing, @"%s Wrong queue", __PRETTY_FUNCTION__);
    NSParameterAssert(buffer);
    NSParameterAssert(length);
    
    static const char CRLFBytes[] = {'\r', '\n', '\r', '\n'};
    
    // Find the double newline that marks the end of HTTP packet. The newlines might contained entirely
    // within the current buffer or split between multiple (future) buffers.
    // NOTE: HTTP handshake that spans OS read buffers are not supported.
    size_t packetLength = 0;
    int CRLFIndex = 0;
    for(int i = 0; i < length; i++) {
        if(((char *)buffer)[i] == CRLFBytes[CRLFIndex]) {
            CRLFIndex++;
            if(CRLFIndex == 3) {
                packetLength = i + 1; // woot!
            }
        } else if(CRLFIndex != 0) {
            CRLFIndex = 0;
        }
    }
    
    if (packetLength == 0) {
        JFRLog(JFRError, @"Unable to find end of HTTP packet.");
        return -1;
    }
    
    // Split the data regions into the HTTP packet data and the remaining raw data.
    BOOL isValid = [self p_validateHttpHandshake:buffer length:packetLength];
    if (!isValid) {
        JFRLog(JFRError, @"HTTP upgrade packet failed verification");
        return -1;
    }
    
    JFRLog(JFRInfo, @"HTTP upgrade packet verified");
    [self.delegate websocketControllerDidConnect:self];
    return packetLength;
    
    /* Debugging – Print HTTP and remaining data
     {
     void *b;
     size_t l = 0;
     dispatch_data_t t = dispatch_data_create_map(data, (const void **)&b, &l);
     NSData *dt = [NSData dataWithBytesNoCopy:b length:l freeWhenDone:NO];
     NSString *str = [[NSString alloc] initWithData:dt encoding:NSUTF8StringEncoding];
     JFRLog(JFRBinary, @"HTTP DATA:\n%@", str);
     t = nil;
     }
     {
     void *b;
     size_t l = 0;
     dispatch_data_t t = dispatch_data_create_map(*remainingData, (const void **)&b, &l);
     NSData *dt = [NSData dataWithBytesNoCopy:b length:l freeWhenDone:NO];
     JFRLog(JFRBinary, @"REM DATA:\n%@", [dt binaryString]);
     if (t) t = nil; // arc release
     }*/
}

/** This method expects a raw byte buffer that entirely contains a single HTTP packet.
 * @returns True if the HTTP packet represented a valid WebSocket protocol HTTP upgrade.
 */
- (BOOL)p_validateHttpHandshake:(const uint8_t *)buffer length:(size_t)length {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierParsing, @"%s Wrong queue", __PRETTY_FUNCTION__);
    NSParameterAssert(buffer);
    NSParameterAssert(length);
    
    CFHTTPMessageRef response = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, NO);
    CFHTTPMessageAppendBytes(response, buffer, length);
    
    BOOL valid = NO;
    if(CFHTTPMessageGetResponseStatusCode(response) == 101) {
        CFStringRef acceptKey = CFHTTPMessageCopyHeaderFieldValue(response, kJFRHttpHeaderAcceptNameKey);
        
        valid = CFStringGetLength(acceptKey) > 0;
        
        CFRelease(acceptKey);
    }
    CFRelease(response);
    
    return valid;
}

#pragma mark - NSStreamDelegate

//- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode {
- (void)stream:(CFReadStreamRef)stream handleEvent:(CFStreamEventType)eventCode {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierIO,
             @"%s Wrong queue", __PRETTY_FUNCTION__);
    
    switch (eventCode) {
            
        case kCFStreamEventOpenCompleted:
        {
            JFRLog(JFRInfo, @"%p read stream open", stream);
            
            [self.delegate websocketControllerDidConnect:self];
            break;
        }   
        case kCFStreamEventHasBytesAvailable:
        {
            JFRLog(JFRInfo, @"%p read stream has bytes available", stream);
            
            [self p_processAvailableBytes:stream];
            break;
        }
        case kCFStreamEventErrorOccurred:
        {
            NSError *error = CFBridgingRelease(CFReadStreamCopyError(self.inputStream));
            JFRLog(JFRError, @"%p read stream error: %@", stream, error);
            
            [self p_destroyInputStream];
            [self.delegate websocketController:self shouldCloseWithError:error];
            break;
        }
        case kCFStreamEventEndEncountered:
        {
            JFRLog(JFRError, @"%p read stream end encountered", stream);
            NSError *error = [[self class] errorWithDetail:@"Connection lost." code:JFRCloseCodeNormal];

            [self p_destroyInputStream];
            [self.delegate websocketController:self shouldCloseWithError:error];
            break;
        }
        default: {
            JFRLog(JFRWarn, @"%p read stream – unknown event", stream);
            break;
        }
    }
}

@end
