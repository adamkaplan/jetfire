//
//  TestCaseTableViewcell.m
//  SimpleTest
//
//  Created by Adam Kaplan on 4/14/15.
//  Copyright (c) 2015 Vluxe. All rights reserved.
//

#import "TestCaseTableViewcell.h"
#import "TestCase.h"

@interface TestCaseTableViewcell ()
@property (nonatomic) UILabel *statusLabel;
@property (nonatomic) UIView *statusView; // UITableViewCell does some introspection on this view and if it's a label, causes a memory leak.
@property (nonatomic) UIActivityIndicatorView *spinnerView;
@end

@implementation TestCaseTableViewcell

- (void)awakeFromNib {
    // Initialization code
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 60, 30)];
    self.statusLabel.font = [UIFont systemFontOfSize:[UIFont smallSystemFontSize]];
    self.statusLabel.minimumScaleFactor = 0.2;
    self.statusLabel.textAlignment = NSTextAlignmentRight;
    
    self.detailTextLabel.text = @" ";
    
    self.statusView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 60, 30)];
    [self.statusView addSubview:self.statusLabel];
    self.accessoryView = self.statusView;
    
    self.spinnerView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.testCase = nil;
    self.textLabel.text = nil;
    self.detailTextLabel.text = nil;
    self.statusLabel.text = nil;
    self.accessoryView = self.statusView;
}

- (void)setTestCase:(TestCase *)testCase {
    [self.testCase removeObserver:self forKeyPath:@"identifier"];
    [self.testCase removeObserver:self forKeyPath:@"summary"];
    [self.testCase removeObserver:self forKeyPath:@"status"];
    
    _testCase = testCase;

    if (testCase) {
        self.textLabel.text = _testCase.identifier ?: @" "; // For some reason blank strings break the cell updating
        self.detailTextLabel.text = _testCase.summary ?: @" "; // For some reason blank strings break the cell updating
        [self updateStatusLabel];
        
        [testCase addObserver:self forKeyPath:@"identifier" options:NSKeyValueObservingOptionNew context:nil];
        [testCase addObserver:self forKeyPath:@"summary" options:NSKeyValueObservingOptionNew context:nil];
        [testCase addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    NSString *value = change[NSKeyValueChangeNewKey];
    
    NSAssert(![value isKindOfClass:[NSNull class]], @"Invalid test case value for %@ from Autobahn: %@", keyPath, change);

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!weakSelf) {
            return;
        }
        
        if ([keyPath isEqualToString:@"identifier"]) {
            weakSelf.textLabel.text = value;
        
        } else if ([keyPath isEqualToString:@"summary"]) {
            weakSelf.detailTextLabel.text = value;
            
        } else {
            [weakSelf updateStatusLabel];
        }
    });
}

- (void)updateStatusLabel {
    NSString *text;
    switch (self.testCase.status) {
        case TestCaseStatusNotRun:
            text = @" ";
            break;
            
        case TestCaseStatusPassed:
            text = @"😎";
            break;
            
        case TestCaseStatusFailed:
            text = @"😡";
            break;
            
        case TestCaseStatusRunning:
            break;
        
        case TestCaseStatusInformational:
            text = @"😈";
            break;
            
        default:
            text = @"😲";
            break;
    }
    
    if (text) {
        [self.spinnerView stopAnimating];
        
        self.statusLabel.text = text;
        self.accessoryView = self.statusView;
    } else {
        self.accessoryView = self.spinnerView;
        [self.spinnerView startAnimating];
    }
}

@end
