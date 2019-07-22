//
//  KWDVDAuthorizer.m
//  KWDVDAuthorizer
//
//  Created by Maarten Foukhar on 16-3-07.
//  Copyright 2009 Kiwi Fruitware. All rights reserved.
//

#import "KWDVDAuthorizer.h"
#import "KWConverter.h"
#import "KWProgressManager.h"

@interface KWDVDAuthorizer()

@property (nonatomic, strong) NSDictionary *currentTheme;

@end

@implementation KWDVDAuthorizer

- (id) init
{
    self = [super init];

    userCanceled = NO;

    [[KWProgressManager sharedManager] setCancelHandler:^
    {
        [self cancelAuthoring];
    }];
    
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)cancelAuthoring
{
    if (spumux)
	    [spumux terminate];
    
    if (dvdauthor)
	    [dvdauthor terminate];
    
    if (ffmpeg)
	    [ffmpeg terminate];
    
    userCanceled = YES;
}

////////////////////////////
// DVD-Video without menu //
////////////////////////////

#pragma mark -
#pragma mark •• DVD-Video without menu

- (NSInteger)createStandardDVDFolderAtPath:(NSString *)path withFileArray:(NSArray *)fileArray withSize:(NSNumber *)size errorString:(NSString **)error
{
    BOOL result;

    result = [KWCommonMethods createDirectoryAtPath:path errorString:&*error];

    //Create a xml file with chapters if there are any
    if (result)
	    [self createStandardDVDXMLAtPath:path withFileArray:fileArray errorString:&*error];

    progressSize = size;

    //Author the DVD
    
    if (result)
	    result = [self authorDVDWithXMLFile:[path stringByAppendingPathComponent:@"dvdauthor.xml"] withFileArray:fileArray atPath:path errorString:&*error];
    
    NSInteger success = 0;

    if (result == NO)
    {
	    if (userCanceled)
    	    success = 2;
	    else
    	    success = 1;
    }

    [KWCommonMethods removeItemAtPath:[path stringByAppendingPathComponent:@"dvdauthor.xml"]];
    
    //Create TOC (Table Of Contents)
    if (success == 0)
    {
        BOOL pal = ([[[NSUserDefaults standardUserDefaults] objectForKey:@"KWDefaultRegion"] intValue] == 0);
    
	    NSArray *arguments = [NSArray arrayWithObjects:@"-T",@"-o",path,nil];
	    BOOL status = [KWCommonMethods launchNSTaskAtPath:[[NSBundle mainBundle] pathForResource:@"dvdauthor" ofType:@""] withArguments:arguments outputError:YES outputString:YES output:&*error environment:@{@"VIDEO_FORMAT": pal ? @"PAL" : @"NTSC"}];

	    if (!status)
    	    success = 1;
    }

    if (success == 0)
    {
	    return 0;
    }
    else
    {
        [KWCommonMethods removeItemAtPath:path];
    
	    if (userCanceled)
    	    return 2;
	    else
    	    return 1;
    }
}

- (void)createStandardDVDXMLAtPath:(NSString *)path withFileArray:(NSArray *)fileArray errorString:(NSString **)error
{
    NSString *xmlFile = [NSString stringWithFormat:@"<dvdauthor dest=\"%@\">\n<titleset>\n<titles>", path];
    
    NSInteger x;
    for (x=0;x<[fileArray count];x++)
    {
	    NSDictionary *fileDictionary = [fileArray objectAtIndex:x];
	    NSString *path = [fileDictionary objectForKey:@"Path"];
	    
	    xmlFile = [NSString stringWithFormat:@"%@\n<pgc>\n<vob file=\"%@\"", xmlFile, path];
	    
	    NSArray *chapters = [fileDictionary objectForKey:@"Chapters"];
	    if ([chapters count] > 0)
	    {
            xmlFile = [NSString stringWithFormat:@"%@ chapters=\"", xmlFile];
	    
    	    NSInteger i;
    	    for (i=0;i<[chapters count];i++)
    	    {
	    	    NSDictionary *chapterDictionary = [chapters objectAtIndex:i];
	    	    float time = [[chapterDictionary objectForKey:@"RealTime"] floatValue];
          
                xmlFile = [NSString stringWithFormat:@"%@%@", xmlFile, [KWCommonMethods formatTimeForChapter:time]];
          
                if (x + 1 < [chapters count])
                {
                    xmlFile = [NSString stringWithFormat:@"%@,", xmlFile];
                }
    	    }
            
            xmlFile = [NSString stringWithFormat:@"%@\"></vob>\n", xmlFile];
	    }
	    else
        {
            xmlFile = [NSString stringWithFormat:@"%@/>", xmlFile];
        }
	    
	    
	    if (x < [fileArray count] - 1)
    	    xmlFile = [NSString stringWithFormat:@"%@\n<post>jump title %li;</post>\n</pgc>", xmlFile, x + 2];
    }
    
    NSString *loopString;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"KWLoopDVD"])
	    loopString = @"<post>jump title 1;</post>\n";
    else
	    loopString = @"<post>exit;</post>\n";
    
    xmlFile = [NSString stringWithFormat:@"%@%@</pgc>\n</titles>\n</titleset>\n</dvdauthor>", xmlFile, loopString];

    [KWCommonMethods writeString:xmlFile toFile:[path stringByAppendingPathComponent:@"dvdauthor.xml"] errorString:&*error];
}

/////////////////////////
// DVD-Video with menu //
/////////////////////////

#pragma mark -
#pragma mark •• DVD-Video with menu

//Create a menu with given files and chapters
- (NSInteger)createDVDMenuFiles:(NSString *)path withTheme:(NSDictionary *)currentTheme withFileArray:(NSArray *)fileArray withSize:(NSNumber *)size withName:(NSString *)name errorString:(NSString **)error
{
    NSString *themeFolderPath = [path stringByAppendingPathComponent:@"THEME_TS"];
    NSString *dvdXMLPath = [themeFolderPath stringByAppendingPathComponent:@"dvdauthor.xml"];
    progressSize = size;

    //Set value for our progress panel
    KWProgressManager *progressManager = [KWProgressManager sharedManager];
    [progressManager setValue:-1];
    [progressManager setStatus:NSLocalizedString(@"Creating DVD Theme", Localized)];

    //Load theme
    [self setCurrentTheme:currentTheme];

    BOOL success = YES;

    //Create temp folders
    success = [KWCommonMethods createDirectoryAtPath:path errorString:&*error];
    
    if (success)
	    success = [KWCommonMethods createDirectoryAtPath:themeFolderPath errorString:&*error];
    
    if ([fileArray count] == 1 && [[[fileArray objectAtIndex:0] objectForKey:@"Chapters"] count] > 0)
    {
	    //Create Chapter Root Menu
	    if (success)
    	    success = [self createRootMenu:themeFolderPath withName:name withTitles:NO withSecondButton:YES errorString:&*error];
	    
	    //Create Chapter Selection Menu(s)
	    if (success)
    	    success = [self createSelectionMenus:fileArray withChapters:YES atPath:themeFolderPath errorString:&*error];
    }
    else
    {
	    //Create Root Menu
	    if (success)
    	    success = [self createRootMenu:themeFolderPath withName:name withTitles:YES withSecondButton:([fileArray count] > 1) errorString:&*error];
	    
	    //Create Title Selection Menu(s)
	    if (success)
    	    success = [self createSelectionMenus:fileArray withChapters:NO atPath:themeFolderPath errorString:&*error];
	    
	    //Create Chapter Menu
	    if (success)
    	    success = [self createChapterMenus:themeFolderPath withFileArray:fileArray errorString:&*error];
	    
	    //Create Chapter Selection Menu(s)
	    if (success)
    	    success = [self createSelectionMenus:fileArray withChapters:YES atPath:themeFolderPath errorString:&*error];
    }
    
    //Create dvdauthor XML file
    if (success)
	    success = [self createDVDXMLAtPath:dvdXMLPath withFileArray:fileArray atFolderPath:path errorString:&*error];
    
    //Author DVD
    if (success)
	    success = [self authorDVDWithXMLFile:dvdXMLPath withFileArray:fileArray atPath:path errorString:&*error];
    
    if (!success)
    {
	    if (userCanceled)
    	    return 2;
	    else
    	    return 1;
    }

    [KWCommonMethods removeItemAtPath:themeFolderPath];

    return 0;
}

//////////////////
// Main actions //
//////////////////

#pragma mark -
#pragma mark •• Main actions

//Create root menu (Start and Titles)
- (BOOL)createRootMenu:(NSString *)path withName:(NSString *)name withTitles:(BOOL)titles withSecondButton:(BOOL)secondButton errorString:(NSString **)error
{
    BOOL success;

    //Create Images
    NSImage *image = [self rootMenuWithTitles:titles withName:name withSecondButton:secondButton];
    NSImage *mask = [self rootMaskWithTitles:titles withSecondButton:secondButton];
	    
    //Save mask as png
    success = [KWCommonMethods saveImage:mask toPath:[path stringByAppendingPathComponent:@"Mask.png"] errorString:&*error];

    //Create mpg with menu in it
    if (success)
	    success = [self createDVDMenuFile:[path stringByAppendingPathComponent:@"Title Menu.mpg"] withImage:image withMaskFile:[path stringByAppendingPathComponent:@"Mask.png"] errorString:&*error];
    
    if (!success && *error == nil)
	    *error = @"Failed to create root menu";
    
    return success;
}

