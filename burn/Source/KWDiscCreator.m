//
//  KWDiscCreator.m
//  Burn
//
//  Created by Maarten Foukhar on 15-11-08.
//  Copyright 2009 Kiwi Fruitware. All rights reserved.
//

#import "KWDiscCreator.h"
#import "KWDataController.h"
#import "KWAudioController.h"
#import "KWVideoController.h"
#import "KWCopyController.h"
#import "KWCommonMethods.h"
#import "KWTrackProducer.h"
#import "KWSVCDImager.h"
#import "KWAlert.h"

@interface KWDiscCreator()

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *fileSystem;

@end

@implementation KWDiscCreator

- (id)init
{
    self = [super init];

    burner = nil;
    
    return self;
}

//////////////////////
// Sessions actions //
//////////////////////

#pragma mark -
#pragma mark •• Sessions actions

- (IBAction)saveCombineSessions:(id)sender
{
    [burner combineSessions:sender];
}

///////////////////
// Image actions //
///////////////////

#pragma mark -
#pragma mark •• Image actions

- (void)saveImageWithName:(NSString *)name withType:(NSInteger)type withFileSystem:(NSString *)fileSystem
{
    NSString *extension;
    NSArray *info;
    [self setName:name];
    [self setFileSystem:fileSystem];
    
    if ([fileSystem isEqualTo:@"-vcd"] || [fileSystem isEqualTo:@"-svcd"] || [fileSystem isEqualTo:@"-audio-cd"])
	    extension = @"cue";
    else
	    extension = @"iso";

    //Setup save sheet
    NSSavePanel *sheet = [NSSavePanel savePanel];
    [sheet setMessage:NSLocalizedString(@"Choose a location to save the image file",nil)];
    [sheet setAllowedFileTypes:@[extension]];
    [sheet setCanSelectHiddenExtension:YES];
    [sheet setNameFieldStringValue:name];
    [saveCombineSessions setState:NSOffState];

    if (type < 4)
    {
	    //Setup image burner
	    burner = [[KWBurner alloc] init];
	    [burner setType:type];
    
	    //Setup combining options
	    NSArray *types = [self getCombinableFormats:YES];

	    if ([types count] > 1 && [types containsObject:[NSNumber numberWithInt:type]])
	    {
    	    [burner setCombinableTypes:types];
    	    [burner prepareTypes];
    	    [burner setCombineBox:saveCombineSessions];
    	    [sheet setAccessoryView:saveImageView];
	    }
    
	    info = [[NSArray alloc] initWithObjects:name, nil];
    }
    else
    {
	    info = [[NSArray alloc] initWithObjects:name, fileSystem, nil];
    }
    
    //Show save sheet
    [sheet beginSheetModalForWindow:mainWindow completionHandler:^(NSModalResponse result)
    {
         if (result == NSModalResponseOK)
        {
            imagePath = [[NSString alloc] initWithString:[[sheet URL] path]];
            
            KWProgressManager *progressManager = [KWProgressManager sharedManager];
            [progressManager setTask:NSLocalizedString(@"Creating image file",nil)];
            [progressManager setStatus:NSLocalizedString(@"Preparing...",nil)];
            [progressManager setIconImage:[[NSWorkspace sharedWorkspace] iconForFileType:[imagePath pathExtension]]];
            [progressManager setMaximumValue:0.0];
            [progressManager beginSheetForWindow:mainWindow];
            
            if ([info count] == 1)
            {
                [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(imageFinished:) name:@"KWBurnFinished" object:burner];
                hiddenExtension = [sheet isExtensionHidden];
                [NSThread detachNewThreadSelector:@selector(burnTracks) toTarget:self withObject:nil];
            }
            else
            {
                [NSThread detachNewThreadSelector:@selector(createImage:) toTarget:self withObject:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:imagePath, [self name], [self fileSystem],[NSNumber numberWithBool:[sheet isExtensionHidden]], nil] forKeys:[NSArray arrayWithObjects:@"Path", @"Filesystem", @"Name", @"Hidden Extension", nil]]];
            }
        }
    }];
}

