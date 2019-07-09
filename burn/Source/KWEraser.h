/* KWEraser */

#import <Cocoa/Cocoa.h>
#import <DiscRecording/DiscRecording.h>
#import "KWCommonMethods.h"

@interface KWEraser : NSWindowController
{
    //Interface outlets
    IBOutlet id burnerPopup;
    IBOutlet id closeButton;
    IBOutlet id completelyErase;
    IBOutlet id eraseButton;
    IBOutlet id quicklyErase;
    IBOutlet id statusText;
    
    //Variables
    BOOL shouldClose;
}
//Main actions
- (void)setupWindow;
- (void)beginEraseSheetForWindow:(NSWindow *)window completion:(void (^)(NSModalResponse returnCode))completion;
- (NSInteger)beginEraseWindow;
- (void)erase;
- (void)updateDevice:(DRDevice *)device;

//Interface actions
- (IBAction)burnerPopup:(id)sender;
- (IBAction)cancelButton:(id)sender;
- (IBAction)closeButton:(id)sender;
- (IBAction)eraseButton:(id)sender;

//Notification actions
- (void)statusChanged:(NSNotification *)notif;
- (void)eraseNotification:(NSNotification*)notification;

//Other actions
- (DRDevice *)currentDevice;
- (DRDevice *)savedDevice;

@end