//Batch create title selection menus
- (BOOL)createSelectionMenus:(NSArray *)fileArray withChapters:(BOOL)chapters atPath:(NSString *)path errorString:(NSString **)error
{
    BOOL success = YES;
    NSInteger menuSeries = 1;
    NSInteger numberOfpages = 0;
    NSMutableArray *titlesWithChapters = [[NSMutableArray alloc] init];
    NSMutableArray *indexes = [[NSMutableArray alloc] init];
    NSArray *objects = fileArray;

    if (chapters)
    {
	    NSInteger i;
	    for (i=0;i<[fileArray count];i++)
	    {
    	    if ([[[fileArray objectAtIndex:i] objectForKey:@"Chapters"] count] > 0)
    	    {
	    	    [titlesWithChapters addObject:[[fileArray objectAtIndex:i] objectForKey:@"Chapters"]];
	    	    [indexes addObject:[NSNumber numberWithInt:i]];
    	    }
	    }

	    objects = titlesWithChapters;
	    menuSeries = [titlesWithChapters count];
    }
    
    NSDictionary *currentTheme = [self currentTheme];

    NSInteger x;
    for (x=0;x<menuSeries;x++)
    {
	    if (chapters)
    	    objects = [titlesWithChapters objectAtIndex:x];

	    NSMutableArray *images = [[NSMutableArray alloc] init];

	    NSInteger i;
	    for (i=0;i<[objects count];i++)
	    {
    	    NSDictionary *currentObject = [objects objectAtIndex:i];
    	    NSImage *image;

    	    if (chapters)
    	    {
	    	    image = [[NSImage alloc] initWithData:[currentObject objectForKey:@"Image"]];
    	    }
    	    else
    	    {
	    	    image = [[KWConverter alloc] getImageAtPath:[currentObject objectForKey:@"Path"] atTime:[[currentTheme objectForKey:@"KWScreenshotAtTime"] intValue] isWideScreen:[[currentObject objectForKey:@"WideScreen"] boolValue]];
	    	    
	    	    //Too short movie
	    	    if (!image)
    	    	    image = [[KWConverter alloc] getImageAtPath:[currentObject objectForKey:@"Path"] atTime:0 isWideScreen:[[currentObject objectForKey:@"WideScreen"] boolValue]];
    	    }
    	    
    	    [images addObject:image];
	    }

	    //create the menu's and masks
	    NSString *outputName;
	    if (chapters)
    	    outputName = @"Chapter Selection ";
	    else
    	    outputName = @"Title Selection ";

	    NSInteger number;
	    if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] != 2)
    	    number = [[currentTheme objectForKey:@"KWSelectionImagesOnAPage"] intValue];
	    else
    	    number = [[currentTheme objectForKey:@"KWSelectionStringsOnAPage"] intValue];

	    NSInteger pages = [objects count] / number;

	    if ([objects count] > number * pages)
    	    pages = pages + 1;

	    NSRange firstRange;
	    NSImage *image;
	    NSImage *mask;

	    if (pages > 1)
	    {
    	    //Create first page range
    	    firstRange = NSMakeRange(0,number);

    	    NSInteger i;
    	    for (i=1;i<pages - 1;i++)
    	    {
	    	    if (success)
	    	    {
    	    	    NSRange range = NSMakeRange(number * i,number);
    	    	    image = [self selectionMenuWithTitles:(!chapters) withObjects:[objects subarrayWithRange:range] withImages:[images subarrayWithRange:range] addNext:YES addPrevious:YES];
    	    	    mask = [self selectionMaskWithTitles:(!chapters) withObjects:[objects subarrayWithRange:range] addNext:YES addPrevious:YES];
    	    	    success = [KWCommonMethods saveImage:mask toPath:[path stringByAppendingPathComponent:@"Mask.png"] errorString:&*error];
	    	    
    	    	    if (success)
	    	    	    success = [self createDVDMenuFile:[[[path stringByAppendingPathComponent:outputName] stringByAppendingString:[[NSNumber numberWithInt:i + 1 + numberOfpages] stringValue]] stringByAppendingString:@".mpg"] withImage:image withMaskFile:[path stringByAppendingPathComponent:@"Mask.png"] errorString:&*error];
	    	    }
    	    }

    	    if (success)
    	    {
	    	    NSRange range = NSMakeRange((pages - 1) * number,[objects count] - (pages - 1) * number);
	    	    image = [self selectionMenuWithTitles:(!chapters) withObjects:[objects subarrayWithRange:range] withImages:[images subarrayWithRange:range] addNext:NO addPrevious:YES];
	    	    mask = [self selectionMaskWithTitles:(!chapters) withObjects:[objects subarrayWithRange:range] addNext:NO addPrevious:YES];
	    	    success = [KWCommonMethods saveImage:mask toPath:[path stringByAppendingPathComponent:@"Mask.png"] errorString:&*error];
    	    
	    	    if (success)
    	    	    success = [self createDVDMenuFile:[[[path stringByAppendingPathComponent:outputName] stringByAppendingString:[[NSNumber numberWithInt:pages + numberOfpages] stringValue]] stringByAppendingString:@".mpg"] withImage:image withMaskFile:[path stringByAppendingPathComponent:@"Mask.png"] errorString:&*error];
    	    }
	    }
	    else
	    {
    	    firstRange = NSMakeRange(0,[objects count]);
	    }

	    if (success)
	    {
    	    image = [self selectionMenuWithTitles:(!chapters) withObjects:[objects subarrayWithRange:firstRange] withImages:[images subarrayWithRange:firstRange] addNext:([objects count] > number) addPrevious:NO];
    	    mask = [self selectionMaskWithTitles:(!chapters) withObjects:[objects subarrayWithRange:firstRange] addNext:([objects count] > number) addPrevious:NO];
    	    success = [KWCommonMethods saveImage:mask toPath:[path stringByAppendingPathComponent:@"Mask.png"] errorString:&*error];
	    
    	    if (success)
	    	    success = [self createDVDMenuFile:[path stringByAppendingPathComponent:[[outputName stringByAppendingString:[[NSNumber numberWithInt:1 + numberOfpages] stringValue]] stringByAppendingString:@".mpg"]] withImage:image withMaskFile:[path stringByAppendingPathComponent:@"Mask.png"] errorString:&*error];
	    }

	    numberOfpages = numberOfpages + pages;
	    images = nil;
    }
    
    if (!success && !*error)
	    *error = @"Failed to create selection menus";

    return success;
}

//Create a chapter menu (Start and Chapters)
- (BOOL)createChapterMenus:(NSString *)path withFileArray:(NSArray *)fileArray errorString:(NSString **)error
{
    BOOL success = YES;

    //Check if there are any chapters
    NSInteger i;
    for (i=0;i<[fileArray count];i++)
    {
	    if ([[[fileArray objectAtIndex:i] objectForKey:@"Chapters"] count] > 0)
	    {
    	    NSString *name = [[[[fileArray objectAtIndex:i] objectForKey:@"Path"] lastPathComponent] stringByDeletingPathExtension];

    	    //Create Images
    	    NSImage *image = [self rootMenuWithTitles:NO withName:name withSecondButton:YES];
    	    NSImage *mask = [self rootMaskWithTitles:NO withSecondButton:YES];
	    
    	    //Save mask as png
    	    success = [KWCommonMethods saveImage:mask toPath:[path stringByAppendingPathComponent:@"Mask.png"] errorString:&*error];

    	    //Create mpg with menu in it
    	    if (success)
	    	    success = [self createDVDMenuFile:[path stringByAppendingPathComponent:[name stringByAppendingString:@".mpg"]] withImage:image withMaskFile:[path stringByAppendingPathComponent:@"Mask.png"] errorString:&*error];
	    }
    }
    
    if (!success && !*error)
	    *error = @"Failed to create chapter menus";
    
    return success;
}

/////////////////
// DVD actions //
/////////////////

#pragma mark -
#pragma mark •• DVD actions

