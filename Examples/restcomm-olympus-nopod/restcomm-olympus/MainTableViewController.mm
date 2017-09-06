/*
 * TeleStax, Open Source Cloud Communications
 * Copyright 2011-2015, Telestax Inc and individual contributors
 * by the @authors tag.
 *
 * This program is free software: you can redistribute it and/or modify
 * under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation; either version 3 of
 * the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>
 *
 * For questions related to commercial use licensing, please contact sales@telestax.com.
 *
 */

#import "MainNavigationController.h"
#import "SettingsTableViewController.h"
#import "CallViewController.h"
#import "MessageTableViewController.h"
#import "MainTableViewController.h"
#import "ContactDetailsTableViewController.h"
#import "ContactUpdateTableViewController.h"

#import "ToastController.h"
#import "RestCommClient.h"
#import "RCUtilities.h"
#import "Utils.h"

#import <Contacts/Contacts.h>
#import "LocalContact.h"


@interface MainTableViewController ()
@property RCDeviceState previousDeviceState;

@property (nonatomic, strong) CNContactStore *contactsStore;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;

@end

@implementation MainTableViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    UIColor *grey = [UIColor colorWithRed:109.0/255.0 green:110.0/255.0 blue:112/255.0 alpha:255.0/255.0];
    [[UIBarButtonItem appearance] setBackButtonTitlePositionAdjustment:UIOffsetMake(0, -60)
                                                         forBarMetrics:UIBarMetricsDefault];
    self.navigationController.navigationBar.tintColor = grey;
    
    UIBarButtonItem * editButton = [self editButtonItem];
    [editButton setTintColor:grey];
    UIBarButtonItem * addButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                target:self
                                                                                action:@selector(invokeCreateContact)];
    [addButton setTintColor:grey];
    
    self.navigationItem.rightBarButtonItems = [[NSArray alloc] initWithObjects:editButton, addButton, nil];
    
    // Uncomment the following line to preserve selection between presentations.
    // self.clearsSelectionOnViewWillAppear = NO;
    
    // remove empty cells from tableview
    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    
    // Uncomment the following line to display an Edit button in the navigation bar for this view controller.
    // self.navigationItem.rightBarButtonItem = self.editButtonItem;
    self.isRegistered = NO;
    self.isInitialized = NO;
    
    
    // TODO: capabilityTokens aren't handled yet
    //NSString* capabilityToken = @"";
    
    self.parameters = [[NSMutableDictionary alloc] initWithObjectsAndKeys:[Utils sipIdentification], @"aor",
                       [Utils sipPassword], @"password",
                       @([Utils turnEnabled]), @"turn-enabled",
                       [Utils turnUrl], @"turn-url",
                       [Utils turnUsername], @"turn-username",
                       [Utils turnPassword], @"turn-password",
                       @(NO), @"signaling-secure",
                       //[cafilePath stringByDeletingLastPathComponent], @"signaling-certificate-dir",
                       //                       @([Utils signalingSecure]), @"signaling-secure",
                       //                       [cafilePath stringByDeletingLastPathComponent], @"signaling-certificate-dir",
                       nil];
    
    [self.parameters setObject:[NSString stringWithFormat:@"%@", [Utils sipRegistrar]] forKey:@"registrar"];
    
    // initialize RestComm Client by setting up an RCDevice
    self.device = [[RCDevice alloc] initWithParams:self.parameters delegate:self];
    
    if (self.device.state == RCDeviceStateOffline) {
        [self updateConnectivityStatus:self.device.state
                   andConnectivityType:self.device.connectivityType
                              withText:@""];
    }
    else {
        [self updateConnectivityStatus:self.device.state
                   andConnectivityType:self.device.connectivityType
                              withText:@""];
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(register:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(unregister:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    self.contactsStore = [[CNContactStore alloc] init];

    //define spinner
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    
    [self checkContactsAccess];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}


#pragma mark - UI events

- (void)register:(NSNotification *)notification
{
    if (self.device && self.isInitialized) {
        [self register];
    }
}

- (void)register
{
    [self.device listen];
    self.isRegistered = YES;
}

- (void)unregister:(NSNotification *)notification
{
    [self.device unlisten];
    self.isRegistered = NO;
}

#pragma mark - Delegate methods for RCDeviceDelegate

- (void)device:(RCDevice*)device didStopListeningForIncomingConnections:(NSError*)error
{
    //NSLog(@"------ didStopListeningForIncomingConnections: error: %p", error);
    // if error is nil then this is not an error condition, but an event that we have stopped listening after user request, like RCDevice.unlinsten
    if (error) {
        [self updateConnectivityStatus:device.state
                   andConnectivityType:device.connectivityType
                              withText:error.localizedDescription];
    }
}

- (void)deviceDidStartListeningForIncomingConnections:(RCDevice*)device
{
    self.isInitialized = YES;
    self.isRegistered = YES;
    
    [self updateConnectivityStatus:device.state
               andConnectivityType:device.connectivityType
                          withText:nil];
    
    NSString * pendingInterapUri = [Utils pendingInterappUri];
    if (pendingInterapUri && ![pendingInterapUri isEqualToString:@""]) {
        // we have a request from another iOS to make a call to the passed URI
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:[[NSBundle mainBundle].infoDictionary objectForKey:@"UIMainStoryboardFile"] bundle:nil];
        CallViewController *callViewController = [storyboard instantiateViewControllerWithIdentifier:@"call-controller"];
        
        callViewController.delegate = self;
        callViewController.device = self.device;
        callViewController.parameters = [[NSMutableDictionary alloc] init];
        [callViewController.parameters setObject:@"make-call" forKey:@"invoke-view-type"];
        
        // search through the contacts if the given URI is known and if so use its alias, if not just use the URI
        NSString * alias = [Utils sipUri2Alias:pendingInterapUri];
        if ([alias isEqualToString:@""]) {
            alias = pendingInterapUri;
        }
        [callViewController.parameters setObject:alias forKey:@"alias"];
        [callViewController.parameters setObject:pendingInterapUri forKey:@"username"];
        [callViewController.parameters setObject:[NSNumber numberWithBool:YES] forKey:@"video-enabled"];
        
        [self presentViewController:callViewController animated:YES completion:nil];
        
        // clear it so that it doesn't pop again
        [Utils updatePendingInterappUri:@""];
    }
}

// received incoming message
- (void)device:(RCDevice *)device didReceiveIncomingMessage:(NSString *)message withParams:(NSDictionary *)params
{
    // Open message view if not already opened
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:[[NSBundle mainBundle].infoDictionary objectForKey:@"UIMainStoryboardFile"] bundle:nil];
    if (![self.navigationController.visibleViewController isKindOfClass:[MessageTableViewController class]]) {
        MessageTableViewController *messageViewController = [storyboard instantiateViewControllerWithIdentifier:@"message-controller"];
        //messageViewController.delegate = self;
        messageViewController.device = self.device;
        messageViewController.delegate = self;
        messageViewController.parameters = [[NSMutableDictionary alloc] init];
        [messageViewController.parameters setObject:message forKey:@"message-text"];
        [messageViewController.parameters setObject:@"receive-message" forKey:@"invoke-view-type"];
        [messageViewController.parameters setObject:[params objectForKey:@"from"] forKey:@"username"];
        [messageViewController.parameters setObject:[RCUtilities usernameFromUri:[params objectForKey:@"from"]] forKey:@"alias"];
        
        messageViewController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [self.navigationController pushViewController:messageViewController animated:YES];
    }
    else {
        // message view already opened, just append
        MessageTableViewController * messageViewController = (MessageTableViewController*)self.navigationController.visibleViewController;
        [messageViewController appendToDialog:message sender:[params objectForKey:@"from"]];
    }
}

