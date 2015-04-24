//
//  JFRSocketControllerStatus.h
//  SimpleTest
//
//  Created by Adam Kaplan on 4/20/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#ifndef SimpleTest_JFRSocketControllerStatus_h
#define SimpleTest_JFRSocketControllerStatus_h

typedef NS_ENUM(NSUInteger, JFRSocketControllerStatus) {
    JFRSocketControllerStatusNew        = 0,
    JFRSocketControllerStatusOpening    = 1,
    JFRSocketControllerStatusOpen       = 2,
    JFRSocketControllerStatusClosingHandshakeInitiated = 3,
    JFRSocketControllerStatusClosingHandshakeComplete  = 4,
    JFRSocketControllerStatusClosed     = 5,
};

#endif
