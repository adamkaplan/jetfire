//
//  JFRWebSocketWriteController.h
//  SimpleTest
//
//  Created by Adam Kaplan on 4/20/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import "JFRWebSocketController.h"
#import "JFRWebSocketControllerDelegate.h"

@interface JFRWebSocketWriteController : JFRWebSocketController

/** Output stream provided during intialization */
@property (nonatomic, readonly) CFWriteStreamRef outputStream;

@property (nonatomic, weak) id<JFRWebSocketWriteControllerDelegate> delegate;

/** Initialize with an input stream. The stream must be new and un-opened */
- (instancetype)initWithOutputStream:(CFWriteStreamRef)outputStream NS_DESIGNATED_INITIALIZER;

- (void)connect;

- (void)disconnect;

- (void)failWithCloseCode:(NSUInteger)code reason:(NSString *)reason;

- (void)writeString:(NSString *)string;

- (void)writeData:(NSData *)data;

- (void)writePing:(NSData *)data;

- (void)writePong:(NSData *)data;

- (void)writeCloseCode:(NSUInteger)code reason:(NSString *)reason;

/** Writes data as raw bytes, without any introspection or additional web socket framing.
 * Typically used to send HTTP packets prior to completing the web socket handshake.
 */
- (void)writeRawData:(NSData *)data;

@end
