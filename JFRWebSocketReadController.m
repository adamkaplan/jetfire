//
//  JFRWebSocketReadController.m
//  SimpleTest
//
//  Created by Adam Kaplan on 4/20/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import "JFRWebSocketReadController.h"
#import "JFRLog.h"

#import "NSData+JFRBinaryInspection.h"

// Dispatch Queue Property Keys
static const void *const kJFRSocketReadControllerQueueFragmentKey   = "JFRSocketReadControllerQueueFragmentBufferKey";
static const void *const kJFRSocketReadControllerQueueReponseKey    = "JFRSocketReadControllerQueueCurrentReponseKey";
//
static const void *const kJFRSocketReadControllerQueueIdentifierParsing = "JFRSocketReadControllerQueueIdentifierParsing";
// WebSocket HTTP Header Keys
static const CFStringRef kJFRHttpHeaderAcceptNameKey                = CFSTR("Sec-WebSocket-Accept");

static const size_t kJFRReadBufferMax = 4096;

// A dispatch_destructor_t function which releases a retainable type via ARC.
static void arcDestructorFunction(void *ptr) {
    id obj = (__bridge_transfer id)ptr;
    do { obj = nil; } while (obj); // gets rid of "unused" warnings without any jumps or branch prediction failures.
}

/** A wrapper object for tracking the state of a multi-frame response */
@interface JFRMultiFrameResponse : NSObject
@property (nonatomic) BOOL isFinished;
@property (nonatomic) JFROpCode opcode;
@property (nonatomic) NSInteger bytesLeftInMessage;
@property (nonatomic) dispatch_data_t payloadData;
@property (nonatomic) NSUInteger fragmentCount;
@property (nonatomic) NSUInteger frameCount;
@end
@implementation JFRMultiFrameResponse @end

@interface JFRWebSocketReadController () <NSStreamDelegate>
/** Serial queue used for blocking I/O operations */
@property (nonatomic) dispatch_queue_t ioQueue;
/** Serial queue used for frame parsing and other input-related operations */
@property (nonatomic) dispatch_queue_t parsingQueue;
/** While this value is true the delegate method will ignore NSStreamEventHasBytesAvailable. This is
 * helpful because NSStream will send that signal once each time we read, even if we read in a loop.
 */
//@property (nonatomic) BOOL ignoreStreamHasBytesAvailable;
@end

@implementation JFRWebSocketReadController

@synthesize status = _status;

#pragma - Lifecycle

