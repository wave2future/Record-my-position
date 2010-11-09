/** \mainpage Record my position
 *
 * \section meta Meta
 *
 * You are reading the autogenerated Doxygen documentation extracted
 * from the project. Source code can be found at:
 * http://github.com/gradha/Record-my-position
 *
 * \section external-libs External libraries
 * Sqlite disk access is controlled through the singleton like DB
 * class built on top of a fork (http://github.com/gradha/egodatabase)
 * of the EGODatabase (http://developers.enormego.com/code/egodatabase/)
 * from enormego (http://enormego.com/).
 *
 * Fragments of code from a private library by Grzegorz Adam
 * Hankiewicz from Electric Hands Software (http://elhaso.com/) have
 * made it to Floki for hardware UDID detection. See licensing
 * information under \c external/egf/readme.txt.
 */

#import "App_delegate.h"

#import "GPS.h"
#import "Tab_controller.h"
#import "db/DB.h"
#import "macro.h"


// Forward private declarations.
static void _set_globals(void);


@implementation App_delegate

@synthesize db = db_;


#pragma mark -
#pragma mark Application lifecycle

- (BOOL)application:(UIApplication *)application
	didFinishLaunchingWithOptions:(NSDictionary *)launch_options
{
	DLOG(@"Lunching application with %@", launch_options);

	[[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
	_set_globals();

	window_ = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	window_.backgroundColor = [UIColor whiteColor];

	db_ = [DB open_database];
	if (!db_) {
		[self handle_error:@"Couldn't open database" abort:YES];
		return NO;
	}

	// For the moment we don't know what to do with this...
	if (launch_options)
		[db_ log:[NSString stringWithFormat:@"Launch options? %@",
			launch_options]];

	tab_controller_ = [Tab_controller new];
	[window_ addSubview:tab_controller_.view];

	[window_ makeKeyAndVisible];

	return YES;
}

/** Something stole the focus of the application.
 * Or the user might have locked the screen. Change to medium gps tracking.
 */
- (void)applicationWillResignActive:(UIApplication *)application
{
	[[GPS get] set_accuracy:MEDIUM_ACCURACY reason:@"Lost focus."];
	[db_ flush];
}

/** The application regained focus.
 * This is the pair to applicationWillResignActive.
 */
- (void)applicationWillEnterForeground:(UIApplication *)application
{
	[[GPS get] set_accuracy:HIGH_ACCURACY reason:@"Gained focus."];
}

/** The user quit the app, and we are supporting background operation.
 * Suspend GUI dependant timers and log status change.
 *
 * This method is only called if the app is running on a device
 * supporting background operation. Otherwise applicationWillTerminate
 * will be called instead.
 */
- (void)applicationDidEnterBackground:(UIApplication *)application
{
	db_.in_background = YES;
	[[GPS get] set_accuracy:LOW_ACCURACY reason:@"Entering background mode."];
	[db_ flush];
}

/** We were raised from the dead.
 * Revert bad stuff done in applicationDidEnterBackground to be nice.
 */
- (void)applicationDidBecomeActive:(UIApplication *)application
{
	db_.in_background = NO;
	[[GPS get] set_accuracy:HIGH_ACCURACY reason:@"Raising from background."];
}

/** Application shutdown. Save cache and stuff...
 * Note that the method could be called even during initialisation,
 * so you can't make any guarantees about objects being available.
 *
 * If background running is supported, applicationDidEnterBackground
 * is used instead.
 */
- (void)applicationWillTerminate:(UIApplication *)application
{
	if ([GPS get].gps_is_on)
		[db_ log:@"Terminating app while GPS was on..."];

	[db_ flush];
	[db_ close];

	// Save pending changes to user defaults.
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults synchronize];
}

#pragma mark -
#pragma mark Memory management

/** Low on memory. Try to free as much as we can.
 */
- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
	[db_ flush];
}

- (void)dealloc
{
	[tab_controller_ release];
	[window_ release];
	[super dealloc];
}

