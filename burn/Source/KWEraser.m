#import "KWEraser.h"
#import "KWProgressManager.h"

@implementation KWEraser

- (id)init
{
    self = [super init];

    shouldClose = NO;
    
    [[NSBundle mainBundle] loadNibNamed:@"KWEraser" owner:self topLevelObjects:nil];

    return self;
}

///////////////////
// Main actions //
///////////////////

#pragma mark -
#pragma mark •• Main actions

- (void)setupWindow
{
    [burnerPopup removeAllItems];
    
    NSArray *devices = [DRDevice devices];
    NSInteger i;
    for (i=0;i< [devices count];i++)
    {
	    [burnerPopup addItemWithTitle:[[devices objectAtIndex:i] displayName]];
    }
    
    NSString *displayName = [[self savedDevice] displayName];
    if ([burnerPopup indexOfItemWithTitle:displayName] > -1)
    {
	    [burnerPopup selectItemAtIndex:[burnerPopup indexOfItemWithTitle:displayName]];
    }
    
    [self updateDevice:[self currentDevice]];

    [[DRNotificationCenter currentRunLoopCenter] addObserver:self selector:@selector(statusChanged:) name:DRDeviceStatusChangedNotification object:nil];
}

- (void)beginEraseSheetForWindow:(NSWindow *)window completion:(void (^)(NSModalResponse returnCode))completion
{
    [self setupWindow];
    
    [window beginSheet:[self window] completionHandler:^(NSModalResponse returnCode)
    {
        [[DRNotificationCenter currentRunLoopCenter] removeObserver:self name:DRDeviceStatusChangedNotification object:nil];
        completion(returnCode);
    }];
}

- (NSInteger)beginEraseWindow
{
    [burnerPopup removeAllItems];
    
    [self setupWindow];
    
    NSInteger x = [NSApp runModalForWindow:[self window]];
    [[self window] close];

    return x;
}

- (void)erase
{
    DRErase *erase = [[DRErase alloc] initWithDevice:[self currentDevice]];

    if ([completelyErase state] == NSOnState)
	    [erase setEraseType:DREraseTypeComplete];
    else
	    [erase setEraseType:DREraseTypeQuick];    
	    
    //Save burner
    NSMutableDictionary *burnDict = [[NSMutableDictionary alloc] init];

    [burnDict setObject:[[[self currentDevice] info] objectForKey:@"DRDeviceProductNameKey"] forKey:@"Product"];
    [burnDict setObject:[[[self currentDevice] info] objectForKey:@"DRDeviceVendorNameKey"] forKey:@"Vendor"];
    [burnDict setObject:@"" forKey:@"SerialNumber"];

    [[NSUserDefaults standardUserDefaults] setObject:burnDict forKey:@"KWDefaultDeviceIdentifier"];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"KWMediaChanged" object:nil];

    [[DRNotificationCenter currentRunLoopCenter] addObserver:self selector:@selector(eraseNotification:) name:DREraseStatusChangedNotification object:erase];    

    [erase start];
}

