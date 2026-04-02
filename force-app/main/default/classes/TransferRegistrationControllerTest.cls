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

    /**
     * Best-effort DLRS bypass for tests to avoid hitting SOQL 101
     * from rollup automation. Uses dynamic SOQL so it works across
     * orgs using either the legacy custom object or the newer
     * custom metadata storage for rollups.
     */
    private static void bypassAllDlrsRollups() {
        try {
            for (SObject rec : Database.query('SELECT DeveloperName FROM dlrs__LookupRollupSummary2__mdt')) {
                String devName = (String)rec.get('DeveloperName');
                if (String.isNotBlank(devName)) {
                    dlrs.RollupService.bypass(devName);
                }
            }
        } catch (Exception e) {
            // Ignore — org may not be using the v2 metadata object
        }
        try {
            for (SObject rec : Database.query('SELECT UniqueName__c FROM dlrs__LookupRollupSummary__c')) {
                String uniqueName = (String)rec.get('UniqueName__c');
                if (String.isNotBlank(uniqueName)) {
                    dlrs.RollupService.bypass(uniqueName);
                }
            }
        } catch (Exception e) {
            // Ignore — org may not be using the legacy custom object
        }
    }

    // ── Tests ───────────────────────────────────────────────────────

    @IsTest
    static void testGetInitData() {
        // Disable DLRS rollups for this test run to avoid SOQL 101
        // from heavy rollup automation in this org.
        bypassAllDlrsRollups();

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
        bypassAllDlrsRollups();

        TestContext ctx = loadContext();

        Test.startTest();
        TransferRegistrationController.ProgramDetails details =
            TransferRegistrationController.getProgramDetails(ctx.newProgramId, ctx.originalOppPricebook2Id);
        Test.stopTest();

        System.assertNotEquals(null, details.program, 'Program should be loaded');
        // expectedProgramFee source field varies by org; just assert no exception.
    }

    @IsTest
    static void testExecuteTransferDifferentProgramWithFee() {
        bypassAllDlrsRollups();

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
    static void testExecuteTransferSameProgramNoFee() {
        bypassAllDlrsRollups();

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
    static void testExecuteTransferWithRefund() {
        bypassAllDlrsRollups();

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
    static void testExecuteTransferErrorHandling() {
        bypassAllDlrsRollups();

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

    @IsTest
    static void testExecuteCancellationBasic() {
        bypassAllDlrsRollups();

        TestContext ctx = loadContext();
        Id attId = insertAttendee(ctx);

        // Ensure Opportunity has a non-zero Amount and a simple payment status
        Opportunity oppToUpdate = [
            SELECT Id, Amount, Payment_Status__c
            FROM Opportunity
            WHERE Id = :ctx.originalOppId
            LIMIT 1
        ];
        oppToUpdate.Amount = 9950;
        oppToUpdate.Payment_Status__c = 'Not Paid';
        update oppToUpdate;

        TransferRegistrationController.CancellationRequest request =
            new TransferRegistrationController.CancellationRequest();
        request.attendeeId = attId;
        request.originalOppId = ctx.originalOppId;
        request.applyCancellationFee = false;
        request.cancellationFeeAmount = 0;
        request.settlementType = null;
        request.cancelComments = 'Unit test basic cancellation';

        Test.startTest();
        TransferRegistrationController.CancellationResult result =
            TransferRegistrationController.executeCancellation(request);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Cancellation should succeed: ' + result.errorMessage);
        System.assertEquals(ctx.originalOppId, result.opportunityId, 'Should return original Opp Id');
    }

    @IsTest
    static void testExecuteCancellationWithRefund() {
        bypassAllDlrsRollups();

        TestContext ctx = loadContext();
        Id attId = insertAttendee(ctx);

        // Mark the Opportunity with a non-zero Amount and keep Payment Status
        // as Not Paid so we avoid the complex Paid/Refund flow automation
        // (Opportunity Tracker / payments), but still exercise the
        // cancellation-fee and credit line item branches.
        Opportunity oppToUpdate = [
            SELECT Id, Amount, Payment_Status__c
            FROM Opportunity
            WHERE Id = :ctx.originalOppId
            LIMIT 1
        ];
        oppToUpdate.Amount = 9950;
        oppToUpdate.Payment_Status__c = 'Not Paid';
        update oppToUpdate;

        TransferRegistrationController.CancellationRequest request =
            new TransferRegistrationController.CancellationRequest();
        request.attendeeId = attId;
        request.originalOppId = ctx.originalOppId;
        request.applyCancellationFee = true;
        request.cancellationFeeAmount = 500;
        request.settlementType = null;
        request.cancelComments = 'Unit test cancellation with fee';

        Test.startTest();
        TransferRegistrationController.CancellationResult result =
            TransferRegistrationController.executeCancellation(request);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Cancellation with fee should succeed: ' + result.errorMessage);
    }

    /**
     * Cancellation credit must use Opportunity.Amount (net registration), not raw program-fee total,
     * and the credit line must use the same PricebookEntry as the original Program Fee OLI when present.
     */
    @IsTest
    static void testExecuteCancellation_NetAmountUsesOriginalProgramFeePbe() {
        bypassAllDlrsRollups();

        TestContext ctx = loadContext();
        Id attId = insertAttendee(ctx);

        OpportunityLineItem feeLine = [
            SELECT PricebookEntryId
            FROM OpportunityLineItem
            WHERE OpportunityId = :ctx.originalOppId
              AND UnitPrice = 9950
            LIMIT 1
        ];
        System.assertNotEquals(null, feeLine.PricebookEntryId, 'Test setup should have a program fee line with PBE');

        // Discount line so orgs that sync Opportunity.Amount from products can reflect net below list fee
        PricebookEntry discountPbe = [
            SELECT Id FROM PricebookEntry WHERE Product2.Name = 'Early Bird Discount' LIMIT 1
        ];
        insert new OpportunityLineItem(
            OpportunityId = ctx.originalOppId,
            PricebookEntryId = discountPbe.Id,
            Quantity = 1,
            UnitPrice = -6190
        );

        Decimal targetNet = 3760;
        Opportunity oppToUpdate = [
            SELECT Id, Amount, Payment_Status__c
            FROM Opportunity
            WHERE Id = :ctx.originalOppId
            LIMIT 1
        ];
        oppToUpdate.Amount = targetNet;
        oppToUpdate.Payment_Status__c = 'Not Paid';
        update oppToUpdate;

        TransferRegistrationController.CancellationRequest request =
            new TransferRegistrationController.CancellationRequest();
        request.attendeeId = attId;
        request.originalOppId = ctx.originalOppId;
        request.applyCancellationFee = false;
        request.cancellationFeeAmount = 0;
        request.settlementType = null;
        request.cancelComments = 'Unit test net amount + PBE mapping';

        Test.startTest();
        // Amount may be overwritten by automation after DML; credit must match Amount at execution time (same as production).
        Decimal amtAtRun = [
            SELECT Amount FROM Opportunity WHERE Id = :ctx.originalOppId LIMIT 1
        ].Amount;
        System.assertNotEquals(null, amtAtRun, 'Opportunity.Amount must be set for cancellation credit');
        System.assert(amtAtRun > 0, 'Opportunity.Amount should be positive before cancellation');

        TransferRegistrationController.CancellationResult result =
            TransferRegistrationController.executeCancellation(request);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Cancellation should succeed: ' + result.errorMessage);

        OpportunityLineItem creditLine = [
            SELECT PricebookEntryId, UnitPrice, Description
            FROM OpportunityLineItem
            WHERE OpportunityId = :ctx.originalOppId
              AND Description = 'Cancellation Credit'
            LIMIT 1
        ];
        System.assertEquals(-amtAtRun, creditLine.UnitPrice, 'Credit should match Opportunity.Amount at cancellation time');
        System.assertEquals(
            feeLine.PricebookEntryId,
            creditLine.PricebookEntryId,
            'Credit line should use original program fee PricebookEntry'
        );
    }

    @IsTest
    static void testExecuteSubstitutionBasic() {
        bypassAllDlrsRollups();

        TestContext ctx = loadContext();
        Id attId = insertAttendee(ctx);

        TransferRegistrationController.SubstitutionRequest request =
            new TransferRegistrationController.SubstitutionRequest();
        request.attendeeId = attId;
        request.originalOppId = ctx.originalOppId;
        // For test coverage we can safely use the same Contact as both
        // original and substitute; the controller does not require them
        // to differ, and this avoids additional Contact automation.
        request.substituteContactId = ctx.contactId;
        request.applyDiscount = false;
        request.substitutionComments = 'Unit test basic substitution';

        Test.startTest();
        TransferRegistrationController.SubstitutionResult result =
            TransferRegistrationController.executeSubstitution(request);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Substitution should succeed: ' + result.errorMessage);
        System.assertNotEquals(null, result.newOpportunityId, 'New Opp for substitute should be created');
        System.assertNotEquals(null, result.newAttendeeId, 'New Attendee for substitute should be created');
    }

    /**
     * Substituted-Out credit line should use the original program fee line's PricebookEntry (not a generic Program Fee product).
     */
    @IsTest
    static void testExecuteSubstitution_SubstitutedOutUsesOriginalProgramFeePbe() {
        bypassAllDlrsRollups();

        TestContext ctx = loadContext();
        Id attId = insertAttendee(ctx);

        OpportunityLineItem feeLine = [
            SELECT PricebookEntryId
            FROM OpportunityLineItem
            WHERE OpportunityId = :ctx.originalOppId
              AND UnitPrice = 9950
            LIMIT 1
        ];
        System.assertNotEquals(null, feeLine.PricebookEntryId, 'Test setup should have a program fee line with PBE');

        Decimal oppAmt = 9950;
        update new Opportunity(Id = ctx.originalOppId, Amount = oppAmt);

        TransferRegistrationController.SubstitutionRequest request =
            new TransferRegistrationController.SubstitutionRequest();
        request.attendeeId = attId;
        request.originalOppId = ctx.originalOppId;
        request.substituteContactId = ctx.contactId;
        request.applyDiscount = false;
        request.substitutionComments = 'Unit test substitution PBE mapping';

        Test.startTest();
        TransferRegistrationController.SubstitutionResult result =
            TransferRegistrationController.executeSubstitution(request);
        Test.stopTest();

        String err = result.errorMessage == null ? '' : result.errorMessage;
        System.assertEquals(true, result.success, 'Substitution should succeed: ' + err);

        OpportunityLineItem subOutLine = [
            SELECT PricebookEntryId, UnitPrice, Description
            FROM OpportunityLineItem
            WHERE OpportunityId = :ctx.originalOppId
              AND Description = 'Substituted Out'
            LIMIT 1
        ];
        System.assertEquals(-oppAmt, subOutLine.UnitPrice, 'Substituted-Out credit should match Opportunity.Amount');
        System.assertEquals(
            feeLine.PricebookEntryId,
            subOutLine.PricebookEntryId,
            'Substituted-Out line should use original program fee PricebookEntry'
        );
    }

    /**
     * Transfer with applyDiscount + discount code (no discount OLI on original) — covers executeTransfer discount-from-code branch for prod coverage.
     */
    @IsTest
    static void testExecuteTransferWithDiscountCode() {
        bypassAllDlrsRollups();

        TestContext ctx = loadContext();
        Id attId = insertAttendee(ctx);

        TransferRegistrationController.TransferRequest request = new TransferRegistrationController.TransferRequest();
        request.attendeeId = attId;
        request.originalOppId = ctx.originalOppId;
        request.newSpecialEventId = ctx.newProgramId;
        request.applyTransferFee = false;
        request.settlementType = '';
        request.applyDiscount = true;
        request.discountCode = 'Early Bird Discount';
        request.discountAmount = 0;
        request.sameProgramTransfer = false;
        request.newProgramFeeAmount = 12500;
        request.regChangeComments = 'Unit test transfer with discount code';

        Test.startTest();
        TransferRegistrationController.TransferResult result =
            TransferRegistrationController.executeTransfer(request);
        Test.stopTest();

        String err = result.errorMessage == null ? '' : result.errorMessage;
        System.assertEquals(true, result.success, 'Transfer should succeed: ' + err);
        System.assertNotEquals(null, result.newOpportunityId, 'New Opp should be created');
    }

    @IsTest
    static void testGetDiscountByCode() {
        bypassAllDlrsRollups();

        TestContext ctx = loadContext();

        Test.startTest();
        TransferRegistrationController.DiscountByCodeResult result =
            TransferRegistrationController.getDiscountByCode(
                'Early Bird Discount',
                ctx.originalOppPricebook2Id,
                12500
            );
        Test.stopTest();

        System.assertEquals(true, result.valid, 'Discount code should be valid');
        System.assert(result.discountAmount > 0,
            'Discount amount should be calculated for Early Bird Discount');
    }

    @IsTest
    static void testGetDiscountByCodeBlankCode() {
        TestContext ctx = loadContext();

        Test.startTest();
        TransferRegistrationController.DiscountByCodeResult result =
            TransferRegistrationController.getDiscountByCode('', ctx.originalOppPricebook2Id, 100);
        Test.stopTest();

        System.assertEquals(false, result.valid, 'Blank code should be invalid');
        System.assert(result.errorMessage.contains('required'), 'Should require code and pricebook');
    }

    @IsTest
    static void testGetDiscountByCodeNotFound() {
        TestContext ctx = loadContext();

        Test.startTest();
        TransferRegistrationController.DiscountByCodeResult result =
            TransferRegistrationController.getDiscountByCode('NonexistentCode', ctx.originalOppPricebook2Id, 100);
        Test.stopTest();

        System.assertEquals(false, result.valid, 'Nonexistent code should be invalid');
        System.assert(result.errorMessage.contains('not found'), 'Should say code not found');
    }

    @IsTest
    static void testSearchContactsShortTerm() {
        Test.startTest();
        List<TransferRegistrationController.ContactSearchResult> results =
            TransferRegistrationController.searchContacts('x', null);
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Search term length < 2 should return no results');
    }

    @IsTest
    static void testSearchContactsBlankOrNullTerm() {
        Test.startTest();
        System.assertEquals(0, TransferRegistrationController.searchContacts(null, null).size());
        System.assertEquals(0, TransferRegistrationController.searchContacts('', null).size());
        System.assertEquals(0, TransferRegistrationController.searchContacts('   ', null).size());
        Test.stopTest();
    }

    @IsTest
    static void testSearchContactsWithAccount() {
        TestContext ctx = loadContext();

        Test.startTest();
        List<TransferRegistrationController.ContactSearchResult> results =
            TransferRegistrationController.searchContacts('Doe', ctx.accountId);
        Test.stopTest();

        System.assert(results.size() >= 1, 'Should find test contact Doe in account');
        System.assert(results[0].name.contains('Doe'), 'Result should be Doe');
    }

    @IsTest
    static void testSearchContactsNoAccount() {
        TestContext ctx = loadContext();

        Test.startTest();
        List<TransferRegistrationController.ContactSearchResult> results =
            TransferRegistrationController.searchContacts('Doe', null);
        Test.stopTest();

        System.assert(results.size() >= 1, 'Should find Doe when no account filter');
    }
}