- (void)createImage:(NSDictionary *)dict
{
    NSInteger success = 0;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(imageFinished:) name:@"KWBurnFinished" object:burner];
    
    KWSVCDImager *SVCDImager = [[KWSVCDImager alloc] init];
    NSString *anErrorString;
    success = [SVCDImager createSVCDImage:[[dict objectForKey:@"Path"] stringByDeletingPathExtension] withFiles:[videoControllerOutlet files] withLabel:[self name] createVCD:[[dict objectForKey:@"Filesystem"] isEqualTo:@"-vcd"] hideExtension:[dict objectForKey:@"Hidden Extension"] errorString:&anErrorString];
    errorString = anErrorString;
    
    if (success == 0)
	    [self imageFinished:@"KWSucces"];
    else if (success == 1)
	    [self imageFinished:@"KWFailure"];
    else
	    [self imageFinished:@"KWCanceled"];
}

- (void)showAuthorFailedOfType:(NSInteger)type
{    
    [[KWProgressManager sharedManager] endSheetWithCompletion:^
    {
        KWAlert *alert = [[KWAlert alloc] init];
        [alert addButtonWithTitle:NSLocalizedString(@"OK",nil)];
        
        if (type == 0)
            [alert setMessageText:NSLocalizedString(@"Failed to create temporary folder",nil)];
        else
            [alert setMessageText:NSLocalizedString(@"Authoring failed",nil)];
        
        if (type < 3)
            [alert setInformativeText:NSLocalizedString(@"There was a problem authoring the DVD",nil)];
        else
            [alert setInformativeText:NSLocalizedString(@"There was a problem copying the disc",nil)];
        
        if ([errorString rangeOfString:@"KWConsole:"].length > 0)
            [alert setDetails:errorString];
        else
            [alert setInformativeText:errorString];
        
        [alert setAlertStyle:NSWarningAlertStyle];
        
        [alert beginSheetModalForWindow:mainWindow modalDelegate:self didEndSelector:nil contextInfo:nil];
    }];
}

