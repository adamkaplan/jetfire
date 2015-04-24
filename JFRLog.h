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

#if FALSE

#define JFRLog(SELF, FMT, ...) do {} while(false)
#else
#define JFRLog(SELF, FMT, ...) _JFRLog(SELF, FMT, ## __VA_ARGS__)
#endif

void _JFRLog(id self, NSString *format, ...);

#endif /* defined(__SimpleTest__JFRLog__) */
