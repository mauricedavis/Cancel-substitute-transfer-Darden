/**
 * @description  Test class for TransferRegistrationController.
 *
 *               GOVERNOR LIMIT STRATEGY:
 *               The org has extreme cascading automation on evt__Attendee__c:
 *               Attendee Master + DLRS + SLX Attendee Sync + Pardot Prospect
 *               Update + Contact UTM Parameters — consuming 80-90 SOQL combined.
 *
 *               Budget allocation per test method (for executeTransfer tests):
 *
 *               PRE-startTest budget (100 SOQL):
 *                 ~4 SOQL   - query @TestSetup records
 *                 ~80 SOQL  - Attendee insert + automation cascade
 *                 ~16 SOQL  - remaining headroom
 *                 (NO Opp.Attendee__c update — that triggers Pardot cascade)
 *
 *               POST-startTest budget (fresh 100 SOQL):
 *                 ~6 SOQL   - executeTransfer controller queries
 *                 ~80 SOQL  - automation on Attendee update + new Attendee insert
 *                 ~14 SOQL  - remaining headroom
 *
 *               The Opp.Attendee__c lookup is NOT required for the transfer
 *               to work — the controller queries the Attendee independently
 *               and uses Attendee.Opportunity__c to find the Opp.
 *
 * @author       Maury Davis (MJD) - Attain Partners
 * @date         2026-02-12
 * @ticket       EELL-216
 */
@IsTest
private class TransferRegistrationControllerTest {

    @TestSetup
    static void setupTestData() {
        Account testAccount = new Account(Name = 'Test Corp');
        insert testAccount;

        Contact testContact = new Contact(
            FirstName = 'Jane',
            LastName  = 'Doe',
            Email     = 'jane.doe@test.com',
            AccountId = testAccount.Id
        );
        insert testContact;

        Id stdPricebookId = Test.getStandardPricebookId();
        Id eeRecordTypeId = Schema.SObjectType.Product2.getRecordTypeInfosByName()
            .get('EE Programs').getRecordTypeId();

        Product2 programFeeProduct  = new Product2(Name = 'WIL Program Fee',     Family = 'Program Fee', IsActive = true, RecordTypeId = eeRecordTypeId);
        Product2 transferFeeProduct = new Product2(Name = 'Transfer Fee',         Family = 'Fee',         IsActive = true, RecordTypeId = eeRecordTypeId);
        Product2 discountProduct    = new Product2(Name = 'Early Bird Discount',  Family = 'Discount',    IsActive = true, RecordTypeId = eeRecordTypeId);
        insert new List<Product2>{ programFeeProduct, transferFeeProduct, discountProduct };

        PricebookEntry programFeePBE  = new PricebookEntry(Pricebook2Id = stdPricebookId, Product2Id = programFeeProduct.Id,  UnitPrice = 9950, IsActive = true);
        PricebookEntry transferFeePBE = new PricebookEntry(Pricebook2Id = stdPricebookId, Product2Id = transferFeeProduct.Id, UnitPrice = 500,  IsActive = true);
        PricebookEntry discountPBE    = new PricebookEntry(Pricebook2Id = stdPricebookId, Product2Id = discountProduct.Id,    UnitPrice = 500,  IsActive = true);
        insert new List<PricebookEntry>{ programFeePBE, transferFeePBE, discountPBE };

        evt__Special_Event__c originalProgram = new evt__Special_Event__c(
            Name = 'WIL 2026',
            evt__Start__c  = DateTime.newInstance(Date.today().addDays(30), Time.newInstance(8, 0, 0, 0)),
            evt__End__c    = DateTime.newInstance(Date.today().addDays(35), Time.newInstance(17, 0, 0, 0)),
            evt__Status__c = 'Active',
            Program_Acronym_Name__c = 'WIL'
        );
        evt__Special_Event__c newProgram = new evt__Special_Event__c(
            Name = 'LEAD 2026',
            evt__Start__c  = DateTime.newInstance(Date.today().addDays(60), Time.newInstance(8, 0, 0, 0)),
            evt__End__c    = DateTime.newInstance(Date.today().addDays(65), Time.newInstance(17, 0, 0, 0)),
            evt__Status__c = 'Active',
            Expected_Program_Fee__c = 12500,
            Program_Acronym_Name__c = 'LEAD'
        );
        insert new List<evt__Special_Event__c>{ originalProgram, newProgram };

        Opportunity originalOpp = new Opportunity(
            Name             = 'Doe - WIL',
            AccountId        = testAccount.Id,
            ContactId        = testContact.Id,
            StageName        = 'Registered',
            CloseDate        = Date.today(),
            Pricebook2Id     = stdPricebookId,
            Special_Event__c = originalProgram.Id,
            Registration_Date__c = Date.today().addDays(-30)
        );
        insert originalOpp;

        OpportunityLineItem programFeeOLI = new OpportunityLineItem(
            OpportunityId    = originalOpp.Id,
            PricebookEntryId = programFeePBE.Id,
            Quantity         = 1,
            UnitPrice        = 9950
        );
        insert programFeeOLI;
    }