// 'ringing' for incoming connections -let's animate the 'Answer' button to give a hint to the user
- (void)device:(RCDevice*)device didReceiveIncomingConnection:(RCConnection*)connection
{
    // Open call view
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:[[NSBundle mainBundle].infoDictionary objectForKey:@"UIMainStoryboardFile"] bundle:nil];
    CallViewController *callViewController = [storyboard instantiateViewControllerWithIdentifier:@"call-controller"];
    callViewController.delegate = self;
    callViewController.device = self.device;
    callViewController.pendingIncomingConnection = connection;
    callViewController.pendingIncomingConnection.delegate = callViewController;
    callViewController.parameters = [[NSMutableDictionary alloc] init];
    [callViewController.parameters setObject:@"receive-call" forKey:@"invoke-view-type"];
    [callViewController.parameters setObject:[connection.parameters objectForKey:@"from"] forKey:@"username"];
    // try to 'resolve' the from to the contact name if we do have a contact for that
    NSString * alias = [Utils sipUri2Alias:[connection.parameters objectForKey:@"from"]];
    if ([alias isEqualToString:@""]) {
        alias = [connection.parameters objectForKey:@"from"];
    }
    [callViewController.parameters setObject:alias forKey:@"alias"];
    
    // TODO: change this once I implement the incoming call caller id
    //[callViewController.parameters setObject:@"CHANGEME" forKey:@"username"];
    
    callViewController.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:callViewController
                       animated:YES
                     completion:nil];
}



