//
//  JFRWebSocketReadController.h
//  SimpleTest
//
//  Created by Adam Kaplan on 4/20/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import "JFRWebSocketController.h"
#import "JFRWebSocketControllerDelegate.h"

@interface JFRWebSocketReadController : JFRWebSocketController

/** Input stream provided during intialization */
@property (nonatomic, readonly) NSInputStream *inputStream;

@property (nonatomic, assign) id<JFRWebSocketReadControllerDelegate> delegate;

/** Initialize with an input stream. The stream must be new and un-opened */
- (instancetype)initWithInputStream:(NSInputStream *)inputStream NS_DESIGNATED_INITIALIZER;

- (void)connect;

- (void)disconnect;

@end
