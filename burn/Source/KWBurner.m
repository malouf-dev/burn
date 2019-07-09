#import "KWBurner.h"
#import "KWTrackProducer.h"
#import "KWProgressManager.h"

@implementation KWBurner

- (id)init
{
    self = [super init];
    
    if (self)
    {
        shouldClose = NO;
        userCanceled = NO;
        ignoreMode = NO;
        layerBreak = nil;
        
        [[NSBundle mainBundle] loadNibNamed:@"KWBurner" owner:self topLevelObjects:nil];
    }

    return self;
}

///////////////////
// Main actions //
///////////////////

#pragma mark -
#pragma mark •• Main actions

- (void)beginBurnSetupSheetForWindow:(NSWindow *)window completion:(void (^)(NSModalResponse returnCode))completion
{
    NSWindow *myWindow = [self window];

    [burnerPopup removeAllItems];

    NSInteger i;
    for (i=0;i< [[DRDevice devices] count];i++)
    {
	    NSString *displayName = [[[DRDevice devices] objectAtIndex:i] displayName];
	    [burnerPopup addItemWithTitle:displayName];
    }
    
    NSString *displayName = [[self savedDevice] displayName];
    if ([burnerPopup indexOfItemWithTitle:displayName] > -1)
	    [burnerPopup selectItemAtIndex:[burnerPopup indexOfItemWithTitle:displayName]];
    
    [self updateDevice:[self currentDevice]];

    NSInteger height = 205;
    
    NSArray *combinableTypes = [self combinableTypes];
    NSInteger type = [self type];
    if (type < 3 && [combinableTypes count] > 1 && [combinableTypes containsObject:@(type)])
    {
	    [self prepareTypes];
	    [combineCheckBox setHidden:NO];
    }
    else
    {
	    height = height - 20;
	    [combineCheckBox setHidden:YES];
    }
    
    [myWindow setContentSize:NSMakeSize([myWindow frame].size.width,height)];
    
    DRNotificationCenter *currentCenter = [DRNotificationCenter currentRunLoopCenter];
    [currentCenter addObserver:self selector:@selector(statusChanged:) name:DRDeviceStatusChangedNotification object:nil];
    [currentCenter addObserver:self selector:@selector(mediaChanged:) name:DRDeviceDisappearedNotification object:nil];
    [currentCenter addObserver:self selector:@selector(mediaChanged:) name:DRDeviceAppearedNotification object:nil];
    
    [window beginSheet:myWindow completionHandler:^(NSModalResponse returnCode)
    {
        DRNotificationCenter *currentCenter = [DRNotificationCenter currentRunLoopCenter];
        [currentCenter removeObserver:self name:DRDeviceStatusChangedNotification object:nil];
        [currentCenter removeObserver:self name:DRDeviceDisappearedNotification object:nil];
        [currentCenter removeObserver:self name:DRDeviceAppearedNotification object:nil];

        if (returnCode == NSOKButton)
        {
            //Save the preferences
            NSArray *speeds;
            DRDevice *currentDevice = [self currentDevice];
            NSUserDefaults *standardDefaults = [NSUserDefaults standardUserDefaults];
            
                if (ignoreMode == NO)
                speeds = [[[currentDevice status] objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceBurnSpeedsKey];
            
            NSNumber *speed;

            if ([speedPopup indexOfSelectedItem] == 0 || ignoreMode == YES)
                speed = [NSNumber numberWithFloat:65535];
            else
                speed = [speeds objectAtIndex:[speedPopup indexOfSelectedItem] - 2];

            [standardDefaults setObject:speed forKey:@"DRBurnOptionsBurnSpeed"];

            NSMutableDictionary *burnDict = [[NSMutableDictionary alloc] init];
            NSDictionary *deviceInfo = [currentDevice info];

            [burnDict setObject:[deviceInfo objectForKey:@"DRDeviceProductNameKey"] forKey:@"Product"];
            [burnDict setObject:[deviceInfo objectForKey:@"DRDeviceVendorNameKey"] forKey:@"Vendor"];
            [burnDict setObject:@"" forKey:@"SerialNumber"];

            [standardDefaults setObject:burnDict forKey:@"KWDefaultDeviceIdentifier"];

            [[NSNotificationCenter defaultCenter] postNotificationName:@"KWMediaChanged" object:nil];

            //We're gonna store our setup values for later :-)
            savedDevice = currentDevice;

            NSMutableDictionary *mutableDict = [NSMutableDictionary dictionary];

            //Set speed
            if ([speedPopup indexOfSelectedItem] == 0 && ignoreMode == NO)
                [mutableDict setObject:[speeds objectAtIndex:[speeds count]-1] forKey:DRBurnRequestedSpeedKey];
            else
                [mutableDict setObject:speed forKey:DRBurnRequestedSpeedKey];
            //Set more sessions allowed
            [mutableDict setObject:[NSNumber numberWithBool:([sessionsCheckBox state] == NSOnState)] forKey:DRBurnAppendableKey];
            //Set overwrite / erase before burning
            [mutableDict setObject:[NSNumber numberWithBool:([eraseCheckBox state] == NSOnState)] forKey:DRBurnOverwriteDiscKey];
            //Set should verify from preferences
            [mutableDict setObject:[standardDefaults objectForKey:@"KWBurnOptionsVerifyBurn"] forKey:DRBurnVerifyDiscKey];
            //Set completion action from preferences if one disc
            [mutableDict setObject:[standardDefaults objectForKey:@"KWBurnOptionsCompletionAction"] forKey:DRBurnCompletionActionKey];

            properties = [mutableDict copy];
        }
        
        completion(returnCode);
    }];
}

- (void)burnDiskImageAtPath:(NSString *)path
{
    size = [self getImageSizeAtPath:path];

    if ([self canBurn])
    {
	    burn = [[DRBurn alloc] initWithDevice:savedDevice];
	    [burn setProperties:properties];
	    [[DRNotificationCenter currentRunLoopCenter] addObserver:self selector:@selector(burnNotification:) name:DRBurnStatusChangedNotification object:burn];
	    
        id layout = [DRBurn layoutForImageFile:path];
    
        if (layout != nil)
            [burn writeLayout:layout];
        else
            [[NSNotificationCenter defaultCenter] postNotificationName:@"KWBurnFinished" object:self userInfo:[NSDictionary dictionaryWithObject:@"KWFailure" forKey:@"ReturnCode"]];
    }
    else
    {
	    [[NSNotificationCenter defaultCenter] postNotificationName:@"KWBurnFinished" object:self userInfo:[NSDictionary dictionaryWithObject:@"KWCanceled" forKey:@"ReturnCode"]];
    }
}

- (void)writeTrack:(id)track
{
    BOOL hasTracks = YES;
    id burnTrack = track;
    
    if ([track isKindOfClass:[DRTrack class]])
    {
	    size = [track estimateLength];
    }
    else
    {
	    NSInteger numberOfTracks = [(NSArray *)track count];

	    if (numberOfTracks > 0)
	    {
    	    NSInteger i;
    	    for (i=0;i<numberOfTracks;i++)
    	    {
	    	    id newTrack = [(NSArray *)track objectAtIndex:i];
    	    
	    	    if ([newTrack isKindOfClass:[NSDictionary class]])
	    	    {
    	    	    burnTrack = newTrack;
    	    	    newTrack = [newTrack objectForKey:@"_DRBurnCueLayout"];
	    	    }

	    	    if ([newTrack isKindOfClass:[DRTrack class]])
	    	    {
    	    	    size = size + [(DRTrack *)newTrack estimateLength];
	    	    }
	    	    else
	    	    {
    	    	    NSInteger i;
    	    	    for (i=0;i<[(NSArray *)newTrack count];i++)
    	    	    {
	    	    	    size = size + [[(NSArray *)newTrack objectAtIndex:i] estimateLength];
    	    	    }
	    	    }
    	    }
	    }
	    else
	    {
    	    hasTracks = NO;
	    }
    }
    
    if (hasTracks == NO)
    {
    
	    [[NSNotificationCenter defaultCenter] postNotificationName:@"KWBurnFinished" object:self userInfo:[NSDictionary dictionaryWithObject:@"KWFailure" forKey:@"ReturnCode"]];
    }
    else if ([self canBurn])
    {
	    [burn writeLayout:burnTrack];
	    
	    [[DRNotificationCenter currentRunLoopCenter] addObserver:self selector:@selector(burnNotification:) name:DRBurnStatusChangedNotification object:burn];
     
        [[KWProgressManager sharedManager] setCancelHandler:^
        {
            [[NSOperationQueue mainQueue] addOperationWithBlock:^
            {
                if (isOverwritable)
                {
                    userCanceled = YES;
                    [burn abort];
                }
                else
                {
                    NSAlert *alert = [[NSAlert alloc] init];
                    [alert addButtonWithTitle:NSLocalizedString(@"Continue", Localized)];
                    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", Localized)];
                    [alert setMessageText:NSLocalizedString(@"Are you sure you want to cancel?", Localized)];
                    [alert setInformativeText:NSLocalizedString(@"After canceling the disc can't be used anymore?", Localized)];
                    [alert setAlertStyle:NSWarningAlertStyle];

                    if ([alert runModal] == NSAlertFirstButtonReturn)
                    {
                        userCanceled = YES;
                        [burn abort];
                    }
                }
            }];
        }];
    }
    else
    {
	    [[NSNotificationCenter defaultCenter] postNotificationName:@"KWBurnFinished" object:self userInfo:[NSDictionary dictionaryWithObject:@"KWCanceled" forKey:@"ReturnCode"]];
    }
}

- (void)setLayerBreak:(id)layerBreakIn
{
    layerBreak = layerBreakIn;
}

- (void)burnTrack:(id)track 
{
    burn = [[DRBurn alloc] initWithDevice:savedDevice];
    
    NSMutableDictionary *burnProperties = [[NSMutableDictionary alloc] initWithDictionary:properties copyItems:YES];
    
    if (extraBurnProperties)
	    [burnProperties addEntriesFromDictionary:extraBurnProperties];
    
    [burnProperties setObject:[[NSUserDefaults standardUserDefaults] objectForKey:@"KWSimulateBurn"] forKey:DRBurnTestingKey];
    
    if(layerBreak == nil)
	    layerBreak = [NSNumber numberWithInt:0.5];
    [burnProperties setObject:layerBreak forKey:@"DRBurnDoubleLayerL0DataZoneBlocksKey"];
    
    [burn setProperties:burnProperties];
    [self writeTrack:track];
    
    if ([[savedDevice status] objectForKey:DRDeviceMediaInfoKey])
	    isOverwritable = [[[[savedDevice status] objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceMediaIsOverwritableKey] boolValue];
    else
	    isOverwritable = NO;
}

- (void)burnTrackToImage:(NSDictionary *)dict
{
    NSString *path = [dict objectForKey:@"Path"];
    id track =  [dict objectForKey:@"Track"];
    
    if ([[path pathExtension] isEqualTo:@"cue"])
	    path = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"bin"];
    
    imagePath = [path copy];
    DRCallbackDevice *device = [[DRCallbackDevice alloc] init];
    [device initWithConsumer:self];
    burn = [[DRBurn alloc] initWithDevice:device];
    [self writeTrack:track];
    
    isOverwritable = YES;
}

- (NSInteger)getImageSizeAtPath:(NSString *)path
{
    NSFileManager *defaultManager = [NSFileManager defaultManager];

    if ([[path pathExtension] isEqualTo:@"cue"])
    {
        NSDictionary *attributes = [defaultManager attributesOfItemAtPath:[[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"bin"] error:nil];
	    return (NSInteger)[attributes[NSFileSize] floatValue] / 1024;
    }
    else if ([[path pathExtension] isEqualTo:@"toc"])
    {
	    float appendSize = 0;
	    NSArray *paths = [[KWCommonMethods stringWithContentsOfFile:path] componentsSeparatedByString:@"FILE \""];
	    NSString  *filePath;
    	    
	    NSInteger z;
	    for (z=1;z<[paths count];z++)
	    {
    	    filePath = [[[paths objectAtIndex:z] componentsSeparatedByString:@"\""] objectAtIndex:0];
    	    
    	    if ([[filePath stringByDeletingLastPathComponent] isEqualTo:@""])
	    	    filePath = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:filePath];
            
            NSDictionary *attributes = [defaultManager attributesOfItemAtPath:filePath error:nil];
    	    appendSize = appendSize + [attributes[NSFileSize] floatValue];
	    }
    	    
	    return (NSInteger)appendSize / 1024;
    }
    else
    {
        NSDictionary *attributes = [defaultManager attributesOfItemAtPath:path error:nil];
	    return (NSInteger)[attributes[NSFileSize] floatValue] / 1024;
    }
}

- (void)updateDevice:(DRDevice *)device
{
    if (ignoreMode == YES)
    {
	    [eraseCheckBox setEnabled:YES];
	    [closeButton setEnabled:NO];
	    [sessionsCheckBox setEnabled:YES];
	    [closeButton setTitle:NSLocalizedString(@"Eject", Localized)];
	    [statusText setStringValue:NSLocalizedString(@"Ready to copy", Localized)];
	    [burnButton setEnabled:YES];
    }
    else if ([[[device status] objectForKey:DRDeviceMediaStateKey] isEqualTo:DRDeviceMediaStateMediaPresent])
    {
	    if ([[[[device status] objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceMediaIsBlankKey] boolValue] || [[[[device status] objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceMediaIsAppendableKey] boolValue] || [[[[device status] objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceMediaIsOverwritableKey] boolValue])
	    {
    	    [self populateSpeeds:device];
    	    [speedPopup setEnabled:YES];
	    
    	    NSDictionary *mediaInfo = [[device status] objectForKey:DRDeviceMediaInfoKey];
    	    BOOL erasable = [[mediaInfo objectForKey:DRDeviceMediaIsErasableKey] boolValue];
    	    BOOL appendable = [[mediaInfo objectForKey:DRDeviceMediaIsAppendableKey] boolValue];
    	    BOOL blank = [[mediaInfo objectForKey:DRDeviceMediaIsBlankKey] boolValue];
    	    BOOL isCD = [[mediaInfo objectForKey:DRDeviceMediaClassKey] isEqualTo:DRDeviceMediaClassCD];
    	    
    	    [eraseCheckBox setEnabled:(erasable && appendable && !blank)];
    	    [eraseCheckBox setState:(erasable && !appendable && !blank)];
    	    [sessionsCheckBox setEnabled:isCD];
	    	    
    	    [closeButton setEnabled:YES];
    	    [closeButton setTitle:NSLocalizedString(@"Eject", Localized)];
	    
    	    [statusText setStringValue:NSLocalizedString(@"Ready to burn", Localized)];
	    
    	    [burnButton setEnabled:YES];
	    }
	    else
	    {
    	    [device ejectMedia];
	    }
    }
    else if ([[[device status] objectForKey:DRDeviceMediaStateKey] isEqualTo:DRDeviceMediaStateInTransition])
    {
	    [speedPopup setEnabled:NO];
	    [eraseCheckBox setEnabled:NO];
	    [eraseCheckBox setState:NSOffState];
	    [sessionsCheckBox setEnabled:NO];
	    [closeButton setEnabled:NO];
	    [statusText setStringValue:NSLocalizedString(@"Waiting for the drive...", Localized)];
	    [burnButton setEnabled:NO];
    }
    else if ([[[device status] objectForKey:DRDeviceMediaStateKey] isEqualTo:DRDeviceMediaStateNone])
    {
	    [self populateSpeeds:device];
	    [speedPopup setEnabled:NO];
	    [eraseCheckBox setEnabled:NO];
	    [eraseCheckBox setState:NSOffState];
	    [sessionsCheckBox setEnabled:NO];
    
	    if ([[[device info] objectForKey:DRDeviceLoadingMechanismCanOpenKey] boolValue])
	    {
    	    [closeButton setEnabled:YES];
	    
    	    if ([[[device status] objectForKey:DRDeviceIsTrayOpenKey] boolValue])
	    	    [closeButton setTitle:NSLocalizedString(@"Close", Localized)];
    	    else
	    	    [closeButton setTitle:NSLocalizedString(@"Open", Localized)];
	    }
	    else
	    {
    	    [closeButton setTitle:NSLocalizedString(@"Close", Localized)];
    	    [closeButton setEnabled:NO];
	    }
	    
	    [statusText setStringValue:NSLocalizedString(@"Waiting for a disc to be inserted...", Localized)];
	    [burnButton setEnabled:NO];
    }
}

////////////////////////
// Main Sheet actions //
////////////////////////

#pragma mark -
#pragma mark •• Main Sheet actions

- (IBAction)burnerPopup:(id)sender
{
    DRDevice *currentDevice = [self currentDevice];

    if ([[[currentDevice info] objectForKey:DRDeviceLoadingMechanismCanOpenKey] boolValue])
    {
	    if ([[[currentDevice status] objectForKey:DRDeviceIsTrayOpenKey] boolValue] == NO)
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
    {
	    [[self currentDevice] closeTray];
    }
    
    NSWindow *window = [self window];
    [[window sheetParent] endSheet:window returnCode:NSCancelButton];
    [window orderOut:self];
}

- (IBAction)closeButton:(id)sender
{
    DRDevice *currentDevice = [self currentDevice];
    NSString *closeButtonTitle = [closeButton title];

    if ([closeButtonTitle isEqualTo:NSLocalizedString(@"Eject", Localized)])
    {
	    [currentDevice ejectMedia];
    }
    else if ([closeButtonTitle isEqualTo:NSLocalizedString(@"Close", Localized)])
    {
	    [currentDevice closeTray];
    }
    else if ([closeButtonTitle isEqualTo:NSLocalizedString(@"Open", Localized)])
    {
	    shouldClose = YES;
	    [currentDevice openTray];
    }
}

- (IBAction)burnButton:(id)sender
{
    NSWindow *window = [self window];
    [[window sheetParent] endSheet:window returnCode:NSOKButton];
    [window orderOut:self];
}

- (IBAction)combineSessions:(id)sender
{
    BOOL combineSessionEnabled = [sender state] == NSOnState;
    [self setCombineSessionsEnabled:combineSessionEnabled];

    if (combineSessionEnabled)
    {
	    [NSApp runModalForWindow:sessionsPanel];
    }
}

///////////////////////////
// Session Sheet actions //
///////////////////////////

#pragma mark -
#pragma mark •• Session Sheet actions

- (IBAction)okSession:(id)sender
{
    [self setCombinedDataSessionEnabled:[dataSession state] == NSOnState];
    [self setCombinedAudioSessionEnabled:[audioSession state] == NSOnState];
    [self setCombinedVideoSessionEnabled:[videoSession state] == NSOnState];

    [NSApp stopModal];
    [sessionsPanel orderOut:self];
}

- (IBAction)cancelSession:(id)sender
{
    [NSApp stopModal];
    [sessionsPanel orderOut:self];
    [currentCombineCheckBox setState:NSOffState];
}

//////////////////////////
// Notification actions //
//////////////////////////

#pragma mark -
#pragma mark •• Notification actions

- (void)statusChanged:(NSNotification *)notif
{
    DRDevice *device = [notif object];

    if ([[device displayName] isEqualTo:[burnerPopup title]])
    [self updateDevice:device];
}

- (void)mediaChanged:(NSNotification *)notification
{
    [burnerPopup removeAllItems];
    
    NSArray *devices = [DRDevice devices];

    NSInteger i;
    for (i=0;i< [devices count];i++)
    {
	    [burnerPopup addItemWithTitle:[[devices objectAtIndex:i] displayName]];
    }
    
    NSString *saveDeviceName = [[self savedDevice] displayName];
    
    if ([burnerPopup indexOfItemWithTitle:saveDeviceName] > -1)
    {
	    [burnerPopup selectItemAtIndex:[burnerPopup indexOfItemWithTitle:saveDeviceName]];
    }
    
    [self updateDevice:[self currentDevice]];
}

- (void)burnNotification:(NSNotification*)notification    
{
    NSDictionary *status = [notification userInfo];
    NSString *currentStatusString = [status objectForKey:DRStatusStateKey];
    NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];
    NSString *time = nil;
    NSString *statusString = nil;
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"KWDebug"])
	    NSLog(@"%@", [status description]);
    
    if ([[status objectForKey:DRStatusPercentCompleteKey] floatValue] > 0)
    {
	    if (![currentStatusString isEqualTo:DRStatusStateTrackOpen])
	    {
    	    NSNumber *percent = [status objectForKey:DRStatusPercentCompleteKey];
    	    double currentPercent = [percent doubleValue];
         
            KWProgressManager *progressManager = [KWProgressManager sharedManager];
            [progressManager setMaximumValue:1.0];
            [progressManager setValue:currentPercent];
    	    
    	    if (!imagePath)
    	    {
	    	    float currentSpeed = [[status objectForKey:DRStatusCurrentSpeedKey] floatValue];
	    	    time = [KWCommonMethods formatTime:size / currentSpeed - (size / currentSpeed * currentPercent)];
    	    }
    	    else
    	    {
	    	    time = [NSString stringWithFormat:@"%.0f%@", currentPercent * 100, @"%"];
    	    }
	    }
    }
    else
    {
        [[KWProgressManager sharedManager] setMaximumValue:0.0];
    }
    
    if ([currentStatusString isEqualTo:DRStatusStatePreparing])
    {
	    statusString = NSLocalizedString(@"Preparing...", Localized);
    }
    else if ([currentStatusString isEqualTo:DRStatusStateTrackOpen])
    {
	    if ([[status objectForKey:DRStatusTotalTracksKey] intValue] > 1)
    	    statusString = [NSString stringWithFormat:NSLocalizedString(@"Opening track %ld", nil),[[status objectForKey:DRStatusCurrentTrackKey] longValue]];
	    else
    	    statusString = NSLocalizedString(@"Opening track", Localized);
    }
    else if ([currentStatusString isEqualTo:DRStatusStateTrackWrite])
    {
	    if (time)
	    {
    	    if ([[status objectForKey:DRStatusTotalTracksKey] intValue] > 1)
	    	    statusString = [NSString stringWithFormat:NSLocalizedString(@"Writing track %ld of %ld (%@)", nil), [[status objectForKey:DRStatusCurrentTrackKey] longValue], [[status objectForKey:DRStatusTotalTracksKey] longValue], time];
    	    else
	    	    statusString = [NSString stringWithFormat:NSLocalizedString(@"Writing track (%@)", nil), time];
	    }
    }
    else if ([currentStatusString isEqualTo:DRStatusStateTrackClose])
    {
	    if ([[status objectForKey:DRStatusTotalTracksKey] intValue] > 1)
    	    statusString = [NSString stringWithFormat:NSLocalizedString(@"Closing track %ld of %ld (%@)", nil), [[status objectForKey:DRStatusCurrentTrackKey] longValue], [[status objectForKey:DRStatusTotalTracksKey] longValue], time];
	    else
    	    statusString = [NSString stringWithFormat:NSLocalizedString(@"Closing track (%@)", nil), time];
    }
    else if ([currentStatusString isEqualTo:DRStatusStateSessionClose])
    {
	    statusString = NSLocalizedString(@"Closing session", Localized);
    }
    else if ([currentStatusString isEqualTo:DRStatusStateFinishing])
    {
	    statusString = NSLocalizedString(@"Finishing...", Localized);
    }
    else if ([currentStatusString isEqualTo:DRStatusStateVerifying])
    {
	    statusString = NSLocalizedString(@"Verifying...", Localized);
    }
    else if ([currentStatusString isEqualTo:DRStatusStateDone])
    {
        [[KWProgressManager sharedManager] setCancelHandler:nil];
	    [[DRNotificationCenter currentRunLoopCenter] removeObserver:self name:DRBurnStatusChangedNotification object:[notification object]];
	    
    
	    [[NSNotificationCenter defaultCenter] postNotificationName:@"KWBurnFinished" object:self userInfo:[NSDictionary dictionaryWithObject:@"KWSucces" forKey:@"ReturnCode"]];
    }
    else if ([currentStatusString isEqualTo:DRStatusStateFailed])
    {
        [[KWProgressManager sharedManager] setCancelHandler:nil];
	    [[DRNotificationCenter currentRunLoopCenter] removeObserver:self name:DRBurnStatusChangedNotification object:[notification object]];
	    
	    
	    if (userCanceled)
	    {
    	    [defaultCenter postNotificationName:@"KWBurnFinished" object:self userInfo:[NSDictionary dictionaryWithObject:@"KWCanceled" forKey:@"ReturnCode"]];
	    }
	    else
	    {
    	    NSString *errorString;
	    
    	    if ([[status objectForKey:DRErrorStatusKey] objectForKey:@"DRErrorStatusErrorInfoStringKey"])
	    	    errorString = [[status objectForKey:DRErrorStatusKey] objectForKey:@"DRErrorStatusErrorInfoStringKey"];
    	    else
	    	    errorString = [[status objectForKey:DRErrorStatusKey] objectForKey:DRErrorStatusErrorStringKey];

    	    [defaultCenter postNotificationName:@"KWBurnFinished" object:self userInfo:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:@"KWFailure", errorString,nil] forKeys:[NSArray arrayWithObjects:@"ReturnCode",@"Error",nil]]];
	    }
	    
    }
    
    if (statusString)
    {
        [[KWProgressManager sharedManager] setStatus:statusString];
    }
}