- (void)imageFinished:(id)object
{
    if (extensionHiddenArray)
    {
        // TODO: change something, do at least not use a dictionary since they're pretty prone to errors
	    for (NSDictionary *hideFileExtensionInfo in extensionHiddenArray)
	    {
            NSNumber *hideFileExtension = hideFileExtensionInfo[@"Extension Hidden"];
            NSString *path = hideFileExtensionInfo[@"Path"];
    	    [[NSFileManager defaultManager] setAttributes:@{NSFileExtensionHidden: hideFileExtension} ofItemAtPath:path error:nil];
        }
	    
	    extensionHiddenArray = nil;
    }

    NSString *returnCode;
    if ([object superclass] == [NSNotification class])
	    returnCode = [[object userInfo] objectForKey:@"ReturnCode"];
    else
	    returnCode = object;

    if (!isBurning || [returnCode isEqualTo:@"KWCanceled"])
    {
	    [[KWProgressManager sharedManager] endSheet];
    }
    
    if ([returnCode isEqualTo:@"KWSucces"])
    {
	    if ([[imagePath pathExtension] isEqualTo:@"cue"] && burner)
    	    [KWCommonMethods writeString:[audioControllerOutlet cueStringWithBinFile:[[[imagePath lastPathComponent] stringByDeletingPathExtension] stringByAppendingPathExtension:@"bin"]] toFile:imagePath errorString:nil];
        
        // TODO: why???
        [[NSOperationQueue mainQueue] addOperationWithBlock:^
        {
            if ([[[mainTabView selectedTabViewItem] identifier] isEqualTo:@"Copy"])
            {
                [copyControllerOutlet remount:nil];
            
                NSDictionary *infoDict = [copyControllerOutlet isoInfo];
                
                if (infoDict)
                    [infoDict writeToFile:[[imagePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"isoInfo"] atomically:YES];
            }
        }];
	    
        NSImage *image = [[NSWorkspace sharedWorkspace] iconForFileType:@".iso"];
        [[self windowController] showNotificationWithTitle:NSLocalizedString(@"Image created", nil) withMessage:NSLocalizedString(@"Succesfully created a disk image", nil) withImage:image];
    }
    else if ([returnCode isEqualTo:@"KWFailure"])
    {
	    if (burner)
        {
    	    [KWCommonMethods removeItemAtPath:imagePath];
        }
        
        NSString *message = [NSString stringWithFormat:NSLocalizedString(@"Failed to create '%@'", nil), [[NSFileManager defaultManager] displayNameAtPath:imagePath]];
        NSImage *image = [[NSWorkspace sharedWorkspace] iconForFileType:@".iso"];
        [[self windowController] showNotificationWithTitle:NSLocalizedString(@"Image failed", nil) withMessage:message withImage:image];
        
        [[KWProgressManager sharedManager] endSheetWithCompletion:^
        {
            KWAlert *alert = [[KWAlert alloc] init];
            [alert addButtonWithTitle:NSLocalizedString(@"OK",nil)];
            [alert setMessageText:NSLocalizedString(@"Image failed",nil)];
            [alert setAlertStyle:NSWarningAlertStyle];
            
            // TODO: why can be empty
            if (burner && [object userInfo][@"Error"])
                [alert setInformativeText:[[object userInfo] objectForKey:@"Error"]];
            else
                [alert setInformativeText:NSLocalizedString(@"There was a problem creating the image",nil)];
        
            
            if ([errorString rangeOfString:@"KWConsole:"].length > 0)
                [alert setDetails:errorString];
            else
                [alert setInformativeText:errorString == nil ? NSLocalizedString(@"There was a problem creating the image",nil) : errorString];
            
            [alert beginSheetModalForWindow:mainWindow modalDelegate:self didEndSelector:nil contextInfo:nil];
        }];
    }
    else if ([returnCode isEqualTo:@"KWCanceled"])
    {
	    if (burner)
    	    [KWCommonMethods removeItemAtPath:imagePath];
    }
    
    if (burner)
    {
	    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"KWBurnFinished" object:burner];
    }
    else
    {
	    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"KWImagerFinished" object:nil];
    }

    imagePath = nil;
    
    // TODO: Since it's always yes, just delete files when needed
    [dataControllerOutlet deleteTemporayFiles:YES];
    [audioControllerOutlet deleteTemporayFiles:YES];
    [videoControllerOutlet deleteTemporayFiles:YES];
    [copyControllerOutlet deleteTemporayFiles:YES];
}

//////////////////
// Burn actions //
//////////////////

#pragma mark -
#pragma mark •• Burn actions