- (void)updateDevice:(DRDevice *)device
{
    NSDictionary *deviceStatus = [device status];
    NSString *statusString = [deviceStatus objectForKey:DRDeviceMediaStateKey];

    if ([statusString isEqualTo:DRDeviceMediaStateMediaPresent])
    {
	    if ([[[deviceStatus objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceMediaIsErasableKey] boolValue])
	    {
    	    [closeButton setEnabled:YES];
    	    [closeButton setTitle:NSLocalizedString(@"Eject", nil)];
	    
    	    [statusText setStringValue:NSLocalizedString(@"Ready to erase", nil)];
	    
    	    [eraseButton setEnabled:YES];
	    }
	    else
	    {
    	    [device ejectMedia];
	    }
    }
    else if ([statusString isEqualTo:DRDeviceMediaStateInTransition])
    {
	    [closeButton setEnabled:NO];
	    [statusText setStringValue:NSLocalizedString(@"Waiting for the drive...", nil)];
	    [eraseButton setEnabled:NO];
    }
    else if ([statusString isEqualTo:DRDeviceMediaStateNone])
    {
	    if ([[[device info] objectForKey:DRDeviceLoadingMechanismCanOpenKey] boolValue])
	    {
    	    [closeButton setEnabled:YES];
	    
    	    if ([[deviceStatus objectForKey:DRDeviceIsTrayOpenKey] boolValue])
	    	    [closeButton setTitle:NSLocalizedString(@"Close", nil)];
    	    else
	    	    [closeButton setTitle:NSLocalizedString(@"Open", nil)];
	    }
	    else
	    {
    	    [closeButton setTitle:NSLocalizedString(@"Close", nil)];
    	    [closeButton setEnabled:NO];
	    }
	    
	    [statusText setStringValue:NSLocalizedString(@"Waiting for a disc to be inserted...", nil)];
	    [eraseButton setEnabled:NO];
    }
}

///////////////////////
// Interface actions //
///////////////////////

#pragma mark -
#pragma mark •• Interface actions

- (IBAction)burnerPopup:(id)sender
{
    DRDevice *currentDevice = [self currentDevice];

    if ([[[currentDevice info] objectForKey:DRDeviceLoadingMechanismCanOpenKey] boolValue])
    {
	    if (![[[currentDevice status] objectForKey:DRDeviceIsTrayOpenKey] boolValue])
	    {
    	    [currentDevice openTray];
    	    shouldClose = YES;
	    }
    }
    
    NSArray *devices = [DRDevice devices];
    NSInteger z;
    for (z=0;z<[devices count];z++)
    {
	    DRDevice *device = [devices objectAtIndex:z];
	    
	    if ([[[device info] objectForKey:DRDeviceLoadingMechanismCanOpenKey] boolValue] && [[[device status] objectForKey:DRDeviceIsTrayOpenKey] boolValue] && (!z) == [burnerPopup indexOfSelectedItem])
    	    [device closeTray];
    }

    [self updateDevice:currentDevice];
}

- (IBAction)cancelButton:(id)sender
{
    if (shouldClose)
	    [[[DRDevice devices] objectAtIndex:[burnerPopup indexOfSelectedItem]] closeTray];
	    
    [[DRNotificationCenter currentRunLoopCenter] removeObserver:self name:DREraseStatusChangedNotification object:nil];
    
    if ([[self window] isSheet])
    {
        NSWindow *window = [self window];
	    [[window sheetParent] endSheet:window returnCode:NSModalResponseCancel];
        [window orderOut:self];
    }
    else
    {
	    [NSApp stopModalWithCode:NSModalResponseCancel];
    }
}

- (IBAction)closeButton:(id)sender
{
    DRDevice *selectedDevice = [[DRDevice devices] objectAtIndex:[burnerPopup indexOfSelectedItem]];

    if ([[closeButton title] isEqualTo:NSLocalizedString(@"Eject", nil)])
    {
	    [selectedDevice ejectMedia];
    }
    else if ([[closeButton title] isEqualTo:NSLocalizedString(@"Close", nil)])
    {
	    [selectedDevice closeTray];
    }
    else if ([[closeButton title] isEqualTo:NSLocalizedString(@"Open", nil)])
    {
	    shouldClose = YES;
	    [selectedDevice openTray];
    }
}

- (IBAction)eraseButton:(id)sender
{
    [[DRNotificationCenter currentRunLoopCenter] removeObserver:self name:DREraseStatusChangedNotification object:nil];
    
    if ([[self window] isSheet])
    {
        NSWindow *window = [self window];
        [window orderOut:self];
	    [[window sheetParent] endSheet:window returnCode:NSModalResponseOK];
    }
    else
    {
	    [NSApp stopModalWithCode:NSModalResponseOK];
    }
}

//////////////////////////
// Notification actions //
//////////////////////////

#pragma mark -
#pragma mark •• Notification actions

- (void)statusChanged:(NSNotification *)notif
{
    DRDevice *notifDevice = [notif object];

    if ([[notifDevice displayName] isEqualTo:[burnerPopup title]])
    [self updateDevice:notifDevice];
}

- (void)eraseNotification:(NSNotification*)notification    
{    
    NSDictionary* status = [notification userInfo];
    DRErase *eraseObject = [notification object];
    NSString *currentStatusString = [status objectForKey:DRStatusStateKey];
    NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];
    NSString *time = @"";
    NSString *statusString = nil;
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"KWDebug"])
	    NSLog(@"%@", [status description]);
    
    double percent = [[status objectForKey:DRStatusPercentCompleteKey] doubleValue];
    if (percent > 0)
    {
        KWProgressManager *progressManager = [KWProgressManager sharedManager];
        [progressManager setMaximumValue:1.0];
        [progressManager setValue:percent];
	    
	    NSString *progressString = [KWCommonMethods formatTime:[[[status objectForKey:@"DRStatusProgressInfoKey"] objectForKey:@"DRStatusProgressRemainingTime"] intValue]];
	    
	    time = [NSString stringWithFormat:@" (%@)", progressString];
    }
    else
    {
        [[KWProgressManager sharedManager] setMaximumValue:0.0];
    }

    if ([currentStatusString isEqualTo:DRStatusStatePreparing])
    {
	    statusString = NSLocalizedString(@"Preparing...", nil);
    }
    else if ([currentStatusString isEqualTo:DRStatusStateErasing])
    {
	    statusString = [NSLocalizedString(@"Erasing disc", nil) stringByAppendingString:time];
    }
    else if ([currentStatusString isEqualTo:DRStatusStateFinishing])
    {
	    statusString = NSLocalizedString(@"Finishing...", nil);
    }
    else if ([currentStatusString isEqualTo:DRStatusStateDone])
    {
	    [[DRNotificationCenter currentRunLoopCenter] removeObserver:self name:DREraseStatusChangedNotification object:eraseObject];
	    
	    [defaultCenter postNotificationName:@"KWEraseFinished" object:self userInfo:[NSDictionary dictionaryWithObject:@"KWSucces" forKey:@"ReturnCode"]];
    }
    else if ([currentStatusString isEqualTo:DRStatusStateFailed])
    {
	    [[DRNotificationCenter currentRunLoopCenter] removeObserver:self name:DREraseStatusChangedNotification object:eraseObject];
    
	    [defaultCenter postNotificationName:@"KWEraseFinished" object:self userInfo:[NSDictionary dictionaryWithObject:@"KWFailure" forKey:@"ReturnCode"]];
    }
    
    if (statusString)
    {
        [[KWProgressManager sharedManager] setStatus:statusString];
    }
}

///////////////////
// Other actions //
///////////////////

#pragma mark -
#pragma mark •• Other actions

- (DRDevice *)currentDevice
{
    return [[DRDevice devices] objectAtIndex:[burnerPopup indexOfSelectedItem]];
}

- (DRDevice *)savedDevice
{
    NSArray *devices = [DRDevice devices];
    NSInteger i;
    for (i=0;i< [devices count];i++)
    {
    DRDevice *currentDevice = [devices objectAtIndex:i];
    
	    if ([[[currentDevice info] objectForKey:@"DRDeviceProductNameKey"] isEqualTo:[[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"KWDefaultDeviceIdentifier"] objectForKey:@"Product"]])
	    {
    	    return currentDevice;
	    }
    }
    
    return [devices objectAtIndex:0];
}

@end
