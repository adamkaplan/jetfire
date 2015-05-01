//
//  JFRLog.c
//  SimpleTest
//
//  Created by Adam Kaplan on 4/20/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#include "JFRLog.h"

const JFRLogLevel JFRCurrentLogLevel = JFRDebug;

void _JFRLog(id self, JFRLogLevel level, NSString *format, ...) {
    if (level > JFRCurrentLogLevel) {
        return;
    }
    
    va_list args;
    va_start(args, format);
    NSLogv([NSString stringWithFormat:@"[socket %p] %@", self, format], args);
    va_end(args);
}