- (void)burnDiscWithName:(NSString *)name withType:(NSInteger)type
{
    burner = [[KWBurner alloc] init];
    
    [self setName:name];

    //Check if the user wants to copy the disc in the burning device
    [burner setIgnoreMode:(type == 3 && [[[KWCommonMethods savedDevice] status] objectForKey:DRDeviceMediaInfoKey] && [[copyControllerOutlet myDisc] isEqualTo:[@"/dev/" stringByAppendingString:[[[[KWCommonMethods savedDevice] status] objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceMediaBSDNameKey]]])];

    [burner setType:type];
    [burner setCombinableTypes:[self getCombinableFormats:NO]];
    [burner beginBurnSetupSheetForWindow:mainWindow completion:^(NSModalResponse returnCode)
    {
        if (returnCode == NSModalResponseOK)
        {
            if ((([copyControllerOutlet isCueFile] || ([copyControllerOutlet isAudioCD] && [[[mainTabView selectedTabViewItem] identifier] isEqualTo:@"Copy"])) || ([audioControllerOutlet isAudioCD] && [[[mainTabView selectedTabViewItem] identifier] isEqualTo:@"Audio"])) && ![burner isCD])
            {
                NSAlert *alert = [[NSAlert alloc] init];
                [alert addButtonWithTitle:NSLocalizedString(@"OK",nil)];
                [alert setMessageText:NSLocalizedString(@"No CD",nil)];
                [alert setAlertStyle:NSWarningAlertStyle];
                
                if ([copyControllerOutlet isCueFile])
                    [alert setInformativeText:NSLocalizedString(@"A cue/bin file needs to be burned on a CD",nil)];
                else
                    [alert setInformativeText:NSLocalizedString(@"To burn a Audio-CD the media should be a CD",nil)];
            
                [alert beginSheetModalForWindow:mainWindow modalDelegate:self didEndSelector:nil contextInfo:nil];
            }
            else
            {
                KWProgressManager *progressManager = [KWProgressManager sharedManager];
                [progressManager setIconImage:[NSImage imageNamed:@"Burn"]];
                [progressManager setTask:[NSString stringWithFormat:NSLocalizedString(@"Burning '%@'", nil), [self name]]];
                [progressManager setStatus:NSLocalizedString(@"Preparing...",nil)];
                [progressManager setMaximumValue:0.0];
                [progressManager beginSheetForWindow:mainWindow];
                
                [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(burnFinished:) name:@"KWBurnFinished" object:burner];
                [NSThread detachNewThreadSelector:@selector(burnTracks) toTarget:self withObject:nil];
            }
        }
    }];
}

- (void)burnTracks
{
    NSMutableArray *tracks = [NSMutableArray array];
    NSInteger result = 0;
    BOOL maskSet = NO;
    NSNumber *layerBreak = nil;

    DRFolder *rootFolder = [[DRFolder alloc] initWithName:[self name]];
    [rootFolder setExplicitFilesystemMask:0];

    if ([[burner types] containsObject:[NSNumber numberWithInt:1]])
    {
        NSString *anErrorString;
	    id audioTracks = [audioControllerOutlet myTrackWithBurner:burner errorString:&anErrorString];
        errorString = anErrorString;
	    
	    if (audioTracks)
	    {
    	    if ([audioTracks isKindOfClass:[DRFSObject class]])
    	    {
	    	    [rootFolder setExplicitFilesystemMask:([audioTracks explicitFilesystemMask])];
	    	    maskSet = YES;
    	    	    
	    	    if ([audioTracks isVirtual])
	    	    {
    	    	    NSInteger x;
    	    	    for (x=0;x<[[audioTracks children] count];x++)
    	    	    {
	    	    	    [rootFolder addChild:[self newDRFSObject:(DRFSObject *)[[audioTracks children] objectAtIndex:x]]];
    	    	    }
	    	    }
	    	    else
	    	    {
    	    	    [rootFolder addChild:[self newDRFSObject:audioTracks]];
	    	    }
    	    }
    	    else if ([audioTracks isKindOfClass:[NSNumber class]])
    	    {
	    	    result = [audioTracks intValue];
    	    }
    	    else if ([audioTracks isKindOfClass:[NSArray class]])
    	    {
	    	    [tracks addObjectsFromArray:audioTracks];
    	    }
    	    else
    	    {
	    	    [tracks addObject:audioTracks];
    	    }
	    }
    }
    
    if ([[burner types] containsObject:[NSNumber numberWithInt:2]] && result == 0)
    {
        NSString *anErrorString;
	    id videoTracks = [videoControllerOutlet myTrackWithBurner:burner errorString:&anErrorString];
        errorString = anErrorString;

	    if (videoTracks)
	    {
    	    if ([videoTracks isKindOfClass:[DRFSObject class]])
    	    {
	    	    if (maskSet)
	    	    {
    	    	    [rootFolder setExplicitFilesystemMask:([rootFolder explicitFilesystemMask] || [videoTracks explicitFilesystemMask])];
	    	    }
	    	    else
	    	    {
    	    	    [rootFolder setExplicitFilesystemMask:([videoTracks explicitFilesystemMask])];
    	    	    maskSet = YES;
	    	    }
    	    	    
	    	    if ([videoTracks isVirtual])
	    	    {
    	    	    NSInteger x;
    	    	    for (x=0;x<[[videoTracks children] count];x++)
    	    	    {
	    	    	    [rootFolder addChild:[self newDRFSObject:(DRFSObject *)[[videoTracks children] objectAtIndex:x]]];
    	    	    }
	    	    }
	    	    else
	    	    {
    	    	    [rootFolder addChild:[self newDRFSObject:videoTracks]];
	    	    }
    	    }
    	    else if ([videoTracks isKindOfClass:[NSNumber class]])
    	    {
	    	    result = [videoTracks intValue];
    	    }
    	    else if ([videoTracks isKindOfClass:[NSArray class]])
    	    {
	    	    [tracks addObjectsFromArray:videoTracks];
    	    }
    	    else
    	    {
	    	    [tracks addObject:videoTracks];
    	    }
	    }
    }

    if ([[burner types] containsObject:[NSNumber numberWithInt:0]] && result == 0)
    {
        NSString *anErrorString;
	    id dataTracks = [dataControllerOutlet myTrackWithErrorString:&anErrorString];
        errorString = anErrorString;
    
	    if ([dataTracks isKindOfClass:[DRFSObject class]])
	    {
    	    if (maskSet)
    	    {
	    	    [rootFolder setExplicitFilesystemMask:([rootFolder explicitFilesystemMask] || [dataTracks explicitFilesystemMask])];
    	    }
    	    else
    	    {
	    	    [rootFolder setExplicitFilesystemMask:([dataTracks explicitFilesystemMask])];
	    	    maskSet = YES;
    	    }
    	    
    	    if ([dataTracks isVirtual])
    	    {
	    	    if ([KWCommonMethods fsObjectContainsHFS:dataTracks])
	    	    {
    	    	    extensionHiddenArray = [[NSMutableArray alloc] init];
	    	    }
    	    
	    	    NSInteger x;
	    	    for (x=0;x<[[dataTracks children] count];x++)
	    	    {
    	    	    if ([[(DRFSObject *)[[dataTracks children] objectAtIndex:x] baseName] isEqualTo:@".VolumeIcon.icns"])
	    	    	    [rootFolder setProperty:[NSNumber numberWithUnsignedShort:1024] forKey:DRMacFinderFlags inFilesystem:DRHFSPlus];
	    	    
    	    	    [rootFolder addChild:[self newDRFSObject:(DRFSObject *)[[dataTracks children] objectAtIndex:x]]];
	    	    }
    	    }
    	    else
    	    {
	    	    [rootFolder addChild:[self newDRFSObject:dataTracks]];
    	    }
	    }
	    else if ([dataTracks isKindOfClass:[NSNumber class]])
	    {
    	    result = [dataTracks intValue];
	    }
	    else if ([dataTracks isKindOfClass:[NSArray class]])
	    {
    	    [tracks addObjectsFromArray:dataTracks];
	    }
	    else
	    {
    	    [tracks addObject:dataTracks];
	    }
    }
    
    if ([[burner types] containsObject:[NSNumber numberWithInt:3]] && result == 0)
    {
        NSString *anErrorString;
	    id copyTracks = [copyControllerOutlet myTrackWithErrorString:&anErrorString andLayerBreak:&layerBreak];
        errorString = anErrorString;
    
	    if ([copyTracks isKindOfClass:[NSNumber class]])
    	    result = [copyTracks intValue];
	    else if ([copyTracks isKindOfClass:[NSArray class]])
    	    [tracks addObjectsFromArray:copyTracks];
	    else
    	    [tracks addObject:copyTracks];
    }

    if (result == 0)
    {
	    if (maskSet)
    	    [tracks addObject:[DRTrack trackForRootFolder:rootFolder]];

	    if (imagePath)
	    {
            KWProgressManager *progressManager = [KWProgressManager sharedManager];
            [progressManager setMaximumValue:0.0];
    	    [progressManager setTask:[NSString stringWithFormat:NSLocalizedString(@"Creating image file '%@'", nil), [[NSFileManager defaultManager] displayNameAtPath:imagePath]]];
    	    [progressManager setStatus:NSLocalizedString(@"Preparing...",nil)];
    	    
            NSString *anErrorString;
    	    if ([KWCommonMethods createFileAtPath:imagePath attributes:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:hiddenExtension], NSFileExtensionHidden,nil] errorString:&anErrorString])
    	    {    
	    	    [burner performSelectorOnMainThread:@selector(burnTrackToImage:) withObject:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:imagePath, tracks, nil] forKeys:[NSArray arrayWithObjects:@"Path",@"Track",nil]] waitUntilDone:YES];
    	    }
    	    else
    	    {
	    	    burner = nil;
	    	    [self performSelectorOnMainThread:@selector(imageFinished:) withObject:@"KWFailure" waitUntilDone:YES];
    	    }
            errorString = anErrorString;
	    }
	    else
	    {
            KWProgressManager *progressManager = [KWProgressManager sharedManager];
            [progressManager setMaximumValue:0.0];
            [progressManager setCancelHandler:^
            {
                [self stopWaiting];
            }];
    	    
            shouldWait = YES;

            
	    
    	    if ([self waitForMediaIfNeeded] == YES)
    	    {
                KWProgressManager *progressManager = [KWProgressManager sharedManager];
                [progressManager setCancelHandler:nil];
	    	    [progressManager setTask:[NSString stringWithFormat:NSLocalizedString(@"Burning '%@'", nil), [self name]]];
	    	    [progressManager setStatus:NSLocalizedString(@"Preparing...",nil)];
	    	    [burner performSelectorOnMainThread:@selector(setLayerBreak:) withObject:layerBreak waitUntilDone:YES];
	    	    [burner performSelectorOnMainThread:@selector(burnTrack:) withObject:tracks waitUntilDone:YES];
    	    }
    	    else
    	    {
	    	    [[KWProgressManager sharedManager] endSheet];
    	    }
	    
    	    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"KWStopWaiting" object:nil];
	    
    	    shouldWait = NO;
	    }
    }
    else if (result == 1)
    {
	    [self showAuthorFailedOfType:[burner type]];
    }
    else
    {
	    [[KWProgressManager sharedManager] endSheet];
	    imagePath = nil;
    }
}