    // ── Single bulk query to minimize pre-startTest SOQL ────────────
    // Returns a map with all needed record Ids from @TestSetup.
    // Uses 4 SOQL instead of scattering queries across helpers.
    private class TestContext {
        Id contactId;
        Id accountId;
        Id originalOppId;
        Id originalOppPricebook2Id;
        Id originalProgramId;
        Id newProgramId;
        Id attendeeId;
    }

    static TestContext loadContext() {
        TestContext ctx = new TestContext();

        Contact c = [SELECT Id, AccountId FROM Contact WHERE LastName = 'Doe' LIMIT 1];
        ctx.contactId = c.Id;
        ctx.accountId = c.AccountId;

        Opportunity opp = [SELECT Id, Pricebook2Id FROM Opportunity WHERE Name = 'Doe - WIL' LIMIT 1];
        ctx.originalOppId = opp.Id;
        ctx.originalOppPricebook2Id = opp.Pricebook2Id;

        evt__Special_Event__c origProg = [SELECT Id FROM evt__Special_Event__c WHERE Name = 'WIL 2026' LIMIT 1];
        ctx.originalProgramId = origProg.Id;

        evt__Special_Event__c newProg = [SELECT Id FROM evt__Special_Event__c WHERE Name = 'LEAD 2026' LIMIT 1];
        ctx.newProgramId = newProg.Id;

        return ctx;
    }

    /**
     * Inserts the Attendee. Call BEFORE Test.startTest().
     * Consumes ~80 SOQL from the pre-test budget via automation.
     * Does NOT update Opp.Attendee__c to avoid Pardot cascade.
     */
    static Id insertAttendee(TestContext ctx) {
        evt__Attendee__c att = new evt__Attendee__c(
            evt__Contact__c           = ctx.contactId,
            Account__c                = ctx.accountId,
            Opportunity__c            = ctx.originalOppId,
            evt__Event__c             = ctx.originalProgramId,
            evt__Invitation_Status__c = 'Registered',
            Registration_Date__c      = Date.today().addDays(-30)
        );
        insert att;
        return att.Id;
    }

    // ── Tests ───────────────────────────────────────────────────────

    @IsTest
    static void testGetInitData() {
        TestContext ctx = loadContext();   // ~4 SOQL
        Id attId = insertAttendee(ctx);    // ~80 SOQL (automation)

        // Link Opp → Attendee (skip if SOQL tight; getInitData uses Attendee.Opportunity__c)
        // Opportunity opp = new Opportunity(Id = ctx.originalOppId, Attendee__c = attId);
        // update opp;

        Test.startTest();                  // Fresh 100 SOQL
        TransferRegistrationController.InitData initData =
            TransferRegistrationController.getInitData(attId);
        Test.stopTest();

        System.assertNotEquals(null, initData.attendee, 'Attendee should be loaded');
        System.assertNotEquals(null, initData.originalOpp, 'Original Opp should be loaded');
        System.assertEquals(1, initData.programFeeLineItems.size(), 'Should have 1 program fee line item');
        System.assertEquals(9950, initData.originalProgramFeeTotal, 'Program fee total should be 9950');
    }