- (instancetype)initWithInputStream:(NSInputStream *)inputStream {
    
    if (inputStream.streamStatus != NSStreamStatusNotOpen) {
        NSAssert(false, @"The provided inputStream must be un-opened.");
        @throw NSInternalInconsistencyException;
        return nil;
    }
    
    if (self = [super init]) {
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
    self.inputStream.delegate = nil;
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
    [self.inputStream open];
}

- (void)disconnect {
    _status = JFRSocketControllerStatusClosing;
    
    dispatch_async(self.ioQueue, ^{
        [self.inputStream close];
        _status = JFRSocketControllerStatusClosed;
    });
    
    //dispatch_suspend(self.ioQueue);
}

#pragma mark - Private

- (void)p_configureInputStream {
    self.inputStream.delegate = self;
    
    CFReadStreamSetDispatchQueue((CFReadStreamRef)self.inputStream, self.ioQueue);
    
    if (self.sslEnabled) {
        [self.inputStream setProperty:NSStreamSocketSecurityLevelKey forKey:NSStreamSocketSecurityLevelNegotiatedSSL];
        
        if (self.allowSelfSignedSSLCertificates) {
            NSDictionary *settings = @{ (NSString *)kCFStreamSSLValidatesCertificateChain: @NO,
                                        (NSString *)kCFStreamSSLValidatesCertificateChain: [NSNull null] };
            
            CFReadStreamSetProperty((CFReadStreamRef)self.inputStream, kCFStreamPropertySSLSettings, (CFDictionaryRef)settings);
        }
    }
    
    if(self.voipEnabled) {
        [self.inputStream setProperty:NSStreamNetworkServiceType forKey:NSStreamNetworkServiceTypeVoIP];
    }
}

- (void)p_closeStream {
    _status = JFRSocketControllerStatusClosed;
    self.inputStream.delegate = nil;
    if (self.inputStream.streamStatus != NSStreamStatusClosed) {
        [self.inputStream close];
    }
    _inputStream = nil;
}

#pragma mark - Input Processing

/** This method deals with efficiently slurping bytes off of the internal input stream. It handles
 * only low level connection errors (i.e. reading on a closed socket)  */
- (void)p_processAvailableBytes {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierIO, @"%s Wrong queue", __PRETTY_FUNCTION__);
    //NSAssert(self.status == JFRSocketControllerStatusOpen || self.status == JFRSocketControllerStatusOpening, @"Improper to read on closed stream (%ld)", self.status);
    
    if (self.status == JFRSocketControllerStatusClosed) {
        return; // no-op for pending reads if the connection was closed
    }

    
    BOOL connectionClosed = NO;
    uint8_t *buffer = NULL;
    NSInteger readBytes = 0;
    NSInteger readsRemaining = 10;
    dispatch_data_t collector = dispatch_data_empty;
    
    do {
        JFRLog(self, @"Reading from stream");
        
        buffer = malloc(sizeof(uint8_t) * kJFRReadBufferMax);
        readBytes = [self.inputStream read:buffer maxLength:kJFRReadBufferMax];
        
        if (readBytes < 0) {
            JFRLog(self, @"Input stream read error (code %ld) %@",
                   [self.inputStream streamStatus], [self.inputStream streamError]);
            free(buffer);
            connectionClosed = YES;
            break; // any already buffered data in `collector` still must be processed.
            
        } else if (readBytes == 0) {
            JFRLog(self, @"No data returned from input stream. Connection is intact.");
            free(buffer);
            break;
            
        } else {
            JFRLog(self, @"Read %ld bytes", readBytes);
            dispatch_data_t part = dispatch_data_create(buffer, readBytes, self.parsingQueue, DISPATCH_DATA_DESTRUCTOR_FREE);
            collector = dispatch_data_create_concat(collector, part);
        }
    } while (--readsRemaining > 0 && readBytes == kJFRReadBufferMax);
    
    if (collector && collector != dispatch_data_empty) {
        dispatch_async(self.parsingQueue, ^{
            [self p_processRawBuffers:collector];
        });
    }
    
    if (connectionClosed) {
        //
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
    
    // variable to hold the leftover unprocessed data fragment
    __block dispatch_data_t fragment = (__bridge dispatch_data_t)dispatch_queue_get_specific(self.parsingQueue, kJFRSocketReadControllerQueueFragmentKey);
    if (!fragment) { // ensure a non-NULL empty data
        fragment = dispatch_data_empty;
    } else { // prepend the fragment to the new data region and then dispose of it.
        JFRLog(self, @"Fragment size is %ld, new data size is %ld", dispatch_data_get_size(fragment), dispatch_data_get_size(data));
        data = dispatch_data_create_concat(fragment, data);
        dispatch_queue_set_specific(self.parsingQueue, kJFRSocketReadControllerQueueFragmentKey, NULL, NULL);
    }
    
    dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
        
        ssize_t bytesUsed = [self p_processRawBuffer:(const uint8_t *)buffer length:size];

        if (bytesUsed == 0) { // unable to find a complete frame.
            fragment = data;
            return NO;
            
        } else if (bytesUsed < 0) { // something terrible happened
            //NSAssert(false, @"Fatal error while parsing data region (-1)");
            JFRLog(self, @"Fatal error while parsing data region (-1)");
            return NO; // error
            
        } else if (bytesUsed > size) { // parser ate more bytes than it was given
            NSAssert(false, @"Fatal error while parsing data region");
            JFRLog(self, @"Fatal error while parsing data region");
            return NO; // error
            
        } else if (bytesUsed < size) { // there was a fragment, save it
            dispatch_data_t thisFragment = dispatch_data_create_subrange(region, bytesUsed, size - bytesUsed);
            fragment = dispatch_data_create_concat(fragment, thisFragment);
            return NO;
            
        }
        
        // Return YES to continue processing ONLY if all bytes in the current region were used (bytesUsed == size).
        return YES;
    });
    
    if (fragment && fragment != dispatch_data_empty) {
        // persist any new fragment
        dispatch_queue_set_specific(self.parsingQueue, kJFRSocketReadControllerQueueFragmentKey, (void *)CFBridgingRetain(fragment), arcDestructorFunction);
    }
}

/** This method accepts a single raw buffer and extracts complete web socket frames from it, returning
 * the number of bytes actually used. The bytes used will be less than length if the buffer contains an
 * incomplete frame. It will also recognize if the HTTP handshake has not yet occured and look for that
 * packet first, if needed.
 * @returns the number of bytes from buffer that were actually used, or -1 on any error.
 */