- (void)burnFinished:(NSNotification*)notif
{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"KWDoneBurning" object:nil];

    if (extensionHiddenArray)
    {
	    // TODO: change something, do at least not use a dictionary since they're pretty prone to errors
        for (NSDictionary *hideFileExtensionInfo in extensionHiddenArray)
        {
            NSNumber *hideFileExtension = hideFileExtensionInfo[@"Extension Hidden"];
            NSString *path = hideFileExtensionInfo[@"Path"];
            [[NSFileManager defaultManager] setAttributes:@{NSFileExtensionHidden: hideFileExtension} ofItemAtPath:path error:nil];
        }
	    extensionHiddenArray = nil;
    }

    isBurning = NO;

    NSString *returnCode = [[notif userInfo] objectForKey:@"ReturnCode"];

    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"KWBurnFinished" object:burner];
    
    if ([returnCode isEqualTo:@"KWSucces"])
    {
        [[KWProgressManager sharedManager] endSheet];
        
        NSString *messageName = [NSString stringWithFormat:NSLocalizedString(@"'%@' was burned succesfully", nil), [self name]];
        NSImage *image = [[NSWorkspace sharedWorkspace] iconForFileType:NSFileTypeForHFSTypeCode(kGenericCDROMIcon)];
        [[self windowController] showNotificationWithTitle:NSLocalizedString(@"Finished burning", nil) withMessage:messageName withImage:image];
    }
    else if ([returnCode isEqualTo:@"KWFailure"])
    {
        NSString *messageName = [NSString stringWithFormat:NSLocalizedString(@"Failed to burn '%@'", nil), [self name]];
        NSImage *image = [[NSWorkspace sharedWorkspace] iconForFileType:NSFileTypeForHFSTypeCode(kGenericCDROMIcon)];
        [[self windowController] showNotificationWithTitle:NSLocalizedString(@"Burning failed", nil) withMessage:messageName withImage:image];
     
        [[KWProgressManager sharedManager] endSheetWithCompletion:^
        {
            KWAlert *alert = [[KWAlert alloc] init];
            [alert addButtonWithTitle:NSLocalizedString(@"OK",nil)];
            [alert setMessageText:NSLocalizedString(@"Burning failed",nil)];
            [alert setInformativeText:[[notif userInfo] objectForKey:@"Error"]];
            [alert setAlertStyle:NSWarningAlertStyle];
            [alert setDetails:errorString];
        
            [alert beginSheetModalForWindow:mainWindow modalDelegate:self didEndSelector:nil contextInfo:nil];
        }];
    }
    
    // TODO: Since it's always yes, just delete files when needed
    [dataControllerOutlet deleteTemporayFiles:YES];
    [audioControllerOutlet deleteTemporayFiles:YES];
    [videoControllerOutlet deleteTemporayFiles:YES];
    [copyControllerOutlet deleteTemporayFiles:YES];
}