- (BOOL)createDVDMenuFile:(NSString *)path withImage:(NSImage *)image withMaskFile:(NSString *)maskFile errorString:(NSString **)error
{
    NSString *xmlFile = [NSString stringWithFormat:@"<subpictures>\n<stream>\n<spu\nforce=\"yes\"\nstart=\"00:00:00.00\" end=\"00:00:00.00\"\nhighlight=\"%@\"\nautooutline=\"infer\"\noutlinewidth=\"6\"\nautoorder=\"rows\"\n>\n</spu>\n</stream>\n</subpictures>", [maskFile lastPathComponent]];
    BOOL success = [KWCommonMethods writeString:xmlFile toFile:[[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"xml"] errorString:&*error];
    
    if (success)
    {
	    NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
	    NSPipe *pipe=[[NSPipe alloc] init];
	    NSPipe *pipe2=[[NSPipe alloc] init];
	    NSFileHandle *myHandle = [pipe fileHandleForWriting];
	    NSFileHandle *myHandle2 = [pipe2 fileHandleForReading];
	    ffmpeg = [[NSTask alloc] init];
	    NSString *format;
    
	    if ([[standardUserDefaults objectForKey:@"KWDefaultRegion"] intValue] == 0)
        {
	        format = @"pal-dvd";
        }
        else
        {
	        format = @"ntsc-dvd";
        }
        
	    [ffmpeg setLaunchPath:[KWCommonMethods ffmpegPath]];
	    
	    NSArray *arguments;
	    if ([[standardUserDefaults objectForKey:@"KWDVDThemeFormat"] intValue] == 0)
    	    arguments = [NSArray arrayWithObjects: @"-shortest", @"-f",@"image2pipe",@"-threads",[[NSNumber numberWithInt:[[[NSUserDefaults standardUserDefaults] objectForKey:@"KWEncodingThreads"] intValue]] stringValue], @"-i",@"pipe:.jpg",@"-f", @"s16le", @"-ac", @"2", @"-i", @"/dev/zero",@"-target",format,@"-",@"-an",nil];
	    else
    	    arguments = [NSArray arrayWithObjects: @"-shortest", @"-f",@"image2pipe",@"-threads",[[NSNumber numberWithInt:[[[NSUserDefaults standardUserDefaults] objectForKey:@"KWEncodingThreads"] intValue]] stringValue], @"-i",@"pipe:.jpg",@"-f", @"s16le", @"-ac", @"2", @"-i", @"/dev/zero", @"-target",format,@"-",@"-an",@"-aspect",@"16:9",nil];
    
	    [ffmpeg setArguments:arguments];
	    [ffmpeg setStandardInput:pipe];
	    [ffmpeg setStandardOutput:pipe2];
	    [ffmpeg setStandardError:[NSFileHandle fileHandleWithNullDevice]];

	    spumux = [[NSTask alloc] init];
	    
	    if (![KWCommonMethods createFileAtPath:path attributes:nil errorString:&*error])
    	    return NO;
	    
	    [spumux setStandardOutput:[NSFileHandle fileHandleForWritingAtPath:path]];
	    [spumux setStandardInput:myHandle2];
	    [spumux setLaunchPath:[[NSBundle mainBundle] pathForResource:@"spumux" ofType:@""]];
	    [spumux setCurrentDirectoryPath:[path stringByDeletingLastPathComponent]];
	    [spumux setArguments:[NSArray arrayWithObject:[[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"xml"]]];
	    NSPipe *errorPipe=[[NSPipe alloc] init];
	    NSFileHandle *handle;
	    [spumux setStandardError:errorPipe];
	    handle=[errorPipe fileHandleForReading];
	    [KWCommonMethods logCommandIfNeeded:spumux];
	    [spumux launch];
	    [KWCommonMethods logCommandIfNeeded:ffmpeg];
	    [ffmpeg launch];
    
	    NSData *tiffData = [image TIFFRepresentation];
	    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:tiffData];
	    
	    NSData *jpgData = [bitmap representationUsingType:NSJPEGFileType properties:[NSDictionary dictionaryWithObject:[NSNumber numberWithFloat:1.0] forKey:NSImageCompressionFactor]];
	    
	    NSInteger q = 0;
	    while (q < 25)
	    {
    	    q = q + 1;
    	    [myHandle writeData:jpgData];
	    }
	    
	    [myHandle closeFile];

	    [ffmpeg waitUntilExit];
	    ffmpeg = nil;

	    NSString *string = [[NSString alloc] initWithData:[handle readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    
	    if ([standardUserDefaults boolForKey:@"KWDebug"])
    	    NSLog(@"%@", string);

	    [spumux waitUntilExit];

	    success = ([spumux terminationStatus] == 0);

	    spumux = nil;
	    
	    if (!success)
	    {
            [KWCommonMethods removeItemAtPath:path];
    	    *error = string;
	    }

        [KWCommonMethods removeItemAtPath:maskFile];
        [KWCommonMethods removeItemAtPath:[[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"xml"]];
    }
    
    return success;
}

//Create a xml file for dvdauthor
-(BOOL)createDVDXMLAtPath:(NSString *)path withFileArray:(NSArray *)fileArray atFolderPath:(NSString *)folderPath errorString:(NSString **)error
{	    
    NSString *xmlContent;

    NSString *aspect1 = @"";
    NSString *aspect2 = @"";
	    
    if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"KWDVDThemeFormat"] intValue] == 1)
    {
	    aspect1 = @" aspect=\"16:9\"";
	    aspect2 = @"<video aspect=\"16:9\"></video>\n";
    }
	    
    NSString *titleset = @"";
	    
    if ([fileArray count] > 1 || [[[fileArray objectAtIndex:0] objectForKey:@"Chapters"] count] > 0)
	    titleset = @"<button>jump titleset 1 menu entry root;</button>\n";
	    
    xmlContent = [NSString stringWithFormat:@"<dvdauthor dest=\"../\" jumppad=\"1\">\n<vmgm>\n<menus>\n<video %@></video>\n<pgc entry=\"title\">\n<vob file=\"Title Menu.mpg\" pause=\"inf\"></vob>\n<button>jump titleset 1 title 1;</button>\n%@</pgc>\n</menus>\n</vmgm>\n<titleset>\n<menus>\n%@", aspect1, titleset, aspect2];
    
    
    NSDictionary *currentTheme = [self currentTheme];
    NSInteger number;
    if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] != 2)
	    number = [[currentTheme objectForKey:@"KWSelectionImagesOnAPage"] intValue];
    else
	    number = [[currentTheme objectForKey:@"KWSelectionStringsOnAPage"] intValue];

    NSInteger numberOfMenus = [fileArray count] / number;

    if ([fileArray count] - (numberOfMenus * number) > 0)
	    numberOfMenus = numberOfMenus + 1;

    NSInteger chapterMenu = numberOfMenus + 1;
    NSInteger menuItem = 0;

    if ([fileArray count] == 1)
    {
	    numberOfMenus = 0;
	    chapterMenu = 1;
    }

    NSInteger i;
    for (i=0;i<numberOfMenus;i++)
    {
	    menuItem = menuItem + 1;
	    xmlContent = [NSString stringWithFormat:@"%@<pgc>\n<vob file=\"Title Selection %li.mpg\" pause=\"inf\"></vob>\n",xmlContent, i + 1];
	    
	    NSInteger o;
	    for (o=0;o<number;o++)
	    {
    	    if ([fileArray count] > i * number + o)
    	    {
	    	    NSInteger jumpNumber = o+1+i*number;
	    	    NSString *jumpKind;
	    	    
	    	    NSArray *chapters = [[fileArray objectAtIndex:jumpNumber-1] objectForKey:@"Chapters"];
	    	    if ([chapters count] > 0)
	    	    {
    	    	    jumpKind = @"menu";
    	    	    jumpNumber = chapterMenu;
    	    	    
    	    	    NSInteger chapterMenuCount = [chapters count] / number;
    	    	    
    	    	    if ([chapters count] - (chapterMenuCount * number) > 0)
	    	    	    chapterMenuCount = chapterMenuCount + 1;
    	    	    
    	    	    chapterMenu = chapterMenu + chapterMenuCount;
	    	    }
	    	    else
	    	    {
    	    	    jumpKind = @"title";
	    	    }
	    	    
	    	    xmlContent = [NSString stringWithFormat:@"%@<button>jump %@ %li;</button>\n", xmlContent, jumpKind, jumpNumber];
    	    }
	    }
	    
	    if (i > 0)
    	    xmlContent = [NSString stringWithFormat:@"%@<button>jump menu %li;</button>\n", xmlContent, i];

	    if (i < numberOfMenus - 1)
    	    xmlContent = [NSString stringWithFormat:@"%@<button>jump menu %li;</button>\n", xmlContent, i + 2];

	    xmlContent = [NSString stringWithFormat:@"%@</pgc>\n", xmlContent];
    }

    NSMutableArray *titlesWithChapters = [[NSMutableArray alloc] init];
    NSMutableArray *titlesWithChaptersNames = [[NSMutableArray alloc] init];
    for (i=0;i<[fileArray count];i++)
    {
	    NSDictionary *fileDictionary = [fileArray objectAtIndex:i];
	    NSArray *chapters = [fileDictionary objectForKey:@"Chapters"];
    
	    if ([chapters count] > 0)
	    {
    	    [titlesWithChapters addObject:[NSNumber numberWithInt:i]];
    	    [titlesWithChaptersNames addObject:[[[fileDictionary objectForKey:@"Path"] lastPathComponent] stringByDeletingPathExtension]];
	    }
    }

    NSInteger chapterSelection = 1;
    for (i=0;i<[titlesWithChapters count];i++)
    {
	    NSArray *chapters = [[fileArray objectAtIndex:[[titlesWithChapters objectAtIndex:i] intValue]] objectForKey:@"Chapters"];
	    NSInteger numberOfChapters = [chapters count];
	    NSInteger numberOfMenus = numberOfChapters / number;

	    if (numberOfChapters - numberOfMenus * number > 0)
    	    numberOfMenus = numberOfMenus + 1;

	    NSInteger y;
	    for (y=0;y<numberOfMenus;y++)
	    {
    	    menuItem = menuItem + 1;
    	    
    	    xmlContent = [NSString stringWithFormat:@"%@<pgc>\n<vob file=\"Chapter Selection %li.mpg\" pause=\"inf\"></vob>\n", xmlContent, chapterSelection];
    	    
    	    chapterSelection = chapterSelection + 1;
	    
    	    NSInteger o;
    	    for (o=0;o<number;o++)
    	    {
	    	    NSInteger addNumber;
	    	    if ([[[chapters objectAtIndex:0] objectForKey:@"RealTime"] intValue] == 0)
    	    	    addNumber = 1;
	    	    else
    	    	    addNumber = 2;
    	        
	    	    if (numberOfChapters > y * number + o)
    	    	    xmlContent = [NSString stringWithFormat:@"%@<button>jump title %i chapter %li;</button>\n", xmlContent, [[titlesWithChapters objectAtIndex:i] intValue] + 1, y * number + o + addNumber];
    	    }
	    
	    if (y > 0)
	    {
    	    xmlContent = [NSString stringWithFormat:@"%@<button>jump menu %li;</button>\n", xmlContent, menuItem - 1];
	    }
	    
	    if (y < numberOfMenus - 1)
	    {
    	    xmlContent = [NSString stringWithFormat:@"%@<button>jump menu %li;</button>\n", xmlContent, menuItem + 1];
	    }
	    
    	    xmlContent = [NSString stringWithFormat:@"%@</pgc>\n", xmlContent];
	    }
    }
	    
	    xmlContent = [NSString stringWithFormat:@"%@</menus>\n<titles>\n", xmlContent];
    
    for (i=0;i<[fileArray count];i++)
    {
	    NSDictionary *fileDictionary = [fileArray objectAtIndex:i];
	    NSArray *chapters = [[fileArray objectAtIndex:i] objectForKey:@"Chapters"];
        
        //xmlContent = [NSString stringWithFormat:@"%@<video aspect=\"16:9\" /><pgc>\n<vob file=\"%@\"", xmlContent, [fileDictionary objectForKey:@"Path"]];
	    xmlContent = [NSString stringWithFormat:@"%@<pgc>\n<vob file=\"%@\"", xmlContent, [fileDictionary objectForKey:@"Path"]];
    
	    if ([chapters count] > 0)
	    {
    	    xmlContent = [NSString stringWithFormat:@"%@ chapters=\"", xmlContent];
    	    
    	    NSInteger x;
    	    for (x=0;x<[chapters count];x++)
    	    {
	    	    NSDictionary *currentChapter = [chapters objectAtIndex:x];
	    	    float time = [[currentChapter objectForKey:@"RealTime"] floatValue];
                
                xmlContent = [NSString stringWithFormat:@"%@%@", xmlContent, [KWCommonMethods formatTimeForChapter:time]];
          
                if (x + 1 < [chapters count])
                {
                    xmlContent = [NSString stringWithFormat:@"%@,", xmlContent];
                }
    	    }
         
            xmlContent = [NSString stringWithFormat:@"%@\"></vob>\n", xmlContent];
	    }
        else
        {
            xmlContent = [NSString stringWithFormat:@"%@></vob>\n", xmlContent];
        }
        
	    if (i + 1 < [fileArray count] || [[NSUserDefaults standardUserDefaults] boolForKey:@"KWLoopDVD"] == YES)
	    {
    	    NSInteger title;
    	    if (i + 1 < [fileArray count])
	    	    title = i + 2;
    	    else
	    	    title = 1;
	    	    
    	    xmlContent = [NSString stringWithFormat:@"%@<post>jump title %li;</post>", xmlContent, title];
	    }
	    else
	    {
    	    xmlContent = [NSString stringWithFormat:@"%@<post>call vmgm menu;</post>", xmlContent];
	    }

	    xmlContent = [NSString stringWithFormat:@"%@</pgc>\n", xmlContent];
    }
    
    xmlContent = [NSString stringWithFormat:@"%@</titles>\n</titleset>\n</dvdauthor>", xmlContent];

    return [KWCommonMethods writeString:xmlContent toFile:path errorString:&*error];
}

