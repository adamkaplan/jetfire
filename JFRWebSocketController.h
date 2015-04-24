//
//  JFRWebSocketController.h
//  SimpleTest
//
//  Created by Adam Kaplan on 4/20/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "JFRSocketControllerStatus.h"

extern const void *const kJFRSocketReadControllerQueueIdentifierKey;
extern const void *const kJFRSocketReadControllerQueueIdentifierIO;

/** WebSocket bit masks. Used to extract various values from the binary frames  */
static const uint8_t JFRFinMask             = 0x80;
static const uint8_t JFROpCodeMask          = 0x0F;
static const uint8_t JFRRSVMask             = 0x70;
static const uint8_t JFRMaskMask            = 0x80;
static const uint8_t JFRPayloadLenMask      = 0x7F;
static const size_t  JFRMaxFrameSize        = 32;

/** WebSocket opCodes, RFC-6422 */
typedef NS_ENUM(UInt8, JFROpCode) {
    JFROpCodeContinueFrame      = 0x0,
    JFROpCodeTextFrame          = 0x1,
    JFROpCodeBinaryFrame        = 0x2,
    //3-7 are reserved.
    JFROpCodeConnectionClose    = 0x8,
    JFROpCodePing               = 0x9,
    JFROpCodePong               = 0xA,
    //B-F reserved.
};

static inline BOOL JFROpCodeIsControl(JFROpCode opcode) {
    // RFC-6455 5.5 - Control frames are identified by opcodes where the most significant bit of the opcode is 1.
    return opcode & 0x8;
}

static inline BOOL JFROpCodeIsValid(JFROpCode opcode) {
    // RFC-6455 5.5 - Control frames are identified by opcodes where the most significant bit of the opcode is 1.
    return opcode < 3 || (opcode < 0xB && opcode > 0x7);
}

/** WebSocket close codes, RFC-6422 */
typedef NS_ENUM(NSUInteger, JFRCloseCode) {
    JFRCloseCodeNormal                 = 1000,
    JFRCloseCodeGoingAway              = 1001,
    JFRCloseCodeProtocolError          = 1002,
    JFRCloseCodeProtocolUnhandledType  = 1003,
    // 1004 reserved.
    JFRCloseCodeNoStatusReceived       = 1005,
    //1006 reserved.
    JFRCloseCodeEncoding               = 1007,
    JFRCloseCodePolicyViolated         = 1008,
    JFRCloseCodeMessageTooBig          = 1009
};

@interface JFRWebSocketController : NSObject

/** Set to enable or disable SSL prior to opening the connection. No effect if the underlying connection is open.
 * Enabled by default.
 */
@property (nonatomic) BOOL sslEnabled;

/** Set to enable or disable the self-signed SSL certificates. No effect if the underlying connection is open.
 * Disabled by default. Enabling this setting is potentially insecure!
 */
@property (nonatomic) BOOL allowSelfSignedSSLCertificates;

/** Set to enable or disable VOIP mode prior to opening the connection. No effect if the underlying connection is open.
 * Disabled by default. See Apple VOIP documentation for details on how this will impact your web socket.
 */
@property (nonatomic) BOOL voipEnabled;

/** Current state of the socket – may differ from the state of the underlying stream. */
@property (nonatomic, readonly) JFRSocketControllerStatus status;

+ (NSError *)errorWithDetail:(NSString *)detail code:(NSInteger)code;

@end
