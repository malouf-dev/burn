/* KWApplication */

#import <Cocoa/Cocoa.h>
#import "KWPreferences.h"
#import "KWRecorderInfo.h"
#import "KWDiscInfo.h"
#import "KWEjecter.h"
#import "KWInspector.h"

@interface KWApplication : NSObject
{
    //Variables
    KWPreferences *preferences;
    KWRecorderInfo *recorderInfo;
    KWDiscInfo *diskInfo;
    KWEjecter *ejecter;
    KWInspector *inspector;
    
    //Inspector variables
    id currentObject;
    NSString *currentType;
}

@end