//Create DVD folders with dvdauthor
- (BOOL)authorDVDWithXMLFile:(NSString *)xmlFile withFileArray:(NSArray *)fileArray atPath:(NSString *)path errorString:(NSString **)error
{
    NSFileManager *defaultManager = [NSFileManager defaultManager];

    dvdauthor=[[NSTask alloc] init];
    NSPipe *pipe2 = [[NSPipe alloc] init];
    NSPipe *pipe=[[NSPipe alloc] init];
    NSFileHandle *handle;
    NSFileHandle *handle2;
    NSData *data;
    BOOL returnCode;
    [dvdauthor setLaunchPath:[[NSBundle mainBundle] pathForResource:@"dvdauthor" ofType:@""]];
    [dvdauthor setCurrentDirectoryPath:[xmlFile stringByDeletingLastPathComponent]];
    
    BOOL pal = ([[[NSUserDefaults standardUserDefaults] objectForKey:@"KWDefaultRegion"] intValue] == 0);
    [dvdauthor setEnvironment:@{@"VIDEO_FORMAT": pal ? @"PAL" : @"NTSC"}];

    [dvdauthor setArguments:[NSArray arrayWithObjects:@"-x",xmlFile,nil]];
    [dvdauthor setStandardError:pipe];
    [dvdauthor setStandardOutput:pipe2];
    
    handle=[pipe fileHandleForReading];
    handle2=[pipe2 fileHandleForReading];

    float totalSize = 0;

    if ([defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"THEME_TS"]])
    {
	    totalSize = totalSize + [KWCommonMethods calculateRealFolderSize:[path stringByAppendingPathComponent:@"THEME_TS"]];
    }

    // TODO: just pass files
    for (NSDictionary *fileInfo in fileArray)
    {
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:fileInfo[@"Path"] error:nil];
        totalSize = totalSize + ([attributes[NSFileSize] floatValue]);
    }

    NSInteger currentFile = 1;
    NSInteger currentProcces = 1;
    
    [KWCommonMethods logCommandIfNeeded:dvdauthor];
    [dvdauthor launch];

    totalSize = totalSize / 1024 / 1024;
    
    NSString *errorString = @"";
    NSString *string = nil;

    while([data=[handle availableData] length])
    {
	    if (string)
	    {
    	    string = nil;
	    }
    
	    string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

	    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"KWDebug"])
    	    NSLog(@"%@", string);
	    
	    if (string)    
    	    errorString = [errorString stringByAppendingString:string];

	    if ([string rangeOfString:@"Processing /"].length > 0)
	    {
    	    NSString *fileName = [defaultManager displayNameAtPath:[[[[string componentsSeparatedByString:@"Processing "] objectAtIndex:1] componentsSeparatedByString:@"..."] objectAtIndex:0]];
            NSString *statusString = [NSString stringWithFormat:NSLocalizedString(@"Processing: %@ (%i of %i)", nil), fileName, currentFile, [fileArray count]];
            [[KWProgressManager sharedManager] setStatus:statusString];
    	    
    	    currentFile = currentFile + 1;
	    }
	    
	    if ([string rangeOfString:@"Generating VTS with the following video attributes"].length > 0)
	    {
            [[KWProgressManager sharedManager] setStatus:NSLocalizedString(@"Generating DVD folder", Localized)];
    	    currentProcces = 2;
	    }

	    if ([string rangeOfString:@"MB"].length > 0 && [string rangeOfString:@"at "].length > 0)
	    {
    	    float progressValue;

    	    if (currentProcces == 1)
    	    {
	    	    progressValue = [[[[[string componentsSeparatedByString:@"MB"] objectAtIndex:0] componentsSeparatedByString:@"at "] objectAtIndex:1] floatValue] / totalSize * 100;
                [[KWProgressManager sharedManager] setValue:(([progressSize floatValue] / 100) * progressValue)];
                
            }
    	    else
    	    {
	    	    progressValue = [[[[[string componentsSeparatedByString:@" "] objectAtIndex:[[string componentsSeparatedByString:@" "] count]-1] componentsSeparatedByString:@")"] objectAtIndex:0] floatValue];

	    	    if (progressValue > 0 && progressValue < 101)
	    	    {
                    KWProgressManager *progressManager = [KWProgressManager sharedManager];
                    [progressManager setValue:([progressSize floatValue])+(([progressSize floatValue] / 100) * progressValue)];
                    [progressManager setStatus:[NSString stringWithFormat:NSLocalizedString(@"Generating DVD folder: (%.0f%@)", nil), progressValue, @"%"]];
	    	    }
    	    }
	    }
	    data = nil;
    }
    
    [dvdauthor waitUntilExit];
    
    returnCode = ([dvdauthor terminationStatus] == 0 && userCanceled == NO);
    
    errorString = [errorString stringByAppendingString:[[NSString alloc] initWithData:[handle2 readDataToEndOfFile] encoding:NSUTF8StringEncoding]];
    
    if (!returnCode)
	    *error = [NSString stringWithFormat:@"KWConsole:\nTask: dvdauthor\n%@", errorString];
    
    dvdauthor = nil;

    return returnCode;
}