///////////////////
// Image actions //
///////////////////

#pragma mark -
#pragma mark •• Image actions

- (BOOL)writeBlocks:(char*)wBlocks blockCount:(uint32_t)bCount blockSize:(uint32_t)bSize atAddress:(uint64_t)address
{
    NSOutputStream *imageStream = [NSOutputStream outputStreamToFileAtPath:imagePath append:YES];
    [imageStream open];    
    [imageStream write:(const uint8_t *)wBlocks maxLength:bSize * bCount];
    [imageStream close];

    return NO;
}

- (BOOL)prepareBurn:(DRBurn *)burnObject
{
    return NO;
}

- (BOOL)prepareTrack:(id)track trackIndex:(id)index
{
    trackNumber = trackNumber + 1;
    return NO;
}

- (BOOL)prepareSession:(id)session sessionIndex:(id)index
{
    return NO;
}

- (BOOL)cleanupSessionAfterBurn:(id)session sessionIndex:(id)index
{
    return NO;
}

- (BOOL)cleanupAfterBurn:(DRBurn *)burnObject
{
    return NO;
}

- (BOOL)cleanupTrackAfterBurn:(DRTrack *)track trackIndex:(id)index
{
    return NO;
}

///////////////////
// Other actions //
///////////////////

#pragma mark -
#pragma mark •• Other actions