///////////////////
// Other actions //
///////////////////

#pragma mark -
#pragma mark •• Other actions

- (NSArray *)getCombinableFormats:(BOOL)needAudioCDCheck
{
    NSMutableArray *formats = [NSMutableArray array];

    if ([dataControllerOutlet isCombinable] && ([dataControllerOutlet isOnlyHFSPlus] || (![audioControllerOutlet isAudioCD] || needAudioCDCheck)))
	    [formats addObject:[NSNumber numberWithInt:0]];
    
    if ([audioControllerOutlet isCombinable])
	    [formats addObject:[NSNumber numberWithInt:1]];
    
    if ([videoControllerOutlet isCombinable] && (![audioControllerOutlet isAudioCD] || needAudioCDCheck))
	    [formats addObject:[NSNumber numberWithInt:2]];

    return formats;
}

- (DRFSObject *)newDRFSObject:(DRFSObject *)object
{
    DRFSObject *newObject;
	    
    if ([object isVirtual])
    {
        newObject = [DRFolder virtualFolderWithName:[object baseName]];
    
        NSInteger x;
        for (x=0;x<[[(DRFolder *)object children] count];x++)
        {
            [(DRFolder *)newObject addChild:[self newDRFSObject:[[(DRFolder *)object children] objectAtIndex:x]]];
        }
    }
    else
    {
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[object sourcePath] error:nil];
        NSNumber *isExtensionHiddenNumber = attributes[NSFileExtensionHidden];
        
        [object setProperty:[isExtensionHiddenNumber boolValue] ? @(0x0010) : @(0) forKey:DRMacFinderFlags inFilesystem:DRHFSPlus];
 
        BOOL isDir;
        [[NSFileManager defaultManager] fileExistsAtPath:[object sourcePath] isDirectory:&isDir];
    
        if (isDir)
        {
            newObject = [DRFolder folderWithPath:[object sourcePath]];
        }
        else
        {
            if (extensionHiddenArray)
            {
                [extensionHiddenArray addObject:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:[object sourcePath], isExtensionHiddenNumber,nil] forKeys:[NSArray arrayWithObjects:@"Path",@"Extension Hidden",nil]]];
            }
            
            newObject = [DRFile fileWithPath:[object sourcePath]];
        }
        
        [newObject setBaseName:[object baseName]];
    }
	    
    [newObject setExplicitFilesystemMask:[object explicitFilesystemMask]];
    
    NSString *name = [object specificNameForFilesystem:DRHFSPlus];
    if (name != nil)
    {
        [newObject setSpecificName:name forFilesystem:DRHFSPlus];
    }
    name = [object specificNameForFilesystem:DRISO9660];
    if (name != nil)
    {
        [newObject setSpecificName:name forFilesystem:DRISO9660];
    }
    name = [object specificNameForFilesystem:DRJoliet];
    if (name != nil)
    {
        [newObject setSpecificName:name forFilesystem:DRJoliet];
    }
    name = [object specificNameForFilesystem:DRUDF];
    if (name != nil)
    {
        [newObject setSpecificName:name forFilesystem:DRUDF];
    }
    
    NSDictionary *properties = [object propertiesForFilesystem:DRHFSPlus mergeWithOtherFilesystems:NO];
    if (properties != nil)
    {
        [newObject setProperties:properties inFilesystem:DRHFSPlus];
    }
    properties = [object propertiesForFilesystem:DRISO9660 mergeWithOtherFilesystems:NO];
    if (properties != nil)
    {
        [newObject setProperties:properties inFilesystem:DRISO9660];
    }
    properties = [object propertiesForFilesystem:DRJoliet mergeWithOtherFilesystems:NO];
    if (properties != nil)
    {
        [newObject setProperties:properties inFilesystem:DRJoliet];
    }
    properties = [object propertiesForFilesystem:DRUDF mergeWithOtherFilesystems:NO];
    if (properties != nil)
    {
        [newObject setProperties:properties inFilesystem:DRUDF];
    }

    return newObject;
}