///////////////////
// Theme actions //
///////////////////

#pragma mark -
#pragma mark •• Theme actions

//Create menu image with titles or chapters
- (NSImage *)rootMenuWithTitles:(BOOL)titles withName:(NSString *)name withSecondButton:(BOOL)secondButton
{
    NSImage *newImage = nil;
    NSDictionary *currentTheme = [self currentTheme];

    if (titles)
	    newImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWAltRootImage"]];
    else
	    newImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWAltChapterImage"]];

    if (!newImage)
	    newImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWDefaultImage"]];
    
    NSInteger y = [[currentTheme objectForKey:@"KWStartButtonY"] intValue];

    if (titles)
    {
	    if (![[currentTheme objectForKey:@"KWDVDNameDisableText"] boolValue])
    	    [self drawString:name inRect:NSMakeRect([[currentTheme objectForKey:@"KWDVDNameX"] intValue],[[currentTheme objectForKey:@"KWDVDNameY"] intValue],[[currentTheme objectForKey:@"KWDVDNameW"] intValue],[[currentTheme objectForKey:@"KWDVDNameH"] intValue]) onImage:newImage withFontName:[currentTheme objectForKey:@"KWDVDNameFont"] withSize:[[currentTheme objectForKey:@"KWDVDNameFontSize"] intValue] withColor:[self colourForName:@"KWDVDNameFontColor" inTheme:currentTheme] useAlignment:NSCenterTextAlignment];
    }
    else
    {
	    if (![[currentTheme objectForKey:@"KWVideoNameDisableText"] boolValue])
    	    [self drawString:name inRect:NSMakeRect([[currentTheme objectForKey:@"KWVideoNameX"] intValue],[[currentTheme objectForKey:@"KWVideoNameY"] intValue],[[currentTheme objectForKey:@"KWVideoNameW"]  intValue],[[currentTheme objectForKey:@"KWVideoNameH"]  intValue]) onImage:newImage withFontName:[currentTheme objectForKey:@"KWVideoNameFont"] withSize:[[currentTheme objectForKey:@"KWVideoNameFontSize"] intValue] withColor:[self colourForName:@"KWVideoNameFontColor" inTheme:currentTheme] useAlignment:NSCenterTextAlignment];
    }
    
    if (![[currentTheme objectForKey:@"KWStartButtonDisable"] boolValue])
    {
	    NSImage *startButtonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWStartButtonImage"]];
	    NSRect rect = NSMakeRect([[currentTheme objectForKey:@"KWStartButtonX"] intValue],y,[[currentTheme objectForKey:@"KWStartButtonW"]  intValue],[[currentTheme objectForKey:@"KWStartButtonH"] intValue]);

	    if (!startButtonImage)
    	    [self drawString:[currentTheme objectForKey:@"KWStartButtonString"] inRect:rect onImage:newImage withFontName:[currentTheme objectForKey:@"KWStartButtonFont"] withSize:[[currentTheme objectForKey:@"KWStartButtonFontSize"] intValue] withColor:[self colourForName:@"KWStartButtonFontColor" inTheme:currentTheme] useAlignment:NSCenterTextAlignment];
	    else
    	    [self drawImage:startButtonImage inRect:rect onImage:newImage];
    }

    //Draw titles if needed
    if (titles)
    {
	    if (![[currentTheme objectForKey:@"KWTitleButtonDisable"] boolValue] && secondButton)
	    {
    	    NSImage *titleButonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWTitleButtonImage"]];
    	    NSRect rect = NSMakeRect([[currentTheme objectForKey:@"KWTitleButtonX"] intValue],[[currentTheme objectForKey:@"KWTitleButtonY"] intValue],[[currentTheme objectForKey:@"KWTitleButtonW"] intValue],[[currentTheme objectForKey:@"KWTitleButtonH"] intValue]);

    	    if (!titleButonImage)
	    	    [self drawString:[currentTheme objectForKey:@"KWTitleButtonString"] inRect:rect onImage:newImage withFontName:[currentTheme objectForKey:@"KWTitleButtonFont"] withSize:[[currentTheme objectForKey:@"KWTitleButtonFontSize"] intValue] withColor:[self colourForName:@"KWTitleButtonFontColor" inTheme:currentTheme] useAlignment:NSCenterTextAlignment];
    	    else
	    	    [self drawImage:titleButonImage inRect:rect onImage:newImage];
	    }
    }
    //Draw chapters if needed
    else
    {
	    if (![[currentTheme objectForKey:@"KWChapterButtonDisable"] boolValue])
	    {
    	    NSImage *chapterButtonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWChapterButtonImage"]];
    	    NSRect rect = NSMakeRect([[currentTheme objectForKey:@"KWChapterButtonX"] intValue],[[currentTheme objectForKey:@"KWChapterButtonY"] intValue],[[currentTheme objectForKey:@"KWChapterButtonW"] intValue],[[currentTheme objectForKey:@"KWChapterButtonH"] intValue]);

    	    if (!chapterButtonImage)
	    	    [self drawString:[currentTheme objectForKey:@"KWChapterButtonString"] inRect:rect onImage:newImage withFontName:[currentTheme objectForKey:@"KWChapterButtonFont"] withSize:[[currentTheme objectForKey:@"KWChapterButtonFontSize"] intValue] withColor:[self colourForName:@"KWChapterButtonFontColor" inTheme:currentTheme] useAlignment:NSCenterTextAlignment];
    	    else
	    	    [self drawImage:chapterButtonImage inRect:rect onImage:newImage];
	    }
    }

    NSImage *overlay = nil;
    
	    if (titles)
    	    overlay = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWRootOverlayImage"]] ;
	    else
    	    overlay = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWChapterOverlayImage"]];

    if (overlay)
	    [self drawImage:overlay inRect:NSMakeRect(0,0,[newImage size].width,[newImage size].height) onImage:newImage];

    return [self resizeImage:newImage];
}

//Create menu image mask with titles or chapters
- (NSImage *)rootMaskWithTitles:(BOOL)titles withSecondButton:(BOOL)secondButton
{
    NSImage *newImage = [[NSImage alloc] initWithSize: NSMakeSize(720,576)];
    
    float factor;
    if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"KWDVDThemeFormat"] intValue] == 0)
	    factor = 1;
    else
	    factor = 1.5;
    
    NSDictionary *currentTheme = [self currentTheme];

    NSInteger y = [[currentTheme objectForKey:@"KWStartButtonMaskY"] intValue] * factor;

    NSImage *startMaskButtonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWStartButtonMaskImage"]];
    NSRect rect = NSMakeRect([[currentTheme objectForKey:@"KWStartButtonMaskX"] intValue],y-5,[[currentTheme objectForKey:@"KWStartButtonMaskW"] intValue],[[currentTheme objectForKey:@"KWStartButtonMaskH"] intValue] * factor);

    if (!startMaskButtonImage)
	    [self drawBoxInRect:rect lineWidth:[[currentTheme objectForKey:@"KWStartButtonMaskLineWidth"] intValue] onImage:newImage];
    else
	    [self drawImage:startMaskButtonImage inRect:rect onImage:newImage];

    if (titles)
    {
	    if (secondButton)
	    {
    	    NSImage *titleMaskButtonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWTitleButtonMaskImage"]];
    	    NSRect rect = NSMakeRect([[currentTheme objectForKey:@"KWTitleButtonMaskX"] intValue],[[currentTheme objectForKey:@"KWTitleButtonMaskY"] intValue] * factor,[[currentTheme objectForKey:@"KWTitleButtonMaskW"] intValue],[[currentTheme objectForKey:@"KWTitleButtonMaskH"] intValue] * factor);

    	    if (!titleMaskButtonImage)
	    	    [self drawBoxInRect:rect lineWidth:[[currentTheme objectForKey:@"KWTitleButtonMaskLineWidth"] intValue] onImage:newImage];
    	    else
	    	    [self drawImage:titleMaskButtonImage inRect:rect onImage:newImage];
	    }
    }
    else
    {
	    NSImage *chapterMaskButtonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWChapterButtonMaskImage"]];
	    NSRect rect = NSMakeRect([[currentTheme objectForKey:@"KWChapterButtonMaskX"] intValue],[[currentTheme objectForKey:@"KWChapterButtonMaskY"] intValue] * factor,[[currentTheme objectForKey:@"KWChapterButtonMaskW"] intValue],[[currentTheme objectForKey:@"KWChapterButtonMaskH"] intValue] * factor);
    
	    if (!chapterMaskButtonImage)
    	    [self drawBoxInRect:rect lineWidth:[[currentTheme objectForKey:@"KWChapterButtonMaskLineWidth"] intValue] onImage:newImage];
	    else
    	    [self drawImage:chapterMaskButtonImage inRect:rect onImage:newImage];
    }
    
    // TODO: write proper code
    NSImageRep *imageRep = [newImage representations][0];
    CGFloat scale = [imageRep pixelsWide] / 720.0;
    
    NSSize normalSize = NSMakeSize(720.0, 576.0);
    BOOL pal = ([[[NSUserDefaults standardUserDefaults] objectForKey:@"KWDefaultRegion"] intValue] == 0);
    NSSize normalAdjustedSize = NSMakeSize(720.0, pal ? 576.0 : 480.0);
    
    NSSize scaledSize = NSMakeSize(normalSize.width / scale, normalAdjustedSize.height / scale);
    NSImage *scaledImage = [[NSImage alloc] initWithSize:scaledSize];
    
    [scaledImage lockFocus];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationNone];
    [newImage drawInRect:NSMakeRect(0.0, 0.0, scaledSize.width, scaledSize.height) fromRect:NSMakeRect(0.0, 0.0, normalSize.width, normalSize.height) operation:NSCompositeCopy fraction:1.0];
    [scaledImage unlockFocus];

    return scaledImage;
}

