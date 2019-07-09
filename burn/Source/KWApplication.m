#import "KWApplication.h"
#import "KWCommonMethods.h"

@interface KWApplication()

//Menu Actions
//Burn Menu
- (IBAction)preferencesBurn:(id)sender;
//Window Menu
- (IBAction)inspectorWindow:(id)sender;
- (IBAction)recorderInfoWindow:(id)sender;
- (IBAction)diskInfoWindow:(id)sender;
//Help Menu
- (IBAction)openBurnSite:(id)sender;

@end

@implementation KWApplication

+ (void)initialize
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults]; // standard user defaults
    NSArray *defaultKeys = [NSArray arrayWithObjects:   @"KWUseSoundEffects",
	    	    	    	    	    	    	    @"KWRememberLastTab",
	    	    	    	    	    	    	    @"KWRememberPopups",
	    	    	    	    	    	    	    @"KWCleanTemporaryFolderAction",
	    	    	    	    	    	    	    @"KWBurnOptionsVerifyBurn",
	    	    	    	    	    	    	    @"KWShowOverwritableSpace",
	    	    	    	    	    	    	    @"KWDefaultCDMedia",
	    	    	    	    	    	    	    @"KWDefaultDVDMedia",
	    	    	    	    	    	    	    @"KWDefaultMedia",
	    	    	    	    	    	    	    @"KWDefaultDataType",
	    	    	    	    	    	    	    @"KWShowFilePackagesAsFolder",
	    	    	    	    	    	    	    @"KWCalculateFilePackageSizes",
	    	    	    	    	    	    	    @"KWCalculateFolderSizes",
	    	    	    	    	    	    	    @"KWCalculateTotalSize",
	    	    	    	    	    	    	    @"KWDefaultAudioType",
	    	    	    	    	    	    	    @"KWDefaultPregap",
	    	    	    	    	    	    	    @"KWUseCDText",
	    	    	    	    	    	    	    @"KWDefaultMP3Bitrate",
	    	    	    	    	    	    	    @"KWDefaultMP3Mode",
	    	    	    	    	    	    	    @"KWCreateArtistFolders",
	    	    	    	    	    	    	    @"KWCreateAlbumFolders",
	    	    	    	    	    	    	    @"KWDefaultRegion",
	    	    	    	    	    	    	    @"KWDefaultVideoType",
	    	    	    	    	    	    	    @"KWDefaultDVDSoundType",
	    	    	    	    	    	    	    @"KWCustomDVDVideoBitrate",
	    	    	    	    	    	    	    @"KWDefaultDVDVideoBitrate",
	    	    	    	    	    	    	    @"KWCustomDVDSoundBitrate",
	    	    	    	    	    	    	    @"KWDefaultDVDSoundBitrate",
	    	    	    	    	    	    	    @"KWDVDForceAspect",
	    	    	    	    	    	    	    @"KWForceMPEG2",
	    	    	    	    	    	    	    @"KWMuxSeperateStreams",
	    	    	    	    	    	    	    @"KWRemuxMPEG2Streams",
	    	    	    	    	    	    	    @"KWLoopDVD",
	    	    	    	    	    	    	    @"KWUseTheme",
	    	    	    	    	    	    	    @"KWDVDThemePath",
	    	    	    	    	    	    	    @"KWDVDThemeFormat",
	    	    	    	    	    	    	    @"KWDefaultDivXSoundType",
	    	    	    	    	    	    	    @"KWCustomDivXVideoBitrate",
	    	    	    	    	    	    	    @"KWDefaultDivXVideoBitrate",
	    	    	    	    	    	    	    @"KWCustomDivXSoundBitrate",
	    	    	    	    	    	    	    @"KWDefaultDivxSoundBitrate",
	    	    	    	    	    	    	    @"KWCustomDivXSize",
	    	    	    	    	    	    	    @"KWDefaultDivXWidth",
	    	    	    	    	    	    	    @"KWDefaultDivXHeight",
	    	    	    	    	    	    	    @"KWCustomFPS",
	    	    	    	    	    	    	    @"KWDefaultFPS",
	    	    	    	    	    	    	    @"KWAllowMSMPEG4",
	    	    	    	    	    	    	    @"KWForceDivX",
	    	    	    	    	    	    	    @"KWSaveBorders",
	    	    	    	    	    	    	    @"KWSaveBorderSize",
	    	    	    	    	    	    	    @"KWDebug",
	    	    	    	    	    	    	    @"KWUseCustomFFMPEG",
	    	    	    	    	    	    	    @"KWCustomFFMPEG",
	    	    	    	    	    	    	    @"KWAllowOverBurning",
	    	    	    	    	    	    	    @"KWTemporaryLocation",
	    	    	    	    	    	    	    @"KWTemporaryLocationPopup",
	    	    	    	    	    	    	    @"KWDefaultDeviceIdentifier",
	    	    	    	    	    	    	    @"KWBurnOptionsCompletionAction",
	    	    	    	    	    	    	    @"KWSavedPrefView",
	    	    	    	    	    	    	    @"KWLastTab",
	    	    	    	    	    	    	    @"KWAdvancedFilesystems",
	    	    	    	    	    	    	    @"KWDVDTheme",
	    	    	    	    	    	    	    @"KWDefaultWindowWidth",
	    	    	    	    	    	    	    @"KWDefaultWindowHeight",
	    	    	    	    	    	    	    @"KWFirstRun",
	    	    	    	    	    	    	    @"KWEncodingThreads",
	    	    	    	    	    	    	    @"KWSimulateBurn",
	    	    	    	    	    	    	    @"KWDVDAspectMode",
	    	    	    	    	    	    	    @"KWTemporaryFiles",
    nil];

    NSArray *defaultValues = [NSArray arrayWithObjects: [NSNumber numberWithBool:YES],	    // KWUseSoundEffects REMOVED!!!
	    	    	    	    	    	    	    [NSNumber numberWithBool:YES],	    // KWRememberLastTab
	    	    	    	    	    	    	    [NSNumber numberWithBool:YES],	    // KWRememberPopups
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    // KWCleanTemporaryFolderAction REMOVED!!!
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWBurnOptionsVerifyBurn
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWShowOverwritableSpace
	    	    	    	    	    	    	    [NSNumber numberWithInt:6],    	    // KWDefaultCDMedia
	    	    	    	    	    	    	    [NSNumber numberWithInt:4],    	    // KWDefaultDVDMedia
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    // KWDefaultMedia
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    // KWDefaultDataType
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWShowFilePackagesAsFolder
	    	    	    	    	    	    	    [NSNumber numberWithBool:YES],	    // KWCalculateFilePackageSizes
	    	    	    	    	    	    	    [NSNumber numberWithBool:YES],	    // KWCalculateFolderSizes
	    	    	    	    	    	    	    [NSNumber numberWithBool:YES],	    // KWCalculateTotalSize
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    // KWDefaultAudioType
	    	    	    	    	    	    	    [NSNumber numberWithInt:2],    	    // KWDefaultPregap
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWUseCDText
	    	    	    	    	    	    	    [NSNumber numberWithInt:128],	    // KWDefaultMP3Bitrate
	    	    	    	    	    	    	    [NSNumber numberWithInt:1],    	    // KWDefaultMP3Mode
	    	    	    	    	    	    	    [NSNumber numberWithBool:YES],	    // KWCreateArtistFolders
	    	    	    	    	    	    	    [NSNumber numberWithBool:YES],	    // KWCreateAlbumFolders
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    // KWDefaultRegion
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    // KWDefaultVideoType
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    // KWDefaultDVDSoundType
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWCustomDVDVideoBitrate
	    	    	    	    	    	    	    [NSNumber numberWithInt:6000],	    // KWDefaultDVDVideoBitrate
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWCustomDVDSoundBitrate
	    	    	    	    	    	    	    [NSNumber numberWithInt:448],	    // KWDefaultDVDSoundBitrate
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    // KWDVDForceAspect
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWForceMPEG2
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWMuxSeperateStreams
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWRemuxMPEG2Streams
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWLoopDVD
	    	    	    	    	    	    	    [NSNumber numberWithBool:YES],	    // KWUseTheme
	    	    	    	    	    	    	    [[[NSBundle mainBundle] pathForResource:@"Themes" ofType:@""] stringByAppendingPathComponent:@"Default.burnTheme"], //KWDVDThemePath
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    // KWThemeFormat
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    // KWDefaultDivXSoundType
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWCustomDivXVideoBitrate
	    	    	    	    	    	    	    [NSNumber numberWithInt:768],	    // KWDefaultDivXVideoBitrate
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWCustomDivXSoundBitrate
	    	    	    	    	    	    	    [NSNumber numberWithInt:128],	    // KWDefaultDivxSoundBitrate
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWCustomDivXSize
	    	    	    	    	    	    	    [NSNumber numberWithInt:320],	    // KWDefaultDivXWidth
	    	    	    	    	    	    	    [NSNumber numberWithInt:240],	    // KWDefaultDivXHeight
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWCustomFPS
	    	    	    	    	    	    	    [NSNumber numberWithInt:25],	    // KWDefaultFPS
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWAllowMSMPEG4
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWForceDivX
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWSaveBorders
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    // KWSaveBorderSize
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWDebug
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWUseCustomFFMPEG
	    	    	    	    	    	    	    @"",	    	    	    	    // KWCustomFFMPEG
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    // KWAllowOverBurning
	    	    	    	    	    	    	    [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"Burn Temporary.localized"], // KWTemporaryLocation
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    // KWTemporaryLocationPopup REMOVED!!!
	    	    	    	    	    	    	    @"",	    	    	    	    // KWDefaultDeviceIdentifier
	    	    	    	    	    	    	    @"DRBurnCompletionActionMount",	    // KWBurnOptionsCompletionAction
	    	    	    	    	    	    	    @"General",    	    	    	    // KWSavedPrefView
	    	    	    	    	    	    	    @"Data",    	    	    	    // KWLastTab
	    	    	    	    	    	    	    [NSArray arrayWithObject:@"HFS+"],    // KWAdvancedFilesystems
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    //KWDVDTheme
	    	    	    	    	    	    	    [NSNumber numberWithInt:430],	    //KWDefaultWindowWidth
	    	    	    	    	    	    	    [NSNumber numberWithInt:436],	    //KWDefaultWindowHeight
	    	    	    	    	    	    	    [NSNumber numberWithBool:YES],	    //KWFirstRun
	    	    	    	    	    	    	    [NSNumber numberWithInt:8],    	    //KWEncodingThreads
	    	    	    	    	    	    	    [NSNumber numberWithBool:NO],	    //KWSimulateBurn
	    	    	    	    	    	    	    [NSNumber numberWithInt:0],    	    //KWDVDAspectMode
	    	    	    	    	    	    	    [NSArray array],    	    	    //KWTemporaryFiles
    nil];

    NSDictionary *appDefaults = [NSDictionary dictionaryWithObjects:defaultValues forKeys:defaultKeys];
    [defaults registerDefaults:appDefaults];
}

