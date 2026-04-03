public class SelfRegistrationController {
    public String firstName {get; set;}
    public String lastName {get; set;}
    public String email {get; set;}
    public String password {get; set {password = value == null ? value : value.trim(); } }
    public String confirmPassword {get; set { confirmPassword = value == null ? value : value.trim(); } }
    
    public Boolean initSelfRegistration {get; set;}
    public String identifier {get; set;}
    public User u {get; set;}
    public Id accountId {get; set;}
    
    private final Long CURRENT_TIME = Datetime.now().getTime();
    private final String[] UPPERCASE_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('');
    private final String[] LOWERCASE_CHARS = 'abcdefghijklmnopqrstuvwxyz'.split('');
    private final String[] NUMBER_CHARS = '1234567890'.split('');
    private final String[] SPECIAL_CHARS = '!#$%-_=+<>'.split('');
    Private final String PROFILE_NAME='';
    
    public SelfRegistrationController() {
        System.debug('Password '+password);
    }
    public PageReference registerUser() {
        
        Profile profile = [SELECT Id, Name FROM Profile where Name ='EE Program Participate'];
        Account account = [Select Id, Name, OwnerID From Account where Name='Need to Update' Limit 1];
        accountId = account.Id;
        
        try{
            u = new User();
            if(String.isBlank(firstName)){
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR,'First Name is required.'));
            }
            if(String.isBlank(lastName)){
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR,'Last Name is required.'));
            }
            if(String.isBlank(email)){
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR,'Email Address is required.'));
            }
            if (String.isBlank(password)) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR,'Your password must be at least 8 characters - including one capital letter, one number and one special character.'));
            }
            if (String.isBlank(confirmPassword)) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR,'Your password must be at least 8 characters - including one capital letter, one number and one special character.'));
            }
            if(password != confirmPassword){
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR,'Passwords do not match.Your password must be at least 8 characters - including one capital letter, one number and one special character.'));
            }else if(isPasswordValid(password)) {
                u.ProfileId = profile.Id;
                u.FirstName = firstName;
                u.LastName = lastName;
                u.Email = email;
                u.languagelocalekey = UserInfo.getLocale();
                u.localesidkey = UserInfo.getLocale();
                u.emailEncodingKey = 'UTF-8';
                u.timeZoneSidKey = UserInfo.getTimezone().getID();
                u = handleUnsetRequiredFields(u);
                generateContact(u, account.Id);
                if(u.contactId == null){
                    Contact newContact = new Contact();
                    newContact.FirstName =firstName;
                    newContact.LastName =lastName;
                    newContact.Email=email;
                    newContact.AccountId= accountId;
                    // newContact.LeadSource = 'Salesforce Community'; // Remediated: do not force Lead Source on self-registration
                    Database.SaveResult sr = Database.insert(newContact, false);
                    if (sr.isSuccess()) {
                        u.ContactId = sr.getId();
                        initSelfRegistration = true;
                        System.debug('Success');
                    }else{
                        // Record failed to insert/update
                        System.debug('Record Failed'+sr.getErrors());
                        String errorMessage ='';
                        for(Database.Error err : sr.getErrors()) {
                            errorMessage = errorMessage+ err.getMessage();
                        }
                        initSelfRegistration = false;
                        ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR,errorMessage));
                    }
                }else {
                    initSelfRegistration = true;
                }
                
                //code to start self verification 
                    if(initSelfRegistration){
                        if(!Test.isRunningTest()){
                            identifier = System.UserManagement.initSelfRegistration(Auth.VerificationMethod.EMAIL, u);
                        }else{
                            identifier='Testing1234';
                        }
                       
                        if(!String.IsBlank(identifier)){
                            PageReference pageRef = Page.SelfVerification;
                            pageRef.getParameters().put('identifier', identifier);
                            pageRef.getParameters().put('username', u.username);
                            pageRef.getParameters().put('password', password);
                             pageRef.setRedirect(true);
                            // Redirect to the target page
                            return pageRef;
                        }
                    }
                
            }else {
                System.debug('Password--err-'+password);
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR,'Your password must be at least 8 characters - including one capital letter, one number and one special character.'));
            }
            
        }catch(Exception e){
            string message = e.getMessage();
            System.debug('message   '+message);
            
            string LinkUrl = Url.getOrgDomainUrl().toExternalForm();
            if(message.equals('[User already exists.]')){
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR,'Account already exists. Please check your username and password. If you still can\'t log in, contact your EELL Community administrator.'));
            }else if(message.equals('[There was an error in registering a user in site [SiteName]. The error message is: portal user already exists for contact]')) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR,'An error occurred, please try logging in or using a different email. You can login at ' + LinkUrl));
            }else if(message.contains('DUPLICATES_DETECTED')) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR,'Account already exists. Please check your username and password. If you still can\'t log in, contact your EELL Community administrator.'));
            }else{
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR,'Please contact us and give us this error message: ' + e.getMessage()));
            } 
        }
        return null;
    }
    public static Boolean isPasswordValid(String password) {
        // Define the password requirements
        String regexPattern = '^(?=.*[A-Z])(?=.*[0-9])(?=.*[!@#$%^&*()_+\\-])[A-Za-z0-9!@#$%^&*()_+\\-]{8,}$';
        
        // Compile the regular expression pattern
        Pattern pattern = Pattern.compile(regexPattern);
        
        // Match the password against the pattern
        Matcher matcher = pattern.matcher(password);
        
        // Return true if the password meets the criteria, false otherwise
        return matcher.matches();
    }
    // Loops over required fields that were not passed in to set to some default value
    private User handleUnsetRequiredFields(User u) {
        if (String.isBlank(u.LastName)){
            u.LastName = generateLastName();
        }
        if (String.isBlank(u.Username)) {
            //u.Username = generateUsername();
            u.Username = u.Email;
        }
        if (String.isBlank(u.Email)) {
            u.Email = generateEmail();
        }
        if (String.isBlank(u.Alias)) {
            u.Alias = generateAlias();
        }
        if (String.isBlank(u.CommunityNickname)) {
            u.CommunityNickname = generateCommunityNickname();
        }
        return u;
    }
    
    // Method to construct a contact for a user
    private void generateContact(User u, Id accountId) {
        // Add logic here if you want to build your own contact for the user
        // Check for contact already exists in CRM by matching email. Associate new user to first contact match
        // FIXED: Added LeadSource to SELECT statement so we can check its current value
        List<Contact> existingContact = [SELECT Id, FirstName, LastName, AccountId, LeadSource FROM Contact WHERE (Email = :u.email OR hed__WorkEmail__c = :u.email OR hed__AlternateEmail__c = :u.email OR hed__UniversityEmail__c = :u.email)];
        if(existingContact.isEmpty()==false && existingContact.size() > 0)
        {
            System.debug('Found ' + existingContact.size() + ' existing Contact(s) based on Email Address');
            u.ContactId = existingContact[0].Id;
            //accountId = existingContact[0].AccountId;
            // EXISTING Contact - only set LeadSource if currently blank
            // Remediated: do not force 'Salesforce Community' on self-registration email match
            // if (String.isBlank(existingContact[0].LeadSource)) {
            //     existingContact[0].LeadSource = 'Salesforce Community';
            //     update existingContact[0];
            // }
            System.debug('cntct: ' + u.ContactId);
        }
    }
    
    // Default implementation to try to provide uniqueness
    private String generateAlias() {
        String timeString = String.valueOf(CURRENT_TIME);
        return timeString.substring(timeString.length() - 8);
    }
    
    // Default implementation to try to provide uniqueness
    private String generateLastName() {
        return 'ExternalUser' + CURRENT_TIME;
    }
    
    // Default implementation to try to provide uniqueness
    private String generateUsername() {
        return 'externaluser' + CURRENT_TIME + '@company.com';
    }
    
    // Default implementation to try to provide uniqueness
    private String generateEmail() {
        return 'externaluser' + CURRENT_TIME + '@company.com';
    }
    
    // Default implementation to try to provide uniqueness
    private String generateCommunityNickname() {
        return 'ExternalUser' + CURRENT_TIME;
    }   
}