//Create menu image
- (NSImage *)selectionMenuWithTitles:(BOOL)titles withObjects:(NSArray *)objects withImages:(NSArray *)images addNext:(BOOL)next addPrevious:(BOOL)previous
{
    NSImage *newImage = nil;
    
    NSDictionary *currentTheme = [self currentTheme];

    if (titles)
	    newImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWAltTitleSelectionImage"]];
    else
	    newImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWAltChapterSelectionImage"]];
    
    if (!newImage)
	    newImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWDefaultImage"]];

    NSInteger x;
    NSInteger y;
    NSInteger newRow = 0;
    NSString *pageKey;

    if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] == 2)
	    pageKey = @"KWSelectionStringsOnAPage";
    else
	    pageKey = @"KWSelectionImagesOnAPage";

    if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] != 2)
    {
	    x = [[currentTheme objectForKey:@"KWSelectionImagesX"] intValue];
	    y = [[currentTheme objectForKey:@"KWSelectionImagesY"] intValue];
    }
    else
    {
	    if ([[currentTheme objectForKey:@"KWSelectionStringsX"] intValue] == -1)
    	    x = 0;
	    else
    	    x = [[currentTheme objectForKey:@"KWSelectionStringsX"] intValue];
    
	    if ([[currentTheme objectForKey:@"KWSelectionStringsY"] intValue] == -1)
	    {
    	    if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"KWDVDThemeFormat"] intValue] == 0)
	    	    y = 576 - (576 - [objects count] * [[currentTheme objectForKey:@"KWSelectionStringsSeperation"] intValue]) / 2;
    	    else
	    	    y = 384 - (384 - [objects count] * [[currentTheme objectForKey:@"KWSelectionStringsSeperation"] intValue]) / 2;
	    }
	    else
	    {
    	    y = [[currentTheme objectForKey:@"KWSelectionStringsY"] intValue];
	    }
    }
    
    NSInteger i;
    for (i=0;i<[objects count];i++)
    {
	    if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] != 2)
	    {
    	    NSImage *previewImage = [images objectAtIndex:i];
    	    float width;
    	    float height;
    
    	    if ([previewImage size].width / [previewImage size].height < 1)
    	    {
	    	    height = [[currentTheme objectForKey:@"KWSelectionImagesH"] intValue];
	    	    width = [[currentTheme objectForKey:@"KWSelectionImagesH"] intValue] * ([previewImage size].width / [previewImage size].height);
    	    }
    	    else
    	    {
	    	    if ([[currentTheme objectForKey:@"KWSelectionImagesW"] intValue] / ([previewImage size].width / [previewImage size].height) <= [[currentTheme objectForKey:@"KWSelectionImagesH"] intValue])
	    	    {
    	    	    width = [[currentTheme objectForKey:@"KWSelectionImagesW"] intValue];
    	    	    height = [[currentTheme objectForKey:@"KWSelectionImagesW"] intValue] / ([previewImage size].width / [previewImage size].height);
	    	    }
	    	    else
	    	    {
    	    	    height = [[currentTheme objectForKey:@"KWSelectionImagesH"] intValue];
    	    	    width = [[currentTheme objectForKey:@"KWSelectionImagesH"] intValue] * ([previewImage size].width / [previewImage size].height);
	    	    }
    	    }
	    
    	    NSRect inputRect = NSMakeRect(0,0,[previewImage size].width,[previewImage size].height);
    	    [newImage lockFocus];
    	    [previewImage drawInRect:NSMakeRect(x + (([[currentTheme objectForKey:@"KWSelectionImagesW"] intValue] - width) / 2),y + (([[currentTheme objectForKey:@"KWSelectionImagesH"] intValue] - height) / 2),width,height) fromRect:inputRect operation:NSCompositeCopy fraction:1.0];
    	    [newImage unlockFocus];
	    }
	    
	    if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] == 0)
	    {
    	    NSString *name;
	    
    	    if (titles)
	    	    name = [[[[objects objectAtIndex:i] objectForKey:@"Path"] lastPathComponent] stringByDeletingPathExtension];
    	    else
	    	    name = [[objects objectAtIndex:i] objectForKey:@"Title"];

    	    [self drawString:name inRect:NSMakeRect(x,y-[[currentTheme objectForKey:@"KWSelectionImagesH"] intValue],[[currentTheme objectForKey:@"KWSelectionImagesW"] intValue],[[currentTheme objectForKey:@"KWSelectionImagesH"] intValue]) onImage:newImage withFontName:[currentTheme objectForKey:@"KWSelectionImagesFont"] withSize:[[currentTheme objectForKey:@"KWSelectionImagesFontSize"] intValue] withColor:[self colourForName:@"KWSelectionImagesFontColor" inTheme:currentTheme] useAlignment:NSCenterTextAlignment];
	    }
	    else if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] == 2)
	    {
    	    NSTextAlignment alignment;
    	    
    	    if ([[currentTheme objectForKey:@"KWSelectionStringsX"] intValue] == -1)
	    	    alignment = NSCenterTextAlignment;
    	    else
	    	    alignment = NSLeftTextAlignment;
    	    
    	    NSString *name;
    	    if (titles)
	    	    name = [[[[objects objectAtIndex:i] objectForKey:@"Path"] lastPathComponent] stringByDeletingPathExtension];
    	    else
	    	    name = [[objects objectAtIndex:i] objectForKey:@"Title"];

    	    [self drawString:name inRect:NSMakeRect(x,y,[[currentTheme objectForKey:@"KWSelectionStringsW"] intValue],[[currentTheme objectForKey:@"KWSelectionStringsH"] intValue]) onImage:newImage withFontName:[currentTheme objectForKey:@"KWSelectionStringsFont"] withSize:[[currentTheme objectForKey:@"KWSelectionStringsFontSize"] intValue] withColor:[self colourForName:@"KWSelectionStringsFontColor" inTheme:currentTheme] useAlignment:alignment];
	    }
    
	    if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] != 2)
	    {
    	    x = x + [[currentTheme objectForKey:@"KWSelectionImagesSeperationW"] intValue];
	    
    	    if (newRow == [[currentTheme objectForKey:@"KWSelectionImagesOnARow"] intValue]-1)
    	    {
	    	    y = y - [[currentTheme objectForKey:@"KWSelectionImagesSeperationH"] intValue];
	    	    x = [[currentTheme objectForKey:@"KWSelectionImagesX"] intValue];
	    	    newRow = 0;
    	    }
    	    else
    	    {
	    	    newRow = newRow + 1;
    	    }
	    
	    }
	    else
	    {
    	    y = y - [[currentTheme objectForKey:@"KWSelectionStringsSeperation"] intValue];
	    }
    }
    
    if (![[currentTheme objectForKey:@"KWPreviousButtonDisable"] boolValue] && previous)
    {
	    NSImage *previousButtonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWPreviousButtonImage"]];
	    NSRect rect = NSMakeRect([[currentTheme objectForKey:@"KWPreviousButtonX"] intValue],[[currentTheme objectForKey:@"KWPreviousButtonY"] intValue],[[currentTheme objectForKey:@"KWPreviousButtonW"] intValue],[[currentTheme objectForKey:@"KWPreviousButtonH"] intValue]);

	    if (!previousButtonImage)
    	    [self drawString:[currentTheme objectForKey:@"KWPreviousButtonString"] inRect:rect onImage:newImage withFontName:[currentTheme objectForKey:@"KWPreviousButtonFont"] withSize:[[currentTheme objectForKey:@"KWPreviousButtonFontSize"] intValue] withColor:[self colourForName:@"KWPreviousButtonFontColor" inTheme:currentTheme] useAlignment:NSCenterTextAlignment];
	    else
    	    [self drawImage:previousButtonImage inRect:rect onImage:newImage];
    }

    if (![[currentTheme objectForKey:@"KWNextButtonDisable"] boolValue] && next)
    {
	    NSImage *nextButtonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWNextButtonImage"]];
	    NSRect rect = NSMakeRect([[currentTheme objectForKey:@"KWNextButtonX"] intValue],[[currentTheme objectForKey:@"KWNextButtonY"] intValue],[[currentTheme objectForKey:@"KWNextButtonW"] intValue],[[currentTheme objectForKey:@"KWNextButtonH"] intValue]);

	    if (!nextButtonImage)
    	    [self drawString:[currentTheme objectForKey:@"KWNextButtonString"] inRect:rect onImage:newImage withFontName:[currentTheme objectForKey:@"KWNextButtonFont"] withSize:[[currentTheme objectForKey:@"KWNextButtonFontSize"] intValue] withColor:[self colourForName:@"KWNextButtonFontColor" inTheme:currentTheme] useAlignment:NSCenterTextAlignment];
	    else
    	    [self drawImage:nextButtonImage inRect:rect onImage:newImage];
    }

    if (!titles)
    {
	    if (![[currentTheme objectForKey:@"KWChapterSelectionDisable"] boolValue])
	    {
    	    NSImage *chapterSelectionButtonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWChapterSelectionImage"]];
    	    NSRect rect = NSMakeRect([[currentTheme objectForKey:@"KWChapterSelectionX"] intValue],[[currentTheme objectForKey:@"KWChapterSelectionY"] intValue],[[currentTheme objectForKey:@"KWChapterSelectionW"] intValue],[[currentTheme objectForKey:@"KWChapterSelectionH"] intValue]);

    	    if (!chapterSelectionButtonImage)
	    	    [self drawString:[currentTheme objectForKey:@"KWChapterSelectionString"] inRect:rect onImage:newImage withFontName:[currentTheme objectForKey:@"KWChapterSelectionFont"] withSize:[[currentTheme objectForKey:@"KWChapterSelectionFontSize"] intValue] withColor:[self colourForName:@"KWChapterSelectionFontColor" inTheme:currentTheme] useAlignment:NSCenterTextAlignment];
    	    else
	    	    [self drawImage:chapterSelectionButtonImage inRect:rect onImage:newImage];
	    }
    }
    else
    {
	    if (![[currentTheme objectForKey:@"KWTitleSelectionDisable"] boolValue])
	    {
    	    NSImage *titleSelectionButtonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWTitleSelectionImage"]];
    	    NSRect rect = NSMakeRect([[currentTheme objectForKey:@"KWTitleSelectionX"] intValue],[[currentTheme objectForKey:@"KWTitleSelectionY"] intValue],[[currentTheme objectForKey:@"KWTitleSelectionW"] intValue],[[currentTheme objectForKey:@"KWTitleSelectionH"] intValue]);

    	    if (!titleSelectionButtonImage)
	    	    [self drawString:[currentTheme objectForKey:@"KWTitleSelectionString"] inRect:rect onImage:newImage withFontName:[currentTheme objectForKey:@"KWTitleSelectionFont"] withSize:[[currentTheme objectForKey:@"KWTitleSelectionFontSize"] intValue] withColor:[self colourForName:@"KWTitleSelectionFontColor" inTheme:currentTheme] useAlignment:NSCenterTextAlignment];
    	    else
	    	    [self drawImage:titleSelectionButtonImage inRect:rect onImage:newImage];
	    }
    }

    NSImage *overlay = nil;
    
	    if (titles)
    	    overlay = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWTitleSelectionOverlayImage"]];
	    else
    	    overlay = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWChapterSelectionOverlayImage"]];

    if (overlay)
	    [self drawImage:overlay inRect:NSMakeRect(0,0,[newImage size].width,[newImage size].height) onImage:newImage];

    return [self resizeImage:newImage];
}

