//
//  JFRWebSocketControllerDelegate.h
//  SimpleTest
//
//  Created by Adam Kaplan on 4/20/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import <Foundation/Foundation.h>

@class JFRWebSocketController, JFRWebSocketReadController, JFRWebSocketWriteController;

#pragma mark Common Controller Delegate

@protocol JFRWebSocketControllerDelegate <NSObject>

- (void)websocketControllerDidConnect:(JFRWebSocketController *)controller;

- (void)websocketControllerDidDisconnect:(JFRWebSocketController *)controller error:(NSError *)error;

- (void)websocketController:(JFRWebSocketController *)controller shouldFailWithError:(NSError *)error;

- (void)websocketController:(JFRWebSocketController *)controller shouldCloseWithError:(NSError *)error;

@end

#pragma mark Read Controller Delegate

@protocol JFRWebSocketReadControllerDelegate <JFRWebSocketControllerDelegate>

- (void)websocketController:(JFRWebSocketReadController *)controller didReceiveMessage:(NSString *)string;

- (void)websocketController:(JFRWebSocketReadController *)controller didReceiveData:(NSData *)data;

- (void)websocketController:(JFRWebSocketReadController *)controller didReceivePing:(NSData *)ping;

@end

#pragma mark Write Controller Delegate

@protocol JFRWebSocketWriteControllerDelegate <JFRWebSocketControllerDelegate>

@end