- (ssize_t)p_processRawBuffer:(const uint8_t *)buffer length:(const size_t)length {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierParsing, @"%s Wrong queue", __PRETTY_FUNCTION__);
    NSParameterAssert(buffer);
    NSParameterAssert(length);
    if (length == 0 || buffer == NULL) {
        return -1;
    }
    
    if (length < 2) {
        return 0; // cannot process a frame without at least the first 2 bytes (minimum websocket header length)
    }
    
    ssize_t remainingLength = length;
    
    // Process the HTTP handshake packet if the websocket is not yet negotiated
    if (self.status == JFRSocketControllerStatusOpening) {
        ssize_t usedLength = [self p_processHttpHandshake:buffer length:remainingLength];
        if (usedLength >= 0) {
            _status = JFRSocketControllerStatusOpen;
            
        } else { // Incomplete or invalid HTTP header
            _status = JFRSocketControllerStatusClosed;
            //[self disconnectStream];
            //[self notifyDelegateDidDisconnectWithReason:@"Invalid HTTP upgrade" code:1];
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
        JFRLog(self, @"Read stream had %lu bytes remaining after HTTP handshake)", remainingLength);
    }
    
    // Process any websocket frames received
    while (remainingLength > 0) {
        //JFRLog(self, @"About to process frame:\n%@", [[NSData dataWithBytesNoCopy:(void *)buffer length:remainingLength freeWhenDone:NO] binaryString]);
        
        ssize_t usedLength = [self p_processWebSocketFrame:buffer length:remainingLength];
        if (usedLength < 0) {
            return -1;
        }
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
        JFRLog(self, @"Unable to find end of HTTP packet.");
        return -1;
    }
    
    // Split the data regions into the HTTP packet data and the remaining raw data.
    BOOL isValid = [self p_validateHttpHandshake:buffer length:packetLength];
    if (!isValid) {
        JFRLog(self, @"HTTP upgrade packet failed verification");
        return -1;
    }

    JFRLog(self, @"HTTP upgrade packet verified");
    [self.delegate websocketControllerDidConnect:self];
    return packetLength;

    /* Debugging – Print HTTP and remaining data
     {
     void *b;
     size_t l = 0;
     dispatch_data_t t = dispatch_data_create_map(data, (const void **)&b, &l);
     NSData *dt = [NSData dataWithBytesNoCopy:b length:l freeWhenDone:NO];
     NSString *str = [[NSString alloc] initWithData:dt encoding:NSUTF8StringEncoding];
     JFRLog(self, @"HTTP DATA:\n%@", str);
     t = nil;
     }
     {
        void *b;
        size_t l = 0;
        dispatch_data_t t = dispatch_data_create_map(*remainingData, (const void **)&b, &l);
        NSData *dt = [NSData dataWithBytesNoCopy:b length:l freeWhenDone:NO];
        JFRLog(self, @"REM DATA:\n%@", [dt binaryString]);
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

/** This method is the heart of the web socket reader. It expects a raw byte buffer containing 0 or more
 * web socket frames. The method will parse out and validate in turn, all of the frames it can find.
 * Valid complete websocket messages and errors both trigger side effects via delegate notifications.
 * @returns The number of bytes written. If this value is negative, an error occurred
 */
- (ssize_t)p_processWebSocketFrame:(const uint8_t *)buffer length:(size_t)length {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierParsing, @"%s Wrong queue", __PRETTY_FUNCTION__);
    NSParameterAssert(buffer);
    NSParameterAssert(length);
    
    
    // Holds the response of a multi-frame response, if this is a continue frame.
    JFRMultiFrameResponse *response = (__bridge JFRMultiFrameResponse *)dispatch_queue_get_specific(self.parsingQueue, kJFRSocketReadControllerQueueReponseKey);

    if (response.bytesLeftInMessage) {
        size_t bytesToAdd = 0;
        if (response.bytesLeftInMessage >= length) {
            bytesToAdd = length;
        } else {
            bytesToAdd = response.bytesLeftInMessage;
        }
        JFRLog(self, @"Payload size is %lu", dispatch_data_get_size(response.payloadData));

        dispatch_data_t additional = dispatch_data_create(buffer, bytesToAdd, self.parsingQueue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        response.payloadData = dispatch_data_create_concat(response.payloadData, additional);
        response.bytesLeftInMessage -= bytesToAdd;

        NSAssert(response.bytesLeftInMessage >= 0, @"Bytes left in message cannot be negative (%ld)", response.bytesLeftInMessage);
        if (response.bytesLeftInMessage <= 0) {
            const void *frameBuffer = NULL;
            size_t frameSize = 0;
            dispatch_data_t tempData = dispatch_data_create_map(response.payloadData, &frameBuffer, &frameSize);
            [self p_processWebSocketMessage:(uint8_t *)frameBuffer length:frameSize opcode:response.opcode];
            tempData = nil;
            dispatch_queue_set_specific(self.parsingQueue, kJFRSocketReadControllerQueueReponseKey, NULL, NULL);
        }
        
        return bytesToAdd;
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
    
    // Fin - Indicates that this is the final fragment in a message. The first fragment MAY also be the final fragment.
    const BOOL isFin = JFRFinMask & buffer[0];
    // rsv1,2,3 - MUST be 0 unless an extension is negotiated that defines meanings for non-zero values.
    const uint8_t rsvBits = JFRRSVMask & buffer[0];
    // Opcode - Defines the interpretation of the "Payload data".  If an unknown opcode is received,
    // the receiving endpoint MUST fail the connection. See opcodes constants
    const JFROpCode receivedOpcode = JFROpCodeMask & buffer[0];
    // Mask - Defines whether the "Payload data" is masked. If true, masking-key is present.
    const BOOL isMasked = JFRMaskMask & buffer[1];
    // Payloan Length - The length of the "Payload data", in bytes: if 0-125, that is the payload length.
    // If 126, the following 2 bytes interpreted as a 16-bit unsigned integer are the payload length.
    // If 127, the following 8 bytes interpreted as a 64-bit unsigned integer are the payload length.
    const uint8_t payloadLen = JFRPayloadLenMask & buffer[1];
    
    // Handle error case - masked data & rsv are currently not supported by this project...
    if((isMasked || rsvBits) && receivedOpcode != JFROpCodePong) {
        
        //[self writeError:JFRCloseCodeProtocolError];
        NSError *error = [[self class] errorWithDetail:@"masked and rsv data is not currently supported" code:JFRCloseCodeProtocolError];
        [self.delegate websocketControllerDidDisconnect:self error:error];
        [self p_closeStream];
        return -1;
    }
    
    // Handle error case - unrecognized opcode (either invalid or new/unrecognized)
    BOOL isControlFrame = receivedOpcode == JFROpCodeConnectionClose || receivedOpcode == JFROpCodePing;
    if(!isControlFrame
       && receivedOpcode != JFROpCodeBinaryFrame
       && receivedOpcode != JFROpCodeTextFrame
       && receivedOpcode != JFROpCodeContinueFrame
       && receivedOpcode != JFROpCodePong) {
        
        //[self writeError:JFRCloseCodeProtocolError];
        NSError *error = [[self class] errorWithDetail:[NSString stringWithFormat:@"unknown opcode: 0x%lx", receivedOpcode]
                                                  code:JFRCloseCodeProtocolError];
        [self.delegate websocketControllerDidDisconnect:self error:error];
        [self p_closeStream];
        return -1;
    }
    
    // Handle error case - All control frames MUST have a payload length of 125 bytes or less and MUST NOT be fragmented.
    if(isControlFrame) {
        NSString *errorReason;
        
        if (!isFin) {
            errorReason = @"All control frames MUST NOT be fragmented.";
            
        } else if (payloadLen > 125) {
            errorReason = @"All control frames MUST have a payload length of 125 bytes or less.";
        }
        
        if (errorReason) {
            //[self writeError:JFRCloseCodeProtocolError];
            NSError *error = [[self class] errorWithDetail:errorReason code:JFRCloseCodeProtocolError];
            [self.delegate websocketControllerDidDisconnect:self error:error];
            [self p_closeStream];
            return -1;
        }
    }
    
    // Handle error case - continuation frame without previous non-continuation frame
    if (!response && receivedOpcode == JFROpCodeContinueFrame) {
        //[self writeError:JFRCloseCodeProtocolError];
        NSError *error = [[self class] errorWithDetail:@"continue frame before non-continue frame"
                                                  code:JFRCloseCodeProtocolError];
        [self.delegate websocketControllerDidDisconnect:self error:error];
        [self p_closeStream];
        return -1;
    }
    
    // Handle error case - expected continuation frame, but received non-continuation frame
    if (response && receivedOpcode != JFROpCodeContinueFrame) {
        //[self writeError:JFRCloseCodeProtocolError];
        NSString *reason = [NSString stringWithFormat:@"expected continuation frame, "
                            @"received non-continuation frame [code 0x%lx]", receivedOpcode];
        NSError *error = [[self class] errorWithDetail:reason
                                                  code:JFRCloseCodeProtocolError];
        [self.delegate websocketControllerDidDisconnect:self error:error];
        [self p_closeStream];
        return -1;
    }
    
    // Handle Opcode - Server disconnected
    if(receivedOpcode == JFROpCodeConnectionClose) {
        NSInteger offset = sizeof(uint16_t); // skip the original 2-byte web socket header
        NSString *closeReason;
        
        // Determine appropriate server close code
        uint16_t code = JFRCloseCodeNormal;
        if(payloadLen == 1) {
            code = JFRCloseCodeNoStatusReceived; // optional status code not received
            
        } else if(payloadLen > 1) {
            code = CFSwapInt16BigToHost(*(uint16_t *)(buffer + offset));
            if(code < 1000 || (code > 1003 && code < 1007) || (code > 1011 && code < 3000)) {
                code = JFRCloseCodeProtocolError;
            }
            offset += sizeof(uint16_t);

            // Determine appropriate server close reason, if provided
            NSInteger reasonLength = payloadLen - sizeof(uint16_t); // account for the 2-byte reason code
            if(reasonLength > 0) {
                closeReason = [[NSString alloc] initWithBytes:(void *)(buffer + offset)
                                                       length:reasonLength
                                                     encoding:NSUTF8StringEncoding];
            }
        }
        
        if (closeReason.length) {
            closeReason = [NSString stringWithFormat:@"close reason [%@]", closeReason];
        }

        NSError *error = [[self class] errorWithDetail:closeReason code:code];
        [self.delegate websocketControllerDidDisconnect:self error:error];
        [self p_closeStream];
        return payloadLen + sizeof(uint16_t); // add back in the original 2-byte web socket frame header
    }
    
    size_t offset = 2;
    
    // Compute actual payload length: can be either 8-bit, 16-bit ot 64-bit.
    NSInteger framePayloadLength = payloadLen;  // 8-bit
    if(payloadLen == 127) {                     // 64-bit
        framePayloadLength = CFSwapInt64BigToHost(*(uint64_t *)(buffer+offset));
        offset += 8;
        
    } else if(payloadLen == 126) {              // 16-bit
        framePayloadLength = CFSwapInt16BigToHost(*(uint16_t *)(buffer+offset) );
        offset += 2;
    }
    
    // Detect incomplete frame OR detect additional frames in buffer
    // A) frame payload length = remaining buffer length :: Frame is entirely contained within buffer & additional frames are NOT present
    // B) frame payload length < remaining buffer length :: Frame is entirely contained within buffer & additional frame are present
    // C) frame payload length > remaining buffer length :: Frame is NOT entirely contained within buffer & additional bytes are needed
    
    ssize_t remainingBufferLength = length - offset; // remaining bytes in the buffer
    ssize_t remainingLengthAfterFrame = remainingBufferLength - framePayloadLength; // portion of remaining bytes which are beyond this frame
    BOOL frameIsIncomplete = remainingLengthAfterFrame < 0; // the buffer does not contain the data to satisfy this frame.
    
    if(frameIsIncomplete || !isFin) { // C
        if (!response) {
            response = [JFRMultiFrameResponse new];
            response.opcode = receivedOpcode;
        }
        
        // The current data buffer will be collected below – after checking to ensure that this is not a pong frame
        dispatch_queue_set_specific(self.parsingQueue, kJFRSocketReadControllerQueueReponseKey, (__bridge_retained void *)response, arcDestructorFunction);
    }
    
    // Handle multi-frame or multi-part messages with payload
    // If message is incomplete, save a copy of the data frame payload and shove it into the multi-frame response object.
    if (response) {
        // First, update the response state to account for the new frame / additional data
        response.isFinished = isFin;
        
        if (frameIsIncomplete) {
            response.bytesLeftInMessage = -remainingLengthAfterFrame;
            response.fragmentCount++;
        } else {
            response.frameCount++;
        }
        
        // Next concatenate any new data onto the payload
        size_t additionalPayloadLength = framePayloadLength;
        if (additionalPayloadLength > length - offset) {
            additionalPayloadLength = length - offset;
        }
        
        dispatch_data_t additionalPayloadData = dispatch_data_create(buffer+offset, additionalPayloadLength, self.parsingQueue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        if (response.payloadData) {
            response.payloadData = dispatch_data_create_concat(response.payloadData, additionalPayloadData);
        } else {
            response.payloadData = additionalPayloadData;
        }
        
        // Second, if the multi-frame fragmented message is completed, or the missing bytes have been satisfied...
        if (isFin && response.bytesLeftInMessage == 0) { // Handle multi-frame message is complete.
            const void *frameBuffer = NULL;
            size_t frameSize = 0;
            dispatch_data_t tempData = dispatch_data_create_map(response.payloadData, &frameBuffer, &frameSize);
            [self p_processWebSocketMessage:(uint8_t *)frameBuffer length:frameSize opcode:response.opcode];
            tempData = nil;
            dispatch_queue_set_specific(self.parsingQueue, kJFRSocketReadControllerQueueReponseKey, NULL, NULL);
        }
    } else if (isFin) { // Single-frame message finished
        [self p_processWebSocketMessage:buffer+offset length:framePayloadLength opcode:receivedOpcode];
    }
    
    /*
     // Handle Opcode - Pong
     if(receivedOpcode == JFROpCodePong) {
     // From the RFC:
     //> A Pong frame sent in response to a Ping frame must have identical "Application data" as found in
     //> the message body of the Ping frame being replied to.
     //>
     //> If an endpoint receives a Ping frame and has not yet sent Pong frame(s) in response to previous Ping
     //> frame(s), the endpoint MAY elect to send a Pong frame for only the most recently processed Ping frame.
     //>
     //> A Pong frame MAY be sent unsolicited.  This serves as a unidirectional heartbeat.  A response to an
     //> unsolicited Pong frame is not expected.
     //
     // Therefore, at this time we can generally skip over and ignore the payload of a pong frame.
     
     // Discard the remaining buffer if it only contains data for this frame (i.e. frame == buffer or frame is incomplete.
     // For non-pong frames, need to collect the payload data (which may be complete or incomplete).
     return payloadLen + offset;
     }
     */
    
    // Other opcodes require data to be preserved as above
    // JFROpCodeBinary & JFROpCodeText
    // JFROpCodePing (repeat the data back to the the server in a pong frame)
    // JFROpCodeContinueFrame (append to previously received binary, text or ping frame data)
    
    if (remainingLengthAfterFrame > 0) {
        return length - remainingLengthAfterFrame;
    } else {
        return length; // every byte has been consumed (and more is needed!)
    }
}

- (void)p_processWebSocketMessage:(const uint8_t *)buffer length:(size_t)length opcode:(uint8_t)opcode {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierParsing, @"%s Wrong queue", __PRETTY_FUNCTION__);
    NSParameterAssert(buffer);
    
    if (!buffer) {
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
            NSAssert(str, @"Failed to initialize text message");
            if(!str) {
                //[self writeError:JFRCloseCodeEncoding];
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
    }
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode {
    NSAssert(dispatch_get_specific(kJFRSocketReadControllerQueueIdentifierKey) == kJFRSocketReadControllerQueueIdentifierIO, @"%s Wrong queue", __PRETTY_FUNCTION__);

    switch (eventCode) {
            
        case NSStreamEventNone:
            JFRLog(self, @"%p read stream unknown event", stream);
            break;
            
        case NSStreamEventOpenCompleted:
            JFRLog(self, @"%p read stream open", stream);
            [self.delegate websocketControllerDidConnect:self];
            break;
            
        case NSStreamEventHasBytesAvailable:
        {
            JFRLog(self, @"%p read stream has bytes available", stream);
            dispatch_async(self.ioQueue, ^{
                [self p_processAvailableBytes];
            });
            break;
        }
        case NSStreamEventHasSpaceAvailable:
            JFRLog(self, @"%p read stream has space (this is meaningless)", stream);
            NSAssert(false, @"input stream should not be writable");
            break;
            
        case NSStreamEventErrorOccurred:
        {
            JFRLog(self, @"%p read stream error", stream);
            [self.delegate websocketControllerDidDisconnect:self error:[stream streamError]];
            break;
        }
        case NSStreamEventEndEncountered:
        {
            JFRLog(self, @"%p read stream end encountered", stream);
            [self.delegate websocketControllerDidDisconnect:self
                                                      error:[[self class] errorWithDetail:@"Connection lost." code:JFRCloseCodeNormal]];
            break;
        }
        default:
            JFRLog(self, @"%p read stream – unknown event", stream);
            break;
    }
}

@end
