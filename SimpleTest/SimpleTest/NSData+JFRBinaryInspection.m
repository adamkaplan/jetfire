//
//  NSData+JFRBinaryInspection.m
//  SimpleTest
//
//  Created by Adam Kaplan on 4/15/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import "NSData+JFRBinaryInspection.h"

@implementation NSData (JFRBinaryInspection)

- (NSString *)binaryString {
    static const unsigned char mask = 0x01;
    
    NSMutableString *str = [NSMutableString stringWithString:
                            @"               1          2          3\n"
                            @"     12345678 90123456 78901234 56789012\n"
                            @"   *------------------------------------"];
    NSUInteger length = self.length;
    const unsigned char* bytes = self.bytes;
    
    NSUInteger lineNumber = 1;
    for (NSUInteger offset = 0; offset < length; offset++) {
        
        if (offset == 0 || offset % 4 == 0) {
            [str appendFormat:@"\n%3lu| ", lineNumber++];
        }
        else {
            [str appendString:@" "];
        }
        
        for (char bit = 7; bit >= 0; bit--) {
            
            if ((mask << bit) & *(bytes+offset)) {
                [str appendString:@"1"];
            }
            else {
                [str appendString:@"0"];
            }
        }
    }
    
    return [str copy];
}

@end
