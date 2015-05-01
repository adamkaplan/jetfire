//
//  JFRLog.h
//  SimpleTest
//
//  Created by Adam Kaplan on 4/20/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#ifndef __SimpleTest__JFRLog__
#define __SimpleTest__JFRLog__

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, JFRLogLevel) {
    JFRError,
    JFRWarn,
    JFRInfo,
    JFRDebug,
    JFRBinary,
};

extern const JFRLogLevel JFRCurrentLogLevel;


#if TRUE
#define JFRLog(...) do {} while(false)
#else
#define JFRLog(LEVEL, FORMAT, ...) _JFRLog(self, LEVEL, FORMAT, ## __VA_ARGS__)
#endif

extern void _JFRLog(id self, JFRLogLevel level, NSString *format, ...);

#endif /* defined(__SimpleTest__JFRLog__) */