//Create menu mask
- (NSImage *)selectionMaskWithTitles:(BOOL)titles withObjects:(NSArray *)objects addNext:(BOOL)next addPrevious:(BOOL)previous
{
    NSImage *newImage;
    
    NSDictionary *currentTheme = [self currentTheme];

    //if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"KWDVDThemeFormat"] intValue] == 0)
	    newImage = [[NSImage alloc] initWithSize: NSMakeSize(720,576)];
    //else
    //newImage = [[[NSImage alloc] initWithSize: NSMakeSize(720,384)] autorelease];
    
    float factor;
    if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"KWDVDThemeFormat"] intValue] == 0)
	    factor = 1;
    else
	    factor = 1.5;
    
    NSInteger newRow = 0;
    NSInteger x;
    NSInteger y;

    NSString *pageKey;

    if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] == 2)
	    pageKey = @"KWSelectionStringsOnAPage";
    else
	    pageKey = @"KWSelectionImagesOnAPage";

    if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] != 2)
    {
	    x = [[currentTheme objectForKey:@"KWSelectionImagesMaskX"] intValue];
	    y = [[currentTheme objectForKey:@"KWSelectionImagesMaskY"] intValue] * factor;
    }
    else
    {
	    if ([[currentTheme objectForKey:@"KWSelectionStringsMaskX"] intValue] == -1)
    	    x = (720 - [[currentTheme objectForKey:@"KWSelectionStringsMaskW"] intValue]) / 2;
	    else
    	    x = [[currentTheme objectForKey:@"KWSelectionStringsMaskX"] intValue];
    
	    if ([[currentTheme objectForKey:@"KWSelectionStringsMaskY"] intValue] == -1)
	    {
            if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"KWDVDThemeFormat"] intValue] == 0)
    	        y = 576 - (576 - [objects count] * ([[currentTheme objectForKey:@"KWSelectionStringsMaskSeperation"] intValue] * factor)) / 2;
            else
                y = 384 - (384 - [objects count] * ([[currentTheme objectForKey:@"KWSelectionStringsMaskSeperation"] intValue] * factor)) / 2;
	    }
	    else
	    {
    	    y = [[currentTheme objectForKey:@"KWSelectionImagesMaskY"] intValue] * factor;
	    }
    }
    
    NSInteger i;
    for (i=0;i<[objects count];i++)
    {
	    if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] == 2)
	    {
    	    NSImage *selectionStringsMaskButtonImage  = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWSelectionStringsImage"]];
    	    NSRect rect = NSMakeRect(x,y,[[currentTheme objectForKey:@"KWSelectionStringsMaskW"] intValue],[[currentTheme objectForKey:@"KWSelectionStringsMaskH"] intValue] * factor);
	    
    	    if (!selectionStringsMaskButtonImage)
	    	    [self drawBoxInRect:rect lineWidth:[[currentTheme objectForKey:@"KWSelectionStringsMaskLineWidth"] intValue] onImage:newImage];
    	    else
	    	    [self drawImage:selectionStringsMaskButtonImage inRect:rect onImage:newImage];
	    }
	    else
	    {
    	    NSImage *selectionImageMaskButtonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWSelectionImagesImage"]];
    	    NSRect rect = NSMakeRect(x,y,[[currentTheme objectForKey:@"KWSelectionImagesMaskW"] intValue],[[currentTheme objectForKey:@"KWSelectionImagesMaskH"] intValue] * factor);
	    
    	    if (!selectionImageMaskButtonImage)
	    	    [self drawBoxInRect:rect lineWidth:[[currentTheme objectForKey:@"KWSelectionImagesMaskLineWidth"] intValue] onImage:newImage];
    	    else
	    	    [self drawImage:selectionImageMaskButtonImage inRect:rect onImage:newImage];
	    }
    
	    if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] != 2)
	    {
    	    x = x + [[currentTheme objectForKey:@"KWSelectionImagesMaskSeperationW"] intValue];
    
    	    if (newRow == [[currentTheme objectForKey:@"KWSelectionImagesOnARow"] intValue]-1)
    	    {
	    	    y = y - [[currentTheme objectForKey:@"KWSelectionImagesMaskSeperationH"] intValue] * factor;
	    	    x = [[currentTheme objectForKey:@"KWSelectionImagesMaskX"] intValue];
	    	    newRow = 0;
    	    }
    	    else
    	    {
	    	    newRow = newRow + 1;
    	    }
	    }
	    else
	    {
    	    y = y - [[currentTheme objectForKey:@"KWSelectionStringsMaskSeperation"] intValue] * factor;
	    }
    }
    
	    if (previous)
	    {
    	    NSImage *previousMaskButtonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWPreviousButtonMaskImage"]];
    	    NSRect rect = NSMakeRect([[currentTheme objectForKey:@"KWPreviousButtonMaskX"] intValue],[[currentTheme objectForKey:@"KWPreviousButtonMaskY"] intValue] * factor,[[currentTheme objectForKey:@"KWPreviousButtonMaskW"] intValue],[[currentTheme objectForKey:@"KWPreviousButtonMaskH"] intValue] * factor);
    
    	    if (!previousMaskButtonImage)
	    	    [self drawBoxInRect:rect lineWidth:[[currentTheme objectForKey:@"KWPreviousButtonMaskLineWidth"] intValue] onImage:newImage];
    	    else
	    	    [self drawImage:previousMaskButtonImage inRect:rect onImage:newImage];
	    }
    
	    if (next)
	    {
    	    NSImage *nextMaskButtonImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWNextButtonMaskImage"]];
    	    NSRect rect = NSMakeRect([[currentTheme objectForKey:@"KWNextButtonMaskX"] intValue],[[currentTheme objectForKey:@"KWNextButtonMaskY"] intValue] * factor,[[currentTheme objectForKey:@"KWNextButtonMaskW"] intValue],[[currentTheme objectForKey:@"KWNextButtonMaskH"] intValue] * factor);
    
    	    if (!nextMaskButtonImage)
	    	    [self drawBoxInRect:rect lineWidth:[[currentTheme objectForKey:@"KWNextButtonMaskLineWidth"] intValue] onImage:newImage];
    	    else
	    	    [self drawImage:nextMaskButtonImage inRect:rect onImage:newImage];
	    }
    
    // TODO: write proper code
    NSImageRep *imageRep = [newImage representations][0];
    CGFloat scale = [imageRep pixelsWide] / 720.0;
    
    NSSize normalSize = NSMakeSize(720.0, 576.0);
    BOOL pal = ([[[NSUserDefaults standardUserDefaults] objectForKey:@"KWDefaultRegion"] intValue] == 0);
    NSSize normalAdjustedSize = NSMakeSize(720.0, pal ? 576.0 : 480.0);
    
    NSSize scaledSize = NSMakeSize(normalSize.width / scale, normalAdjustedSize.height / scale);
    NSImage *scaledImage = [[NSImage alloc] initWithSize:scaledSize];
    
    [scaledImage lockFocus];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationNone];
    [newImage drawInRect:NSMakeRect(0.0, 0.0, scaledSize.width, scaledSize.height) fromRect:NSMakeRect(0.0, 0.0, normalSize.width, normalSize.height) operation:NSCompositeCopy fraction:1.0];
    [scaledImage unlockFocus];
	    
    return scaledImage;
}

