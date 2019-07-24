#import "KWDiscInfo.h"
#import "KWCommonMethods.h"

@interface KWDiscInfo()

@property (nonatomic, weak) IBOutlet NSPopUpButton *recorderPopUp;
@property (nonatomic, weak) IBOutlet NSTextField *kindTextField;
@property (nonatomic, weak) IBOutlet NSTextField *freeSpaceTextField;
@property (nonatomic, weak) IBOutlet NSTextField *usedSpaceTextField;
@property (nonatomic, weak) IBOutlet NSTextField *writableTextField;

@property (nonatomic, strong) NSDictionary *discTypeMappings;

@end

@implementation KWDiscInfo

- (instancetype)init
{
    self = [super init];

    if (self)
    {
        _discTypeMappings = @{  DRDeviceMediaTypeCDROM: @"CD-ROM",
                                DRDeviceMediaTypeDVDROM: @"CD-ROM",
                                DRDeviceMediaTypeCDR: @"CD-ROM",
                                DRDeviceMediaTypeCDRW: @"CD-ROM",
                                DRDeviceMediaTypeDVDR: @"CD-ROM",
                                DRDeviceMediaTypeDVDRW: @"CD-ROM",
                                DRDeviceMediaTypeDVDRAM: @"CD-ROM",
                                DRDeviceMediaTypeDVDPlusR: @"CD-ROM",
                                DRDeviceMediaTypeDVDPlusRW: @"CD-ROM",
                                DRDeviceMediaTypeBDR: @"BD-R",
                                DRDeviceMediaTypeBDRE: @"BD-RE",
                                DRDeviceMediaTypeBDROM: @"BD-ROM",
                                DRDeviceMediaTypeHDDVDROM: @"HD DVD-ROM",
                                DRDeviceMediaTypeHDDVDR: @"HD DVD-R",
                                DRDeviceMediaTypeHDDVDRDualLayer: @"HD DVD-R DL",
                                DRDeviceMediaTypeHDDVDRAM: @"HD DVD-RAM",
                                DRDeviceMediaTypeHDDVDRW: @"HD DVD-RW",
                                DRDeviceMediaTypeHDDVDRWDualLayer: @"HD DVD-RW DL",
                                DRDeviceMediaTypeUnknown: @"????"
                            };
        
        [[NSBundle mainBundle] loadNibNamed:@"KWDiscInfo" owner:self topLevelObjects:nil];
    }
    
    return self;
}

- (void)dealloc
{
    [[DRNotificationCenter currentRunLoopCenter] removeObserver:self name:DRDeviceStatusChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)awakeFromNib
{
    [super awakeFromNib];

    NSWindow *myWindow = [self window];
    DRNotificationCenter *currentCenter = [DRNotificationCenter currentRunLoopCenter];

    [currentCenter addObserver:self selector:@selector(updateDiskInfo) name:DRDeviceDisappearedNotification object:nil];
    [currentCenter addObserver:self selector:@selector(updateDiskInfo) name:DRDeviceAppearedNotification object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(saveFrame) name:NSWindowWillCloseNotification object:nil];

    // TODO: is this necessary?
    [myWindow setFrameUsingName:@"Disc Info"];

    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"KWFirstRun"] == YES)
    {
	    [myWindow setFrameOrigin:NSMakePoint(500.0, [[NSScreen mainScreen] frame].size.height - 500.0)];
    }
}

#pragma mark - Main Methods

- (void)startDiskPanelwithDevice:(DRDevice *)device
{    
    NSWindow *myWindow = [self window];

    if ([myWindow isVisible])
    {
	    [myWindow orderOut:self];
    }
    else 
    {
        NSPopUpButton *recorderPopUp = [self recorderPopUp];
        [recorderPopUp removeAllItems];
        
	    for (DRDevice *device in [DRDevice devices])
	    {
    	    [recorderPopUp addItemWithTitle:[device displayName]];
	    }
    	    
	    [recorderPopUp selectItemWithTitle:[device displayName]];
	    
	    [self setDiskInfo:device];
	    [myWindow makeKeyAndOrderFront:self];
    }
}

#pragma mark - Interface Methods

- (IBAction)recorderPopup:(id)sender
{
    NSInteger indexOfSelectedItem = [[self recorderPopUp] indexOfSelectedItem];
    DRDevice *device = [DRDevice devices][indexOfSelectedItem];
    [self setDiskInfo:device];
}

#pragma mark -  Convenient Methods

- (void)setDiskInfo:(DRDevice *)device
{
    NSDictionary *mediaInfo = [device status][DRDeviceMediaInfoKey];
    NSString *type = [mediaInfo objectForKey:DRDeviceMediaTypeKey];
    NSString *kind = [self discTypeMappings][type];

    if (kind != nil)
    {
        NSString *freeSpace = [KWCommonMethods makeSizeFromFloat:[mediaInfo[DRDeviceMediaFreeSpaceKey] floatValue] * 2048];
        NSString *usedSpace = [KWCommonMethods makeSizeFromFloat:[mediaInfo[DRDeviceMediaUsedSpaceKey] floatValue] * 2048];
    
	    [[self kindTextField] setStringValue:kind];
	    [[self freeSpaceTextField] setStringValue:freeSpace];
	    [[self usedSpaceTextField] setStringValue:usedSpace];

	    if ([[mediaInfo[DRDeviceMediaBlocksOverwritableKey] stringValue] isEqualTo:@"0"])
    	    [[self writableTextField] setStringValue:NSLocalizedString(@"No",nil)];
	    else
    	    [[self writableTextField] setStringValue:NSLocalizedString(@"Yes",nil)];
    }
    else
    {
	    [[self kindTextField] setStringValue:NSLocalizedString(@"No disc",nil)];
	    [[self freeSpaceTextField] setStringValue:@""];
	    [[self usedSpaceTextField] setStringValue:@""];
	    [[self writableTextField] setStringValue:@""];
    }
}

- (void)updateDiskInfo
{
    NSPopUpButton *recorderPopUp = [self recorderPopUp];
    NSString *title = [[recorderPopUp title] copy];
    
    [recorderPopUp removeAllItems];
    
    for (DRDevice *device in [DRDevice devices])
    {
	    [recorderPopUp addItemWithTitle:[device displayName]];
    }
	    
    if ([recorderPopUp indexOfItemWithTitle:title] > -1)
    {
        [recorderPopUp selectItemWithTitle:title];
    }
    
    [self recorderPopup:self];
}

// TODO: is this necessary?
- (void)saveFrame
{
    [[self window] saveFrameUsingName:@"Disc Info"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