- (void)setIgnoreMode:(BOOL)mode
{
    ignoreMode = mode;
}

- (void)prepareTypes
{
    NSInteger i;
    for (i=0;i< 3;i++)
    {
	    [[sessions cellWithTag:i] setState:NSOffState];
	    
	    if (![[self combinableTypes] containsObject:[NSNumber numberWithInt:i]])
    	    [[sessions cellWithTag:i] setEnabled:NO];
    }
    
    NSInteger type = [self type];
    [[sessions cellWithTag:type] setEnabled:NO];
    [[sessions cellWithTag:type] setState:NSOnState];
}

- (void)setCombineBox:(id)box
{
    currentCombineCheckBox = box;
}

- (DRDevice *)currentDevice
{
    return [[DRDevice devices] objectAtIndex:[burnerPopup indexOfSelectedItem]];
}

- (void)populateSpeeds:(DRDevice *)device
{
    NSDictionary *mediaInfo = [[device status] objectForKey:DRDeviceMediaInfoKey];
    NSArray *speeds = [mediaInfo objectForKey:DRDeviceBurnSpeedsKey];
    
    [speedPopup removeAllItems];

    if ([speeds count] > 0)
    {
	    float speed;
    
	    NSInteger z;
	    for (z=0;z<[speeds count];z++)
	    {
    	    speed = [[speeds objectAtIndex:z] floatValue];
	    
    	    if ([[mediaInfo objectForKey:DRDeviceMediaClassKey] isEqualTo:DRDeviceMediaClassCD])
	    	    speed = speed / DRDeviceBurnSpeedCD1x;
    	    else
	    	    speed = speed / DRDeviceBurnSpeedDVD1x;

    	    [speedPopup addItemWithTitle:[NSString stringWithFormat:@"%.0fx", speed]];
	    }

    [speedPopup insertItemWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Maximum Possible (%.0fx)", nil), speed] atIndex:0];
    [[speedPopup menu] insertItem:[NSMenuItem separatorItem] atIndex:1];


	    NSNumber *burnSpeed = [[NSUserDefaults standardUserDefaults] objectForKey:@"DRBurnOptionsBurnSpeed"];
	    
	    if (!burnSpeed)
	    {
    	    if ([speeds containsObject:burnSpeed])
    	    {
	    	    [speedPopup selectItemAtIndex:[speeds indexOfObject:burnSpeed] + 2];
    	    }
    	    else
    	    {
	    	    [speedPopup selectItemAtIndex:0];
    	    }
	    }
	    else
	    {
    	    [speedPopup selectItemAtIndex:0];
	    }
    }
    else
    {
	    [speedPopup addItemWithTitle:NSLocalizedString(@"Maximum Possible", Localized)];
    }
}

- (DRDevice *)savedDevice
{
    NSArray *devices = [DRDevice devices];
    
    NSInteger i;
    for (i=0;i< [devices count];i++)
    {
	    DRDevice *device = [devices objectAtIndex:i];
    
	    if ([[[device info] objectForKey:@"DRDeviceProductNameKey"] isEqualTo:[[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"KWDefaultDeviceIdentifier"] objectForKey:@"Product"]])
	    {
    	    return device;
	    }
    }
    
    return [devices objectAtIndex:0];
}

- (BOOL)canBurn
{
    if (imagePath)
	    return YES;

    NSInteger space;
    NSDictionary *mediaInfo = [[savedDevice status] objectForKey:DRDeviceMediaInfoKey];

    if ([[mediaInfo objectForKey:DRDeviceMediaIsBlankKey] boolValue])
    {
	    space = [[mediaInfo objectForKey:DRDeviceMediaFreeSpaceKey] floatValue];
    }
    else if ([[mediaInfo objectForKey:DRDeviceMediaClassKey] isEqualTo:DRDeviceMediaClassDVD])
    {
	    space = [[mediaInfo objectForKey:DRDeviceMediaOverwritableSpaceKey] floatValue];
    }
    else
    {
	    space = (NSInteger)[KWCommonMethods defaultSizeForMedia:@"KWDefaultCDMedia"];
    }
	    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"KWAllowOverBurning"])
    {
	    return YES;
    }
    else if (space < size)
    {
	    NSAlert *alert = [[NSAlert alloc] init];
	    [alert addButtonWithTitle:NSLocalizedString(@"Burn", Localized)];
	    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", Localized)];
	    [alert setMessageText:NSLocalizedString(@"Not enough space", Localized)];
	    [alert setInformativeText:NSLocalizedString(@"Still try to burn the disc?", Localized)];
	    [alert setAlertStyle:NSWarningAlertStyle];
	    
	    return ([alert runModal] == NSAlertFirstButtonReturn);
    }
    else
    {
	    return YES;
    }
}