///////////////////
// Other Actions //
///////////////////

#pragma mark -
#pragma mark •• Other actions

- (NSImage *)getPreviewImageFromTheme:(NSDictionary *)currentTheme ofType:(NSInteger)type
{
    NSImage *image;

    if (type == 0)
    {
	    image = [self rootMenuWithTitles:YES withName:NSLocalizedString(@"Title Menu",nil) withSecondButton:YES];
    }
    else if (type == 1)
    {
	    image = [self rootMenuWithTitles:NO withName:NSLocalizedString(@"Chapter Menu",nil) withSecondButton:YES];
    }
    else if (type == 2 || type == 3)
    {
	    NSInteger number;
	    if ([[currentTheme objectForKey:@"KWSelectionMode"] intValue] != 2)
    	    number = [[currentTheme objectForKey:@"KWSelectionImagesOnAPage"] intValue];
	    else
    	    number = [[currentTheme objectForKey:@"KWSelectionStringsOnAPage"] intValue];
    
	    NSMutableArray *images = [NSMutableArray array];
	    NSMutableArray *nameArray = [NSMutableArray array];
    
	    NSInteger i;
	    for (i=0;i<number;i++)
	    {
    	    NSMutableDictionary *nameDict = [NSMutableDictionary dictionary];
    
    	    [images addObject:[self previewImage]];
    
    	    NSString *name = NSLocalizedString(@"Preview",nil);
    
    	    if (type == 2)
	    	    [nameDict setObject:name forKey:@"Path"];
    	    else
	    	    [nameDict setObject:name forKey:@"Title"];
    
    	    [nameArray addObject:nameDict];
	    }

	    if (type == 2)
    	    image = [self selectionMenuWithTitles:YES withObjects:nameArray withImages:images addNext:YES addPrevious:YES];
	    else
    	    image = [self selectionMenuWithTitles:NO withObjects:nameArray withImages:images addNext:YES addPrevious:YES];
    }
    
    if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"KWDVDThemeFormat"] intValue] == 1)
    {
	    [image setSize:NSMakeSize(720,404)];
    }
    
    return image;    
}

- (NSImage *)previewImage
{
    NSImage *newImage = [[NSImage alloc] initWithSize: NSMakeSize(320,240)];

    [newImage lockFocus];
    [[NSColor whiteColor] set];
    NSBezierPath *path;
    path = [NSBezierPath bezierPathWithRect:NSMakeRect(0,0,320,240)];
    [path fill];
    [[NSImage imageNamed:@"Theme document"] drawInRect:NSMakeRect(96,56,128,128) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
    [newImage unlockFocus];
    
    // TODO: write proper code
    NSImageRep *imageRep = [newImage representations][0];
    CGFloat scale = [imageRep pixelsWide] / 320.0;
    
    NSSize normalSize = NSMakeSize(320.0, 240.0);
    NSSize scaledSize = NSMakeSize(normalSize.width / scale, normalSize.height / scale);
    NSImage *scaledImage = [[NSImage alloc] initWithSize:scaledSize];
    
    [scaledImage lockFocus];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationNone];
    [newImage drawInRect:NSMakeRect(0.0, 0.0, scaledSize.width, scaledSize.height) fromRect:NSMakeRect(0.0, 0.0, normalSize.width, normalSize.height) operation:NSCompositeCopy fraction:1.0];
    [scaledImage unlockFocus];

    return scaledImage;
}

- (void)drawString:(NSString *)string inRect:(NSRect)rect onImage:(NSImage *)image withFontName:(NSString *)fontName withSize:(NSInteger)size withColor:(NSColor *)color useAlignment:(NSTextAlignment)alignment
{
    NSFont *labelFont = [NSFont fontWithName:fontName size:size];
    NSMutableParagraphStyle *centeredStyle = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    [centeredStyle setAlignment:alignment];
    NSDictionary *attsDict = [NSDictionary dictionaryWithObjectsAndKeys:centeredStyle, NSParagraphStyleAttributeName,color, NSForegroundColorAttributeName, labelFont, NSFontAttributeName, [NSNumber numberWithInt:NSUnderlineStyleNone], NSUnderlineStyleAttributeName, nil];
    centeredStyle = nil;
	    
    [image lockFocus];
    [string drawInRect:rect withAttributes:attsDict]; 
    [image unlockFocus];
}

- (void)drawBoxInRect:(NSRect)rect lineWidth:(NSInteger)width onImage:(NSImage *)image
{
    [image lockFocus];
    [[NSGraphicsContext currentContext] setShouldAntialias:NO];
    [[NSColor whiteColor] set];
    NSBezierPath *path = [NSBezierPath bezierPathWithRect:rect];
    [path setLineWidth:width]; 
    [path stroke];
    [image unlockFocus];
}

- (void)drawImage:(NSImage *)drawImage inRect:(NSRect)rect onImage:(NSImage *)image
{
    [image lockFocus];
    [drawImage drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    [image unlockFocus];
}

- (NSImage *)resizeImage:(NSImage *)image
{
    // TODO: rewrite
    NSImage *resizedImage = [[NSImage alloc] initWithSize: NSMakeSize(720, 576.0)];
    
    NSImageRep *imageRep = [image representations][0];
    CGFloat scale = [imageRep pixelsWide] / 720.0;
    
    NSSize normalSize = NSMakeSize(720.0, 576.0);
    NSSize scaledSize = NSMakeSize(normalSize.width / scale, normalSize.height / scale);
    
    resizedImage = [[NSImage alloc] initWithSize:scaledSize];
    
    NSSize originalSize = [image size];

    [resizedImage lockFocus];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationNone];
    [image drawInRect: NSMakeRect(0, 0, scaledSize.width, scaledSize.height) fromRect: NSMakeRect(0, 0, originalSize.width, originalSize.height) operation:NSCompositeSourceOver fraction: 1.0];
    [resizedImage unlockFocus];

    return resizedImage;
}

- (NSImage *)imageForAudioTrackWithName:(NSString *)name withTheme:(NSDictionary *)currentTheme
{
    NSImage *newImage = [[NSImage alloc] initWithData:[currentTheme objectForKey:@"KWDefaultImage"]];
    
    if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"KWDVDThemeFormat"] intValue] == 0)
    {
	    [self drawString:@"♫" inRect:NSMakeRect(20, ((NSInteger)[newImage size].height - 600) / 2 , (NSInteger)[newImage size].width - 40, 600) onImage:newImage withFontName:[currentTheme objectForKey:@"KWDVDNameFont"] withSize:400 withColor:[self colourForName:@"KWDVDNameFontColor" inTheme:currentTheme] useAlignment:NSCenterTextAlignment];
	    [self drawString:name inRect:NSMakeRect(62, 56, 720, 30) onImage:newImage withFontName:[currentTheme objectForKey:@"KWDVDNameFont"] withSize:24 withColor:[self colourForName:@"KWDVDNameFontColor" inTheme:currentTheme] useAlignment:NSLeftTextAlignment];
    }
    else
    {
	    [self drawString:@"♫" inRect:NSMakeRect(20, ((NSInteger)[newImage size].height - 420) / 2 , (NSInteger)[newImage size].width - 40, 420) onImage:newImage withFontName:[currentTheme objectForKey:@"KWDVDNameFont"] withSize:300 withColor:[self colourForName:@"KWDVDNameFontColor" inTheme:currentTheme] useAlignment:NSCenterTextAlignment];
	    [self drawString:name inRect:NSMakeRect(42, 38, 720, 24) onImage:newImage withFontName:[currentTheme objectForKey:@"KWDVDNameFont"] withSize:16 withColor:[self colourForName:@"KWDVDNameFontColor" inTheme:currentTheme] useAlignment:NSLeftTextAlignment];
    }
    
    return newImage;//[self resizeImage:newImage];
}

- (NSColor *)colourForName:(NSString *)name inTheme:(NSDictionary *)theme
{
    NSData *colourData = theme[name];
    if (colourData != nil)
    {
        return (NSColor *)[NSUnarchiver unarchiveObjectWithData:colourData];
    }
    
    return [NSColor whiteColor];
}

@end