- (BOOL)waitForMediaIfNeeded
{
    BOOL correctMedia = ![[[[KWCommonMethods savedDevice] status] objectForKey:DRDeviceMediaStateKey] isEqualTo:DRDeviceMediaStateNone];

    while (correctMedia == NO && shouldWait == YES)
    {
	    if ([[[[KWCommonMethods savedDevice] status] objectForKey:DRDeviceMediaStateKey] isEqualTo:DRDeviceMediaStateMediaPresent])
	    {
    	    if ([[[[[KWCommonMethods savedDevice] status] objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceMediaIsBlankKey] boolValue] || [[[[[KWCommonMethods savedDevice] status] objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceMediaIsAppendableKey] boolValue] || ([[[[[KWCommonMethods savedDevice] status] objectForKey:DRDeviceMediaInfoKey] objectForKey:DRDeviceMediaIsOverwritableKey] boolValue] && [[[burner properties] objectForKey:DRBurnOverwriteDiscKey] boolValue]))
	    	    return YES;
    	    else
	    	    [[KWCommonMethods savedDevice] ejectMedia];
	    }
	    else if ([[[[KWCommonMethods savedDevice] status] objectForKey:DRDeviceMediaStateKey] isEqualTo:DRDeviceMediaStateInTransition])
	    {
    	    [[KWProgressManager sharedManager] setStatus:NSLocalizedString(@"Waiting for the drive...", Localized)];
	    }
	    else if ([[[[KWCommonMethods savedDevice] status] objectForKey:DRDeviceMediaStateKey] isEqualTo:DRDeviceMediaStateNone])
	    {
    	    [[KWProgressManager sharedManager] setStatus:NSLocalizedString(@"Waiting for a disc to be inserted...", Localized)];
	    }
    }
    
    if (shouldWait == NO)
	    return NO;
    
    return YES;
}

- (void)stopWaiting
{
    shouldWait = NO;
}

@end