- (id)init
{
    self = [super init];
    
    return self;
}

- (void)dealloc 
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)awakeFromNib
{
    [super awakeFromNib];
    
    NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];
    [defaultCenter addObserver:self selector:@selector(openPreferencesAndAddTheme:) name:@"KWDVDThemeOpened" object:nil];
    [defaultCenter addObserver:self selector:@selector(changeInspector:) name:@"KWChangeInspector" object:nil];
}

//////////////////
// Menu actions //
//////////////////

#pragma mark -
#pragma mark •• Menu actions

//Burn menu

#pragma mark -
#pragma mark •• - Burn menu

- (IBAction)preferencesBurn:(id)sender
{
    if (preferences == nil)
	    preferences = [[KWPreferences alloc] init];
    
    [preferences showPreferences];
}

//Window menu

#pragma mark -
#pragma mark •• - Window menu

- (IBAction)inspectorWindow:(id)sender
{
    if (inspector == nil)
	    inspector = [[KWInspector alloc] init];

    [inspector beginWindowForType:currentType withObject:currentObject];
}

- (IBAction)recorderInfoWindow:(id)sender
{
    if (recorderInfo == nil)
	    recorderInfo = [[KWRecorderInfo alloc] init];

    [recorderInfo startRecorderPanelwithDevice:[KWCommonMethods getCurrentDevice]];
}

- (IBAction)diskInfoWindow:(id)sender
{
    if (diskInfo == nil)
	    diskInfo = [[KWDiscInfo alloc] init];

    [diskInfo startDiskPanelwithDevice:[KWCommonMethods getCurrentDevice]];
}

//Help menu

#pragma mark -
#pragma mark •• - Help menu

- (IBAction)openBurnSite:(id)sender
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://burn-osx.sourceforge.io"]];
}

//////////////////////////
// Notification actions //
//////////////////////////

#pragma mark -
#pragma mark •• Notification actions

- (void)openPreferencesAndAddTheme:(NSNotification *)notif
{
    [self preferencesBurn:self];
    [preferences addThemeAndShow:[notif object]];
}

- (void)changeInspector:(NSNotification *)notif
{    
    if (currentObject)
	    currentObject = nil;
    
    if (currentType)
    {
	    currentType = nil;
    }

    currentObject = [notif object];
    currentType = [[notif userInfo] objectForKey:@"Type"];

    if (inspector)
	    [inspector updateForType:currentType withObject:currentObject];
}

@end