#pragma mark Normal methods

/** Handle reporting of errors to the user.
 * Pass the message for the error and a boolean telling to force
 * exit or let the user acknowledge the problem.
 */
- (void)handle_error:(NSString*)message abort:(BOOL)abort
{
	if (abort)
		abort_after_alert_ = YES;

	UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Error"
		message:NON_NIL_STRING(message) delegate:self
		cancelButtonTitle:(abort ? @"Abort" : @"OK") otherButtonTitles:nil];
	[alert show];
	[alert release];
	DLOG(@"Error: %@", message);
}

/** Forces a deletion of the database.
 * The database will be recreated automatically. GPS detection will
 * be disabled for a moment to avoid race conditions.
 */
- (void)purge_database
{
	DLOG(@"Purging database.");
	[db_ flush];
	[db_ close];
	GPS *gps = [GPS get];
	const BOOL activate = gps.gps_is_on;
	[gps stop];

	[DB purge];

	db_ = [DB open_database];
	if (activate)
		[gps start];
}

#pragma mark UIAlertViewDelegate protocol

- (void)alertView:(UIAlertView *)alertView
	clickedButtonAtIndex:(NSInteger)buttonIndex
{
	if (abort_after_alert_) {
		DLOG(@"User closed dialog which aborts program. Bye bye!");
		exit(1);
	}
}

@end

#pragma mark Global functions

BOOL g_is_multitasking = NO;
BOOL g_location_changes = NO;
BOOL g_region_monitoring = NO;

/** Builds up the path of a file in a specific directory.
 * Note that making a path inside a DIR_BUNDLE will always fail if the file
 * doesn't exist (bundles are not allowed to be modified), while a path for
 * DIR_DOCS may succeed even if the file doesn't yet exists (useful to create
 * persistant configuration files).
 *
 * \return Returns an NSString with the path, or NULL if there was an error.
 * If you want to use the returned path with C functions, you will likely
 * call the method cStringUsingEncoding:1 on the returned object.
 */
NSString *get_path(NSString *filename, DIR_TYPE dir_type)
{
	switch (dir_type) {
		case DIR_BUNDLE:
		{
			NSString *path = [[NSBundle mainBundle]
				pathForResource:filename ofType:nil];

			if (!path)
				DLOG(@"File '%@' not found inside bundle!", filename);

			return path;
		}

		case DIR_DOCS:
		{
			NSArray *paths = NSSearchPathForDirectoriesInDomains(
				NSDocumentDirectory, NSUserDomainMask, YES);
			NSString *documentsDirectory = [paths objectAtIndex:0];
			NSString *path = [documentsDirectory
				stringByAppendingPathComponent:filename];

			if (!path)
				DLOG(@"File '%@' not found inside doc directory!", filename);

			return path;
		}

		default:
			DLOG(@"Trying to use dir_type %d", dir_type);
			assert(0 && "Invalid get_path(dir_type).");
			return 0;
	}
}

/** Updates the state of some global variables.
 * These are variables like g_is_multitasking, which can be read
 * by any one any time. Call this function whenever you want,
 * preferably during startup.
 */
static void _set_globals(void)
{
	UIDevice* device = [UIDevice currentDevice];

	if ([device respondsToSelector:@selector(isMultitaskingSupported)])
		g_is_multitasking = device.multitaskingSupported;
	else
		g_is_multitasking = NO;

	g_location_changes = NO;
	SEL getter = @selector(significantLocationChangeMonitoringAvailable);
	if ([CLLocationManager respondsToSelector:getter])
		if ([CLLocationManager performSelector:getter])
			g_location_changes = YES;

	getter = @selector(regionMonitoringAvailable);
	if ([CLLocationManager respondsToSelector:getter])
		if ([CLLocationManager performSelector:getter])
			g_region_monitoring = YES;
}

// vim:tabstop=4 shiftwidth=4 encoding=utf-8 syntax=objc