- (BOOL)isCD
{
return [[[[savedDevice status] objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceMediaClassKey] isEqualTo:DRDeviceMediaClassCD];
}

- (void)setType:(NSInteger)type
{
    _type = type;
    
    if (_combinableTypes == nil)
    {
        _combinableTypes = @[@(_type)];
    }
}

- (void)setCombinableTypes:(NSArray *)types
{
    _combinableTypes = types;
}

- (NSArray *)types
{
    if ([self isCombineSessionsEnabled])
    {
        NSMutableArray *types = [NSMutableArray array];
        
        if ([self isCombinedDataSessionEnabled])
        {
            [types addObject:[NSNumber numberWithInt:0]];
        }
        
        if ([self isCombinedAudioSessionEnabled])
        {
            [types addObject:[NSNumber numberWithInt:1]];
        }
        
        if ([self isCombinedVideoSessionEnabled])
        {
            [types addObject:[NSNumber numberWithInt:2]];
        }
        
        return types;
    }
    else
    {
        return [NSArray arrayWithObject:[NSNumber numberWithInt:[self type]]];
    }
}

- (void)addBurnProperties:(NSDictionary *)burnProperties
{
    extraBurnProperties = burnProperties;
}

- (NSDictionary *)properties
{
    return properties;
}

@end