- (void)updateConnectivityStatus:(RCDeviceState)state andConnectivityType:(RCDeviceConnectivityType)status withText:(NSString *)text
{
    //NSLog(@"------ updateConnectivityStatus: status: %d, text: %@", status, text);
    NSString * imageName = @"inapp-icon-28x28.png";
    
    UIActivityIndicatorView *activityView = [[UIActivityIndicatorView alloc]
                                             initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    [activityView startAnimating];
    UIBarButtonItem *barIndicator = [[UIBarButtonItem alloc] initWithCustomView:activityView];
    
    NSMutableArray * itemsArray = [[NSMutableArray alloc] init];
    
    NSString * defaultText = nil;
    if (state == RCDeviceStateOffline) {
        defaultText = @"Lost connectivity";
        imageName = @"inapp-grey-icon-28x28.png";
        [itemsArray addObject:barIndicator];
    }
    if (state != RCDeviceStateOffline) {
        if (status == RCDeviceConnectivityTypeWifi) {
            defaultText = @"Reestablished connectivity (Wifi)";
        }
        if (status == RCDeviceConnectivityTypeCellularData) {
            defaultText = @"Reestablished connectivity (Cellular)";
        }
    }
    
    if (!text) {
        text = defaultText;
    }
    
    // Important: use imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal to avoid the default blue tint!
    UIBarButtonItem * restcommIconButton = [[UIBarButtonItem alloc] initWithImage:[[UIImage imageNamed:imageName] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
                                                                            style:UIBarButtonItemStylePlain
                                                                           target:self
                                                                           action:@selector(invokeSettings)];
    
    [itemsArray insertObject:restcommIconButton atIndex:0];
    
    self.navigationItem.leftBarButtonItems = itemsArray;
    
    if (![text isEqualToString:@""] ||
        (![text isEqualToString:@""] && status != self.previousDeviceState)) {
        
        // Let's use toast notifications that are much more suitable now that we implemented them
        [[ToastController sharedInstance] showToastWithText:text withDuration:2.0];
    }
    self.previousDeviceState = state;
}

#pragma mark - SipSettingsDelegate method
// User requested new registration in 'Settings'
- (void)sipSettingsTableViewController:(SipSettingsTableViewController*)sipSettingsTableViewController didUpdateRegistrationWithString:(NSString *)registrar
{
    [self updateConnectivityStatus:RCDeviceStateOffline
               andConnectivityType:RCDeviceConnectivityTypeNone
                          withText:@""];
}


#pragma mark - ContactUpdateDelegate method

- (void)contactUpdateViewController:(ContactUpdateTableViewController*)contactUpdateViewController
          didUpdateContactWithAlias:(NSString *)alias sipUri:(NSString*)sipUri
{
    [self.tableView insertRowsAtIndexPaths:[NSArray arrayWithObject:[NSIndexPath indexPathForRow:[Utils contactCount] - 1 inSection:0]]
                          withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - ContactDetailsDelegate method

- (void)contactDetailsViewController:(ContactDetailsTableViewController*)contactDetailsViewController
           didUpdateContactWithAlias:(NSString *)alias sipUri:(NSString*)sipUri
{
    [self.tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:[NSIndexPath indexPathForRow:[Utils indexForContact:sipUri] inSection:0]]
                          withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - MessageDelegate method

- (void)messageViewController:(MessageTableViewController*)messageViewController
       didAddContactWithAlias:(NSString *)alias sipUri:(NSString*)sipUri
{
    [self.tableView insertRowsAtIndexPaths:[NSArray arrayWithObject:[NSIndexPath indexPathForRow:[Utils contactCount] - 1 inSection:0]]
                          withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Table view data source

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [Utils contactCount];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"contact-reuse-identifier" forIndexPath:indexPath];
    
    // Configure the cell...
    LocalContact * contact = [Utils contactForIndex: (int)indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", contact.firstName, contact.lastName];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    
    if (contact.phoneNumbers && [contact.phoneNumbers count] > 0){
        cell.detailTextLabel.text = [contact.phoneNumbers objectAtIndex:0];
        if ([contact.phoneNumbers count] > 1){
            UIImage *image = [UIImage imageNamed:@"settings-30x30.png"];
            UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
            
            CGRect frame = CGRectMake(0.0, 0.0, image.size.width, image.size.height);
            button.frame = frame;
            [button setBackgroundImage:image forState:UIControlStateNormal];
            
            [button addTarget:self action:@selector(checkButtonTapped:event:) forControlEvents:UIControlEventTouchUpInside];
            cell.backgroundColor = [UIColor clearColor];
            cell.accessoryView = button;
        }
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    [self performSegueWithIdentifier:@"invoke-messages" sender:indexPath];
}


// Override to support editing the table view.
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        // Delete the row from the data source
        [Utils removeContactAtIndex:(int)indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
        
    } else if (editingStyle == UITableViewCellEditingStyleInsert) {
        // Adding is handled in the separate screen
        // Create a new instance of the appropriate class, insert it into the array, and add a new row to the table view
    }
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath
{
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:[[NSBundle mainBundle].infoDictionary objectForKey:@"UIMainStoryboardFile"] bundle:nil];
    PhoneNumbersViewController *phoneNumbersViewController = (PhoneNumbersViewController *)[storyboard instantiateViewControllerWithIdentifier:@"phone-numbers"];
    phoneNumbersViewController.localContact = [Utils contactForIndex: (int)indexPath.row];
    phoneNumbersViewController.phoneNumbersDelegate = self;
    
    phoneNumbersViewController.preferredContentSize = CGSizeMake(150, [phoneNumbersViewController.localContact.phoneNumbers count] * 50);
    phoneNumbersViewController.modalPresentationStyle = UIModalPresentationPopover;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    
    // configure the Popover presentation controller
    UIPopoverPresentationController *popController = [phoneNumbersViewController popoverPresentationController];
    popController.permittedArrowDirections = UIPopoverArrowDirectionUp;
    popController.delegate = self;
    

    popController.sourceRect = CGRectMake(2, 5, 10, 10);
    popController.sourceView = cell.accessoryView;
    [self presentViewController:phoneNumbersViewController animated:YES completion:nil];
}

-(UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller {
    return UIModalPresentationNone;
}

#pragma mark - AccessoryView button tap
- (void)checkButtonTapped:(id)sender event:(id)event
{
    NSSet *touches = [event allTouches];
    UITouch *touch = [touches anyObject];
    CGPoint currentTouchPosition = [touch locationInView:self.tableView];
    
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint: currentTouchPosition];
    if (indexPath != nil)
    {
        [self tableView: self.tableView accessoryButtonTappedForRowWithIndexPath: indexPath];
    }
}


#pragma mark - PrepareForSegue

- (void) prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    if ([segue.identifier isEqualToString:@"invoke-settings"]) {
        SettingsTableViewController * settingsTableViewController = [segue destinationViewController];
        settingsTableViewController.device = self.device;
    }
    
    if ([segue.identifier isEqualToString:@"invoke-create-contact"]) {
        UINavigationController *contactUpdateNavigationController = [segue destinationViewController];
        ContactUpdateTableViewController * contactUpdateViewController =  [contactUpdateNavigationController.viewControllers objectAtIndex:0];
        contactUpdateViewController.delegate = self;
    }
    
    if ([segue.identifier isEqualToString:@"invoke-messages"]) {
        NSIndexPath * indexPath = sender;
        // retrieve info for the selected contact
        LocalContact * contact = [Utils contactForIndex: (int)indexPath.row];
        
        MessageTableViewController *messageViewController = [segue destinationViewController];
        messageViewController.delegate = self;
        messageViewController.device = self.device;
        messageViewController.parameters = [[NSMutableDictionary alloc] init];
        
        [messageViewController.parameters setObject:[NSString stringWithFormat:@"%@ %@", contact.firstName, contact.lastName] forKey:@"alias"];
        if (contact.phoneNumbers && [contact.phoneNumbers count] > 0){
            [messageViewController.parameters setObject:[contact.phoneNumbers objectAtIndex:0] forKey:@"username"];
        }
        
    }
    
}

#pragma mark - Invoke methods

- (void)invokeSettings
{
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:[[NSBundle mainBundle].infoDictionary objectForKey:@"UIMainStoryboardFile"] bundle:nil];
    SettingsTableViewController *settingsViewController = [storyboard instantiateViewControllerWithIdentifier:@"settings-view-controller"];
    settingsViewController.device = self.device;
    
    [self.navigationController pushViewController:settingsViewController animated:YES];
    
}

- (void)invokeCreateContact
{
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:[[NSBundle mainBundle].infoDictionary objectForKey:@"UIMainStoryboardFile"] bundle:nil];
    // important: we are retrieving the navigation controller that hosts the contact update table view controller (due to the issue we had on the buttons showing wrong)
    UINavigationController *contactUpdateNavigationController = [storyboard instantiateViewControllerWithIdentifier:@"contact-update-nav-controller"];
    ContactUpdateTableViewController * contactUpdateViewController =  [contactUpdateNavigationController.viewControllers objectAtIndex:0];
    contactUpdateViewController.contactEditType = CONTACT_EDIT_TYPE_CREATION;
    contactUpdateViewController.delegate = self;
    
    [self presentViewController:contactUpdateNavigationController animated:YES completion:nil];
}

#pragma mark - Rotation/Orientation

- (BOOL)shouldAutorotate
{
    return YES;
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskPortraitUpsideDown;
}

#pragma mark - Contacts access request

-(void)checkContactsAccess{
    [self showSpinner];
    [self requestContactsAccessWithHandler:^(BOOL granted) {
        if (granted) {
                CNContactFetchRequest *request = [[CNContactFetchRequest alloc] initWithKeysToFetch:
                                                  @[CNContactFamilyNameKey, CNContactGivenNameKey,
                                                    CNContactNamePrefixKey, CNContactMiddleNameKey, CNContactPhoneNumbersKey]];
                
                [self.contactsStore enumerateContactsWithFetchRequest:request error:nil usingBlock:^(CNContact * _Nonnull contact, BOOL * _Nonnull stop) {
                    
                    NSMutableArray *phoneNumbers = [[NSMutableArray alloc] init];
                    LocalContact *localContact = [[LocalContact alloc] init];
                    localContact.firstName = contact.givenName;
                    localContact.lastName = contact.familyName;
                    
                    if (contact.phoneNumbers.count > 0) {
                        for (int i=0; i<contact.phoneNumbers.count; i++){
                            //add numbers to array
                            CNPhoneNumber *phoneNumber = (CNPhoneNumber *)contact.phoneNumbers[i].value;
                            [phoneNumbers addObject:[phoneNumber valueForKey:@"digits"]];
                        }
                        localContact.phoneNumbers = [NSArray arrayWithArray:phoneNumbers];
                    }
                    [Utils addContact:localContact];
                }];
                
                dispatch_async( dispatch_get_main_queue(), ^{
                    [self hideSpinner];
                    [self.tableView reloadData];
                });
        } else {
            dispatch_async( dispatch_get_main_queue(), ^{
                [self hideSpinner];
            });
        }
    }];
}

-(void)requestContactsAccessWithHandler:(void (^)(BOOL granted))handler{
    switch ([CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]) {
        case CNAuthorizationStatusAuthorized:
            handler(YES);
            break;
        case CNAuthorizationStatusDenied:
        case CNAuthorizationStatusNotDetermined:{
            [self.contactsStore requestAccessForEntityType:CNEntityTypeContacts completionHandler:^(BOOL granted, NSError * _Nullable error) {
                handler(granted);
            }];
            break;
        }
        case CNAuthorizationStatusRestricted:
            handler(NO);
            break;
    }
};

#pragma mark - PhoneNumbersDelegate method

- (void) onPhoneNumberTap:(NSString *)alias andSipUri:(NSString *)sipUri{
    NSLog(@"%@ %@", alias, sipUri);
    
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:[[NSBundle mainBundle].infoDictionary objectForKey:@"UIMainStoryboardFile"] bundle:nil];
    MessageTableViewController *messageViewController = [storyboard instantiateViewControllerWithIdentifier:@"message-controller"];
    
    messageViewController.delegate = self;
    messageViewController.device = self.device;
    messageViewController.parameters = [[NSMutableDictionary alloc] init];
    
    [messageViewController.parameters setObject:alias forKey:@"alias"];
    [messageViewController.parameters setObject:sipUri forKey:@"username"];
    
    [self.navigationController pushViewController:messageViewController animated:YES];

}

#pragma mark - Spinner

-(void) showSpinner{
    self.spinner.center = self.view.center;
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
    [self.view bringSubviewToFront:self.spinner];
    
    [self.spinner startAnimating];
}

-(void) hideSpinner{
    [self.spinner removeFromSuperview];
}

@end