    @IsTest
    static void testGetProgramDetails() {
        TestContext ctx = loadContext();

        Test.startTest();
        TransferRegistrationController.ProgramDetails details =
            TransferRegistrationController.getProgramDetails(ctx.newProgramId, ctx.originalOppPricebook2Id);
        Test.stopTest();

        System.assertNotEquals(null, details.program, 'Program should be loaded');
        System.assertEquals(12500, details.expectedProgramFee, 'Expected fee should be 12500');
    }

    @IsTest
    static void testExecuteTransfer_DifferentProgram_WithFee() {
        TestContext ctx = loadContext();     // ~4 SOQL
        Id attId = insertAttendee(ctx);      // ~80 SOQL (pre-test budget)

        TransferRegistrationController.TransferRequest request = new TransferRegistrationController.TransferRequest();
        request.attendeeId         = attId;
        request.originalOppId      = ctx.originalOppId;
        request.newSpecialEventId  = ctx.newProgramId;
        request.applyTransferFee   = true;
        request.settlementType     = 'Unapplied Funds';
        request.applyDiscount      = false;
        request.sameProgramTransfer = false;
        request.newProgramFeeAmount = 12500;
        request.regChangeComments  = 'Test transfer to LEAD';

        Test.startTest();                    // Fresh 100 SOQL for executeTransfer
        TransferRegistrationController.TransferResult result =
            TransferRegistrationController.executeTransfer(request);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Transfer should succeed: ' + result.errorMessage);
        System.assertNotEquals(null, result.newOpportunityId, 'New Opp ID should be populated');
    }

    @IsTest
    static void testExecuteTransfer_SameProgram_NoFee() {
        TestContext ctx = loadContext();
        Id attId = insertAttendee(ctx);

        TransferRegistrationController.TransferRequest request = new TransferRegistrationController.TransferRequest();
        request.attendeeId         = attId;
        request.originalOppId      = ctx.originalOppId;
        request.newSpecialEventId  = ctx.newProgramId;
        request.applyTransferFee   = false;
        request.settlementType     = '';
        request.applyDiscount      = false;
        request.sameProgramTransfer = true;
        request.newProgramFeeAmount = 9950;
        request.regChangeComments  = 'Same program transfer test';

        Test.startTest();
        TransferRegistrationController.TransferResult result =
            TransferRegistrationController.executeTransfer(request);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Transfer should succeed: ' + result.errorMessage);
    }

    @IsTest
    static void testExecuteTransfer_WithRefund() {
        TestContext ctx = loadContext();
        Id attId = insertAttendee(ctx);

        TransferRegistrationController.TransferRequest request = new TransferRegistrationController.TransferRequest();
        request.attendeeId         = attId;
        request.originalOppId      = ctx.originalOppId;
        request.newSpecialEventId  = ctx.newProgramId;
        request.applyTransferFee   = true;
        request.settlementType     = 'Refund';
        request.applyDiscount      = false;
        request.sameProgramTransfer = false;
        request.newProgramFeeAmount = 12500;
        request.regChangeComments  = 'Transfer with refund';

        Test.startTest();
        TransferRegistrationController.TransferResult result =
            TransferRegistrationController.executeTransfer(request);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Transfer should succeed: ' + result.errorMessage);
    }

    @IsTest
    static void testExecuteTransfer_ErrorHandling() {
        TransferRegistrationController.TransferRequest request = new TransferRegistrationController.TransferRequest();
        request.attendeeId         = 'a6b000000000000AAA';
        request.originalOppId      = '006000000000000AAA';
        request.newSpecialEventId  = 'a0Y000000000000AAA';
        request.applyTransferFee   = false;
        request.sameProgramTransfer = false;

        Test.startTest();
        TransferRegistrationController.TransferResult result =
            TransferRegistrationController.executeTransfer(request);
        Test.stopTest();

        System.assertEquals(false, result.success, 'Should fail with bad IDs');
        System.assertNotEquals(null, result.errorMessage, 'Error message should be populated');
    }
}
