//
//  KWRegionDialog.m
//  Burn
//
//  Created by Maarten Foukhar on 29/12/2019.
//

#import "KWRegionDialog.h"

@implementation KWRegionDialog

- (instancetype)init
{
    self = [super init];
    
    if (self)
    {
        [[NSBundle mainBundle] loadNibNamed:NSStringFromClass([self class]) owner:self topLevelObjects:nil];
    }
    
    return self;
}

- (IBAction)selectRegion:(NSPopUpButton *)popUpButton
{
    [self setRegion:[popUpButton indexOfSelectedItem]];
}

- (IBAction)close:(id)sender
{
    NSWindow *window = [self window];
    [[window sheetParent] endSheet:window returnCode:NSModalResponseOK];
}

@end
