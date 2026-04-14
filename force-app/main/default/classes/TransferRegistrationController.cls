/**
 * @description  Apex controller for the Transfer Registration LWC.
 *               Replaces the "Transfer_Subflow" screen flow (v15).
 *               Handles transferring a registrant to another program, including:
 *               - Credit line item creation (instead of deleting original program fee)
 *               - Transfer fee application
 *               - Opportunity stage updates (Transferred Out)
 *               - Payment record moves/updates/creation
 *               - Unapplied Funds / Refund settlement handling
 *               - Invoice reassignment
 *               - New Attendee + Opportunity creation
 *
 *               SOQL budget: Org has heavy automation on evt__Attendee__c
 *               (Attendee Master, SLX Attendee Sync, DLRS rollups) and Contact
 *               (UTM Parameters flow). This controller is optimized to use
 *               minimal SOQL (~6 queries) to leave headroom for automation.
 *
 *               Opportunity Tracker: We update the original Opportunity to
 *               StageName='Transferred Out' and Registration_Change_Type__c='Transferred Out'
 *               BEFORE inserting credit/transfer-fee OLIs, so when Amount changes
 *               the process does not match "Registered + Paid + null change type".
 *               If the flow still errors, add a safeguard: in the rule that runs
 *               the FlowActionCall (e.g. myRule_31), add conditions so it does NOT
 *               run when Registration_Change_Type__c is not null, or when
 *               StageName is 'Transferred Out'/'Canceled', or when Amount <= 0.
 *
 * @author       Maury Davis (MJD) - Attain Partners
 * @date         2026-02-12
 * @ticket       EELL-216
 */
public with sharing class TransferRegistrationController {

    /**
     * Opportunity field API for "Reason Lost" (picklist or text) when stage becomes Canceled.
     * If your org uses a different API name, change this constant only.
     */
    private static final String OPP_REASON_LOST_FIELD = 'Reason_Lost__c';

    // --- WRAPPER CLASSES ------------------------------------------------

    public class InitData {
        @AuraEnabled public evt__Attendee__c attendee;
        @AuraEnabled public Opportunity originalOpp;
        @AuraEnabled public List<OpportunityLineItem> programFeeLineItems;
        @AuraEnabled public List<OpportunityLineItem> discountLineItems;
        @AuraEnabled public List<evt__Special_Event__c> availablePrograms;
        @AuraEnabled public Decimal originalProgramFeeTotal;
        @AuraEnabled public Decimal discountTotal;
        /** Net registration on original opp: sum(Program Fee TotalPrice) + sum(Discount TotalPrice). */
        @AuraEnabled public Decimal originalNetRegistrationAmount;
        @AuraEnabled public String contactId;
        @AuraEnabled public String accountId;
    }

    public class ProgramDetails {
        @AuraEnabled public evt__Special_Event__c program;
        @AuraEnabled public PricebookEntry programFeePBE;
        @AuraEnabled public PricebookEntry transferFeePBE;
        @AuraEnabled public Decimal expectedProgramFee;
    }

    public class TransferRequest {
        @AuraEnabled public Id attendeeId { get; set; }
        @AuraEnabled public Id originalOppId { get; set; }
        @AuraEnabled public Id newSpecialEventId { get; set; }
        @AuraEnabled public Boolean applyTransferFee { get; set; }
        @AuraEnabled public Decimal transferFeeAmount { get; set; }     // Custom transfer fee amount
        @AuraEnabled public String settlementType { get; set; }         // 'Refund' or 'Unapplied Funds'
        @AuraEnabled public Boolean applyDiscount { get; set; }
        @AuraEnabled public Decimal discountAmount { get; set; }
        @AuraEnabled public String discountCode { get; set; }
        @AuraEnabled public Boolean sameProgramTransfer { get; set; }
        @AuraEnabled public Decimal newProgramFeeAmount { get; set; }
        @AuraEnabled public String regChangeComments { get; set; }
    }

    public class TransferResult {
        @AuraEnabled public Id newOpportunityId;
        @AuraEnabled public Id newAttendeeId;
        @AuraEnabled public String newOpportunityName;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String errorMessage;
    }

    // --- CANCELLATION WRAPPER CLASSES ------------------------------------

    public class CancellationRequest {
        @AuraEnabled public Id attendeeId { get; set; }
        @AuraEnabled public Id originalOppId { get; set; }
        @AuraEnabled public Boolean applyCancellationFee { get; set; }
        @AuraEnabled public Decimal cancellationFeeAmount { get; set; }
        @AuraEnabled public String settlementType { get; set; }         // 'Refund', 'Unapplied Funds', 'Apply to Remaining Balance', or null
        @AuraEnabled public String cancelComments { get; set; }
        @AuraEnabled public String reasonLost { get; set; }
    }

    public class CancellationResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        @AuraEnabled public Id opportunityId { get; set; }
        @AuraEnabled public Id paymentId { get; set; }              // For refund link
        @AuraEnabled public Decimal refundAmount { get; set; }
        @AuraEnabled public Id unappliedFundsId { get; set; }
        @AuraEnabled public Id taskId { get; set; }
    }

    public class ReasonLostPicklistOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    // --- SUBSTITUTION WRAPPER CLASSES ------------------------------------

    public class ContactSearchResult {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String email { get; set; }
        @AuraEnabled public String title { get; set; }
        @AuraEnabled public String accountName { get; set; }
    }

    public class SubstitutionRequest {
        @AuraEnabled public Id attendeeId { get; set; }
        @AuraEnabled public Id originalOppId { get; set; }
        @AuraEnabled public Id substituteContactId { get; set; }
        @AuraEnabled public Boolean applyDiscount { get; set; }
        @AuraEnabled public String substitutionComments { get; set; }
        @AuraEnabled public String reasonLost { get; set; }
    }

    public class SubstitutionResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        @AuraEnabled public Id newOpportunityId { get; set; }
        @AuraEnabled public Id newAttendeeId { get; set; }
        @AuraEnabled public String newOpportunityName { get; set; }
    }

    // --- INITIALIZATION -------------------------------------------------

    @AuraEnabled(cacheable=true)
    public static InitData getInitData(Id attendeeId) {
        InitData data = new InitData();

        data.attendee = [
            SELECT Id, Name, evt__Contact__c, Account__c, Opportunity__c,
                   evt__Invitation_Status__c, Status__c,
                   evt__Event__c, evt__Event__r.Name,
                   evt__Event__r.Program_Code__c, evt__Event__r.Program_Acronym__c,
                   evt__First_Name__c, evt__Last_Name__c, evt__Email__c,
                   Registration_Date__c, evt__Registration_Type__c
            FROM evt__Attendee__c
            WHERE Id = :attendeeId
            LIMIT 1
        ];

        data.contactId = data.attendee.evt__Contact__c;
        data.accountId = data.attendee.Account__c;

        data.originalOpp = [
            SELECT Id, Name, StageName, Amount, AccountId, ContactId,
                   Pricebook2Id, RecordTypeId, OwnerId,
                   Registration_Change_Type__c, Registration_Type__c,
                   Registration_Date__c, CloseDate,
                   EE_Program__c, Special_Event__c,
                   Program_Code__c, Program_Acronym__c, Program_Name__c,
                   Program_Amount__c, Program_Fee__c,
                   Attendee__c, Billing_Contact__c,
                   Invoice__c, Invoice_Status__c,
                   Discount_Amount__c, Number_of_Discounts__c,
                   Reg_Change_Comments__c, Reg_Change_Date__c,
                   Reg_Change_Processed_By__c,
                   Transferred_to__c, Transferred_To_Amount__c,
                   Transferred_to_Program_Acronym__c,
                   Transferred_To_Program_Code__c, Transferred_To_End_Date__c,
                   Parent_Opportunity__c,
                   Payment_Status__c, pymt__Balance__c,
                   Program_Registration_Balance__c
            FROM Opportunity
            WHERE Id = :data.attendee.Opportunity__c
            LIMIT 1
        ];

        data.programFeeLineItems = [
            SELECT Id, OpportunityId, PricebookEntryId, Product2Id,
                   Product2.Name, Product2.Family,
                   Quantity, UnitPrice, TotalPrice,
                   Product_Family__c, Reverse_Product_Line_Item__c
            FROM OpportunityLineItem
            WHERE OpportunityId = :data.originalOpp.Id
              AND Product_Family__c = 'Program Fee'
            ORDER BY CreatedDate ASC
        ];

        data.discountLineItems = [
            SELECT Id, OpportunityId, PricebookEntryId, Product2Id,
                   Product2.Name, Product2.Family,
                   Quantity, UnitPrice, TotalPrice,
                   Product_Family__c, Discount_Code__c
            FROM OpportunityLineItem
            WHERE OpportunityId = :data.originalOpp.Id
              AND (Product_Family__c = 'Discount' OR Product_Family__c = 'Discounts')
            ORDER BY CreatedDate ASC
        ];

        data.originalProgramFeeTotal = 0;
        for (OpportunityLineItem oli : data.programFeeLineItems) {
            if (oli.TotalPrice != null) {
                data.originalProgramFeeTotal += oli.TotalPrice;
            }
        }
        data.discountTotal = 0;
        for (OpportunityLineItem oli : data.discountLineItems) {
            if (oli.TotalPrice != null) {
                data.discountTotal += oli.TotalPrice;
            }
        }
        data.originalNetRegistrationAmount = data.originalProgramFeeTotal + data.discountTotal;

        data.availablePrograms = [
            SELECT Id, Name, evt__Start__c, evt__End__c,
                   Program_Code__c, Program_Acronym__c, Program__c,
                   Expected_Program_Fee__c, EE_Program__c,
                   evt__Status__c, Custom_Program__c,
                   Case_transfer_program__c,
                   Multi_Module_Program__c
            FROM evt__Special_Event__c
            WHERE evt__Status__c NOT IN ('Cancelled', 'Closed')
              AND evt__Start__c >= TODAY
            ORDER BY evt__Start__c ASC
            LIMIT 500
        ];

        return data;
    }

    // --- PROGRAM SELECTION ----------------------------------------------

    @AuraEnabled
    public static ProgramDetails getProgramDetails(Id specialEventId, Id pricebook2Id) {
        ProgramDetails details = new ProgramDetails();

        details.program = [
            SELECT Id, Name, evt__Start__c, evt__End__c,
                   Program_Code__c, Program_Acronym__c, Program__c,
                   Expected_Program_Fee__c, EE_Program__c,
                   Open_Online_Program_Price__c,
                   evt__Status__c, Custom_Program__c,
                   Multi_Module_Program__c
            FROM evt__Special_Event__c
            WHERE Id = :specialEventId
            LIMIT 1
        ];

        // Use Open_Online_Program_Price__c as the primary fee (matches original flow)
        // Fall back to Expected_Program_Fee__c if not set
        details.expectedProgramFee = details.program.Open_Online_Program_Price__c != null
            ? details.program.Open_Online_Program_Price__c
            : details.program.Expected_Program_Fee__c;

        if (pricebook2Id != null && details.program.EE_Program__c != null) {
            List<PricebookEntry> programFeePBEs = [
                SELECT Id, Product2Id, Product2.Name, Product2.Family,
                       UnitPrice, Pricebook2Id, IsActive
                FROM PricebookEntry
                WHERE Pricebook2Id = :pricebook2Id
                  AND Product2.Family = 'Program Fee'
                  AND IsActive = true
                LIMIT 10
            ];
            if (!programFeePBEs.isEmpty()) {
                details.programFeePBE = programFeePBEs[0];
            }
        }

        if (pricebook2Id != null) {
            List<PricebookEntry> transferFeePBEs = [
                SELECT Id, Product2Id, Product2.Name, Product2.Family,
                       UnitPrice, Pricebook2Id, IsActive
                FROM PricebookEntry
                WHERE Pricebook2Id = :pricebook2Id
                  AND Product2.Name = 'Transfer Fee'
                  AND IsActive = true
                LIMIT 1
            ];
            if (!transferFeePBEs.isEmpty()) {
                details.transferFeePBE = transferFeePBEs[0];
            }
        }

        return details;
    }

    // --- DISCOUNT BY CODE (validation + calculation) --------------------

    public class DiscountByCodeResult {
        @AuraEnabled public Boolean valid;
        @AuraEnabled public Decimal discountAmount;
        @AuraEnabled public String errorMessage;
    }

    @AuraEnabled
    public static DiscountByCodeResult getDiscountByCode(String discountCode, Id pricebook2Id, Decimal newProgramFeeAmount) {
        DiscountByCodeResult result = new DiscountByCodeResult();
        result.valid = false;
        result.discountAmount = 0;
        result.errorMessage = '';

        if (String.isBlank(discountCode) || pricebook2Id == null) {
            result.errorMessage = 'Discount code and pricebook are required.';
            return result;
        }

        String codeKey = discountCode.toUpperCase().trim();
        Decimal newFee = (newProgramFeeAmount != null && newProgramFeeAmount > 0) ? newProgramFeeAmount : 0;

        List<PricebookEntry> pbes = [
            SELECT Id, Product2Id, Product2.Name, Product2.ProductCode, Product2.Discount_Percent__c, UnitPrice
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebook2Id
              AND IsActive = true
              AND (Product2.Family = 'Discount' OR Product2.Family = 'Discounts')
        ];

        for (PricebookEntry pbe : pbes) {
            Boolean matches = (pbe.Product2.ProductCode != null && pbe.Product2.ProductCode.toUpperCase().trim() == codeKey)
                || (pbe.Product2.Name != null && pbe.Product2.Name.toUpperCase().trim() == codeKey);
            if (!matches) continue;

            result.valid = true;
            if (pbe.Product2.Discount_Percent__c != null && pbe.Product2.Discount_Percent__c > 0 && newFee > 0) {
                result.discountAmount = newFee * pbe.Product2.Discount_Percent__c / 100;
            } else if (pbe.UnitPrice != null && pbe.UnitPrice != 0) {
                result.discountAmount = Math.abs(pbe.UnitPrice);
            } else {
                result.valid = false;
                result.errorMessage = 'Discount product "' + discountCode + '" has no Discount Percent or Unit Price.';
            }
            return result;
        }

        result.errorMessage = 'Discount code "' + discountCode + '" was not found in the pricebook.';
        return result;
    }

    /**
     * Active picklist values for Reason Lost (cancellation UI). Empty if field is missing or not a picklist — LWC falls back to text entry.
     */
    @AuraEnabled(cacheable=true)
    public static List<ReasonLostPicklistOption> getCancellationReasonLostOptions() {
        List<ReasonLostPicklistOption> out = new List<ReasonLostPicklistOption>();
        String fldApi = resolveOpportunityFieldApiName(OPP_REASON_LOST_FIELD);
        if (fldApi == null) {
            return out;
        }
        Schema.DescribeFieldResult dfr = Schema.SObjectType.Opportunity.fields.getMap().get(fldApi).getDescribe();
        if (dfr.getType() != Schema.DisplayType.PICKLIST) {
            return out;
        }
        for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
            if (!pe.isActive()) {
                continue;
            }
            ReasonLostPicklistOption row = new ReasonLostPicklistOption();
            row.label = pe.getLabel();
            row.value = pe.getValue();
            out.add(row);
        }
        return out;
    }

    // --- EXECUTE TRANSFER -----------------------------------------------
    // SOQL-optimized: ~6 queries total to leave headroom for org automation
    // (Attendee Master, SLX Attendee Sync, DLRS, Contact UTM flows).

    @AuraEnabled
    public static TransferResult executeTransfer(TransferRequest request) {
        TransferResult result = new TransferResult();
        Savepoint sp = Database.setSavepoint();

        try {
            // ── Validate inputs ──────────────────────────────────
            if (request.attendeeId == null) {
                throw new AuraHandledException('attendeeId is null — the component may not have received the record ID.');
            }
            if (request.originalOppId == null) {
                throw new AuraHandledException('originalOppId is null — the original Opportunity ID was not provided.');
            }
            if (request.newSpecialEventId == null) {
                throw new AuraHandledException('newSpecialEventId is null — no target program was selected.');
            }

            // ── QUERY 1: Attendee ──────────────────────────────────
            List<evt__Attendee__c> attendeeList = [
                SELECT Id, Name, evt__Contact__c, Account__c, Opportunity__c,
                       evt__Invitation_Status__c, evt__Event__c,
                       evt__First_Name__c, evt__Last_Name__c, evt__Email__c,
                       Registration_Date__c, evt__Registration_Type__c,
                       Reg_Government__c, Reg_Industry__c, Reg_Job_Function__c,
                       Reg_Job_Level__c, Reg_How_they_heard_about_program__c,
                       Reg_How_they_heard_about_program_Other__c,
                       Reg_Highest_Degree_Completed__c, Reg_Years_of_Work_Experience__c,
                       Reg_LinkedIn_URL__c, Reg_Prefix__c, Reg_Suffix__c,
                       Reg_Middle_Name__c, Reg_Preferred_Name__c, Reg_Gender__c,
                       Reg_Billing_City__c, Reg_Billing_Country__c,
                       Reg_Billing_State__c, Reg_Billing_Street__c, Reg_Billing_Zip__c
                FROM evt__Attendee__c
                WHERE Id = :request.attendeeId
                LIMIT 1
            ];
            if (attendeeList.isEmpty()) {
                throw new AuraHandledException('Attendee not found for ID: ' + request.attendeeId);
            }
            evt__Attendee__c attendee = attendeeList[0];

            // ── QUERY 2: Original Opportunity ──────────────────────
            List<Opportunity> oppList = [
                SELECT Id, Name, AccountId, ContactId, OwnerId, Amount,
                       StageName, Pricebook2Id, RecordTypeId,
                       Registration_Change_Type__c, Registration_Type__c,
                       Registration_Date__c, CloseDate,
                       EE_Program__c, Special_Event__c,
                       Program_Code__c, Program_Acronym__c, Program_Name__c,
                       Billing_Contact__c, Invoice__c,
                       Reg_Change_Comments__c, Reg_Change_Date__c,
                       Discount_Amount__c, Number_of_Discounts__c,
                       Parent_Opportunity__c, Primary_Contact__c,
                       Payment_Status__c, Total_Paid__c, Is_Payment_Opportunity__c,
                       Has_Parent_Opportunity__c,
                       How_they_heard_about_program__c,
                       How_they_heard_about_program_Other__c
                FROM Opportunity
                WHERE Id = :request.originalOppId
                LIMIT 1
            ];
            if (oppList.isEmpty()) {
                throw new AuraHandledException('Original Opportunity not found for ID: ' + request.originalOppId);
            }
            Opportunity originalOpp = oppList[0];

            // ── QUERY 3: New Program (Special Event) ─────────────────
            List<evt__Special_Event__c> programList = [
                SELECT Id, Name, evt__Start__c, evt__End__c,
                       Program_Code__c, Program_Acronym__c, Program__c,
                       Expected_Program_Fee__c, EE_Program__c,
                       Custom_Program__c, Multi_Module_Program__c
                FROM evt__Special_Event__c
                WHERE Id = :request.newSpecialEventId
                LIMIT 1
            ];
            if (programList.isEmpty()) {
                throw new AuraHandledException('Target program not found for ID: ' + request.newSpecialEventId);
            }
            evt__Special_Event__c newProgram = programList[0];
            
            // ── QUERY 3b: New EE Program to get Product__c ───────────
            Id newProgramProductId = null;
            if (newProgram.EE_Program__c != null) {
                List<EE_Program__c> eeProgList = [
                    SELECT Id, Product__c
                    FROM EE_Program__c
                    WHERE Id = :newProgram.EE_Program__c
                    LIMIT 1
                ];
                if (!eeProgList.isEmpty() && eeProgList[0].Product__c != null) {
                    newProgramProductId = eeProgList[0].Product__c;
                }
            }

            // ── QUERY 4: Original Program Fee OLIs ─────────────────
            List<OpportunityLineItem> originalProgramFees = [
                SELECT Id, PricebookEntryId, Product2Id, Product2.Name,
                       UnitPrice, Quantity, TotalPrice
                FROM OpportunityLineItem
                WHERE OpportunityId = :originalOpp.Id
                  AND Product_Family__c = 'Program Fee'
                  AND Reverse_Product_Line_Item__c = false
            ];

            // ── QUERY 4b: Original Discount OLIs ─────────────────────
            // Org uses Product_Family__c = 'Discounts' (plural) per Transfer_Subflow
            List<OpportunityLineItem> originalDiscountOLIs = [
                SELECT Id, PricebookEntryId, Product2Id, Product2.Name,
                       UnitPrice, Quantity, TotalPrice, Discount_Code__c, Description
                FROM OpportunityLineItem
                WHERE OpportunityId = :originalOpp.Id
                  AND (Product_Family__c = 'Discount' OR Product_Family__c = 'Discounts')
            ];

            // ── QUERY 5: ALL PricebookEntries upfront ──────────────
            // Single query replaces 3-4 separate PBE queries
            Map<String, PricebookEntry> pbeByKey = new Map<String, PricebookEntry>();
            Map<String, PricebookEntry> pbeByDiscountCode = new Map<String, PricebookEntry>();
            PricebookEntry newProgramPBE = null;
            
            if (originalOpp.Pricebook2Id != null) {
                List<PricebookEntry> allPBEs = [
                    SELECT Id, Product2Id, Product2.Name, Product2.Family, Product2.ProductCode, Product2.Discount_Percent__c, UnitPrice
                    FROM PricebookEntry
                    WHERE Pricebook2Id = :originalOpp.Pricebook2Id
                      AND IsActive = true
                      AND (Product2.Family = 'Program Fee'
                           OR Product2.Family = 'Discount'
                           OR Product2.Family = 'Discounts'
                           OR Product2.Name = 'Transfer Fee')
                ];
                for (PricebookEntry pbe : allPBEs) {
                    if (pbe.Product2.Name == 'Transfer Fee') {
                        pbeByKey.put('TransferFee', pbe);
                    } else if (pbe.Product2.Family == 'Discount' || pbe.Product2.Family == 'Discounts') {
                        pbeByKey.put('Discount', pbe);
                        if (pbe.Product2.ProductCode != null) {
                            pbeByDiscountCode.put(pbe.Product2.ProductCode.toUpperCase().trim(), pbe);
                        }
                        if (pbe.Product2.Name != null) {
                            pbeByDiscountCode.put(pbe.Product2.Name.toUpperCase().trim(), pbe);
                        }
                    } else if (pbe.Product2.Family == 'Program Fee') {
                        pbeByKey.put('ProgramFee', pbe);
                        // Check if this is the PBE for the new program's product
                        if (newProgramProductId != null && pbe.Product2Id == newProgramProductId) {
                            newProgramPBE = pbe;
                        }
                    }
                }
            }

            // ── QUERY 6: ALL payments in one query ─────────────────
            List<pymt__PaymentX__c> allPayments = [
                SELECT Id, pymt__Opportunity__c, pymt__Amount__c, pymt__Status__c,
                       pymt__Date__c, Amount_Due__c, Balance__c
                FROM pymt__PaymentX__c
                WHERE pymt__Opportunity__c = :originalOpp.Id
                ORDER BY pymt__Date__c ASC
            ];

            // ════════════════════════════════════════════════════════
            // DML PHASE — no more SOQL queries from here on
            // ════════════════════════════════════════════════════════

            Decimal originalFeeTotal = 0;
            for (OpportunityLineItem oli : originalProgramFees) {
                if (oli.TotalPrice != null) {
                    originalFeeTotal += oli.TotalPrice;
                }
            }

            Decimal originalDiscountTotal = 0;
            for (OpportunityLineItem oli : originalDiscountOLIs) {
                if (oli.TotalPrice != null) {
                    originalDiscountTotal += oli.TotalPrice;
                }
            }
            // Net amount the registrant owed for program + discounts (discount lines are typically negative).
            Decimal netOriginalRegistration = originalFeeTotal + originalDiscountTotal;

            // 1. Credit line item to offset net original registration (not gross program fee alone)
            List<OpportunityLineItem> olisToInsert = new List<OpportunityLineItem>();

            if (netOriginalRegistration > 0 && !originalProgramFees.isEmpty()) {
                OpportunityLineItem creditOLI = new OpportunityLineItem();
                creditOLI.OpportunityId = originalOpp.Id;
                creditOLI.PricebookEntryId = originalProgramFees[0].PricebookEntryId;
                creditOLI.Quantity = 1;
                creditOLI.UnitPrice = -netOriginalRegistration;
                creditOLI.Reverse_Product_Line_Item__c = true;
                creditOLI.Internal_Comments__c = 'Transfer credit - offsets net original registration (program fee less discounts)';
                olisToInsert.add(creditOLI);
            }

            // 2. Transfer Fee line item (if applicable)
            if (request.applyTransferFee && pbeByKey.containsKey('TransferFee')) {
                PricebookEntry transferFeePBE = pbeByKey.get('TransferFee');
                OpportunityLineItem transferFeeOLI = new OpportunityLineItem();
                transferFeeOLI.OpportunityId = originalOpp.Id;
                transferFeeOLI.PricebookEntryId = transferFeePBE.Id;
                transferFeeOLI.Quantity = 1;
                // Use custom amount if provided, otherwise fall back to PBE price
                transferFeeOLI.UnitPrice = (request.transferFeeAmount != null && request.transferFeeAmount > 0)
                    ? request.transferFeeAmount
                    : transferFeePBE.UnitPrice;
                transferFeeOLI.Internal_Comments__c = 'Transfer fee applied';
                olisToInsert.add(transferFeeOLI);
            }

            // 3. Update original Attendee
            //    evt__Invitation_Status__c drives the Status__c formula.
            //    Setting to 'Transferred' makes Status__c = 'Transferred Out'.
            attendee.evt__Invitation_Status__c = 'Transferred';
            attendee.Transferred_to__c = request.newSpecialEventId;
            update attendee;

            // 4. Update original Opportunity
            originalOpp.StageName = 'Transferred Out';
            originalOpp.Registration_Change_Type__c = 'Transferred Out';
            originalOpp.Reg_Change_Date__c = Date.today();
            originalOpp.Reg_Change_Processed_By__c = UserInfo.getUserId();
            originalOpp.Reg_Change_Comments__c = request.regChangeComments;
            originalOpp.Transferred_to__c = request.newSpecialEventId;
            update originalOpp;

            // Batch insert credit + transfer fee OLIs
            // Insert after updating the original Opportunity so that
            // org automation (e.g., Opportunity Tracker) sees
            // Registration_Change_Type__c = 'Transferred Out' when Amount changes.
            if (!olisToInsert.isEmpty()) {
                insert olisToInsert;
            }

            // 5. Create new Registration Opportunity
            Opportunity newOpp = new Opportunity();
            newOpp.AccountId = originalOpp.AccountId;
            // Use Primary_Contact__c if available, otherwise fall back to ContactId
            Id primaryContact = originalOpp.Primary_Contact__c != null 
                ? originalOpp.Primary_Contact__c 
                : originalOpp.ContactId;
            newOpp.ContactId = primaryContact;
            newOpp.Primary_Contact__c = primaryContact;
            newOpp.OwnerId = originalOpp.OwnerId;
            newOpp.RecordTypeId = originalOpp.RecordTypeId;
            newOpp.Pricebook2Id = originalOpp.Pricebook2Id;
            newOpp.StageName = 'Registered';
            newOpp.CloseDate = Date.today();
            newOpp.Registration_Date__c = Date.today();
            newOpp.Registration_Type__c = originalOpp.Registration_Type__c;
            newOpp.Billing_Contact__c = originalOpp.Billing_Contact__c;
            newOpp.Special_Event__c = request.newSpecialEventId;
            newOpp.EE_Program__c = newProgram.EE_Program__c;
            newOpp.How_they_heard_about_program__c = originalOpp.How_they_heard_about_program__c;
            newOpp.How_they_heard_about_program_Other__c = originalOpp.How_they_heard_about_program_Other__c;
            newOpp.Registration_Change_Type__c = 'Transferred In';
            newOpp.Reg_Change_Date__c = Date.today();
            newOpp.Reg_Change_Original_Opportunity__c = originalOpp.Id;
            newOpp.Reg_Change_Comments__c = request.regChangeComments;
            newOpp.Reg_Change_Processed_By__c = UserInfo.getUserId();

            // Naming convention: "{ProgramAcronym} Registration - {FirstName} {LastName}"
            // Matches original Transfer_Subflow
            String oppName = '';
            if (newProgram.Program_Acronym__c != null) {
                oppName = newProgram.Program_Acronym__c + ' Registration - ';
            }
            if (attendee.evt__First_Name__c != null) {
                oppName += attendee.evt__First_Name__c + ' ';
            }
            if (attendee.evt__Last_Name__c != null) {
                oppName += attendee.evt__Last_Name__c;
            }
            newOpp.Name = oppName.trim();

            if (originalOpp.Parent_Opportunity__c != null) {
                newOpp.Parent_Opportunity__c = originalOpp.Parent_Opportunity__c;
            }

            insert newOpp;

            // Back-populate the lookup (defer update to batch with invoice handling below)
            originalOpp.Reg_Change_New_Opportunity__c = newOpp.Id;

            // 6. Create OpportunityContactRole
            Id primaryContactId = originalOpp.Primary_Contact__c != null 
                ? originalOpp.Primary_Contact__c 
                : originalOpp.ContactId;
            if (primaryContactId != null) {
                OpportunityContactRole ocr = new OpportunityContactRole();
                ocr.OpportunityId = newOpp.Id;
                ocr.ContactId = primaryContactId;
                ocr.IsPrimary = true;
                ocr.Role = 'Decision Maker';
                insert ocr;
            }

            // 7. Add Program Fee to new Opportunity
            List<OpportunityLineItem> newOppOLIs = new List<OpportunityLineItem>();

            if (request.newProgramFeeAmount != null && request.newProgramFeeAmount > 0) {
                PricebookEntry newProgramFeePBE;
                if (request.sameProgramTransfer && !originalProgramFees.isEmpty()) {
                    // Same program - reuse the original PBE
                    newProgramFeePBE = new PricebookEntry(Id = originalProgramFees[0].PricebookEntryId);
                } else if (newProgramPBE != null) {
                    // Different program - use the PBE matching the new program's Product
                    newProgramFeePBE = newProgramPBE;
                } else if (pbeByKey.containsKey('ProgramFee')) {
                    // Fallback to generic Program Fee PBE
                    newProgramFeePBE = pbeByKey.get('ProgramFee');
                }

                if (newProgramFeePBE != null) {
                    OpportunityLineItem newProgramFeeOLI = new OpportunityLineItem();
                    newProgramFeeOLI.OpportunityId = newOpp.Id;
                    newProgramFeeOLI.PricebookEntryId = newProgramFeePBE.Id;
                    newProgramFeeOLI.Quantity = 1;
                    newProgramFeeOLI.UnitPrice = request.newProgramFeeAmount;
                    // Also set Product2Id for correct product association
                    if (newProgramProductId != null) {
                        newProgramFeeOLI.Product2Id = newProgramProductId;
                    }
                    newOppOLIs.add(newProgramFeeOLI);
                }
            }

            // 8. Apply Discount to new Opp (if applicable)
            Decimal effectiveDiscountAmount = 0;
            if (request.applyDiscount) {
                if (!originalDiscountOLIs.isEmpty()) {
                    // Copy original discount OLIs to new opportunity
                    Boolean sameProgramEE = originalOpp.EE_Program__c != null
                        && newProgram.EE_Program__c != null
                        && originalOpp.EE_Program__c == newProgram.EE_Program__c;

                    for (OpportunityLineItem origDiscount : originalDiscountOLIs) {
                        OpportunityLineItem discountOLI = new OpportunityLineItem();
                        discountOLI.OpportunityId = newOpp.Id;
                        discountOLI.PricebookEntryId = origDiscount.PricebookEntryId;
                        discountOLI.Quantity = 1;
                        discountOLI.Description = origDiscount.Description;

                        if (sameProgramEE) {
                            // Same program - use original discount amount
                            discountOLI.UnitPrice = origDiscount.UnitPrice;
                        } else {
                            // Different program - recalculate based on new program fee
                            Decimal originalFeeForCalc = 0;
                            for (OpportunityLineItem pf : originalProgramFees) {
                                if (pf.TotalPrice != null) originalFeeForCalc += pf.TotalPrice;
                            }
                            if (originalFeeForCalc > 0 && origDiscount.UnitPrice != null) {
                                Decimal discountPercent = Math.abs(origDiscount.UnitPrice) / originalFeeForCalc;
                                Decimal newFee = request.newProgramFeeAmount != null ? request.newProgramFeeAmount : 0;
                                discountOLI.UnitPrice = -(newFee * discountPercent);
                            } else {
                                discountOLI.UnitPrice = origDiscount.UnitPrice;
                            }
                        }

                        effectiveDiscountAmount += (origDiscount.UnitPrice != null ? Math.abs(origDiscount.UnitPrice) : 0);
                        newOppOLIs.add(discountOLI);
                    }
                } else {
                    // No original discounts — use discount amount and/or discount code from Products
                    PricebookEntry discountPBE = null;
                    Decimal discountAmt = (request.discountAmount != null && request.discountAmount > 0)
                        ? -Math.abs(request.discountAmount) : null;
                    if (String.isNotBlank(request.discountCode) && pbeByDiscountCode.containsKey(request.discountCode.toUpperCase().trim())) {
                        discountPBE = pbeByDiscountCode.get(request.discountCode.toUpperCase().trim());
                        if (discountAmt == null && discountPBE != null) {
                            // Prefer Product2.Discount_Percent__c to calculate from new program fee
                            Decimal newFee = request.newProgramFeeAmount != null ? request.newProgramFeeAmount : 0;
                            if (discountPBE.Product2.Discount_Percent__c != null && discountPBE.Product2.Discount_Percent__c > 0 && newFee > 0) {
                                discountAmt = -(newFee * discountPBE.Product2.Discount_Percent__c / 100);
                            } else if (discountPBE.UnitPrice != null && discountPBE.UnitPrice != 0) {
                                discountAmt = discountPBE.UnitPrice < 0 ? discountPBE.UnitPrice : -discountPBE.UnitPrice;
                            }
                        }
                    }
                    if (discountPBE == null && pbeByKey.containsKey('Discount')) {
                        discountPBE = pbeByKey.get('Discount');
                    }
                    if (discountPBE != null && discountAmt == null && discountPBE.UnitPrice != null && discountPBE.UnitPrice != 0) {
                        discountAmt = discountPBE.UnitPrice < 0 ? discountPBE.UnitPrice : -Math.abs(discountPBE.UnitPrice);
                    }
                    if (discountPBE != null && discountAmt != null && discountAmt != 0) {
                        OpportunityLineItem discountOLI = new OpportunityLineItem();
                        discountOLI.OpportunityId = newOpp.Id;
                        discountOLI.PricebookEntryId = discountPBE.Id;
                        discountOLI.Quantity = 1;
                        discountOLI.UnitPrice = discountAmt;
                        if (String.isNotBlank(request.discountCode)) {
                            discountOLI.Description = request.discountCode.trim();
                        }
                        effectiveDiscountAmount = Math.abs(discountAmt);
                        newOppOLIs.add(discountOLI);
                    }
                }
            }

            // Batch insert new Opp OLIs
            if (!newOppOLIs.isEmpty()) {
                insert newOppOLIs;
            }

            // 9. Create new Attendee
            evt__Attendee__c newAttendee = new evt__Attendee__c();
            newAttendee.evt__Contact__c = attendee.evt__Contact__c;
            newAttendee.Account__c = attendee.Account__c;
            newAttendee.Opportunity__c = newOpp.Id;
            newAttendee.evt__Event__c = request.newSpecialEventId;
            newAttendee.evt__Invitation_Status__c = 'Registered';
            newAttendee.Registration_Date__c = Date.today();
            newAttendee.evt__Registration_Type__c = attendee.evt__Registration_Type__c;
            newAttendee.Reg_Government__c = attendee.Reg_Government__c;
            newAttendee.Reg_Gender__c = attendee.Reg_Gender__c;
            newAttendee.Reg_Industry__c = attendee.Reg_Industry__c;
            newAttendee.Reg_Job_Function__c = attendee.Reg_Job_Function__c;
            newAttendee.Reg_Job_Level__c = attendee.Reg_Job_Level__c;
            newAttendee.Reg_How_they_heard_about_program__c = attendee.Reg_How_they_heard_about_program__c;
            newAttendee.Reg_How_they_heard_about_program_Other__c = attendee.Reg_How_they_heard_about_program_Other__c;
            newAttendee.Reg_Highest_Degree_Completed__c = attendee.Reg_Highest_Degree_Completed__c;
            newAttendee.Reg_Years_of_Work_Experience__c = attendee.Reg_Years_of_Work_Experience__c;
            newAttendee.Reg_LinkedIn_URL__c = attendee.Reg_LinkedIn_URL__c;
            newAttendee.Reg_Prefix__c = attendee.Reg_Prefix__c;
            newAttendee.Reg_Suffix__c = attendee.Reg_Suffix__c;
            newAttendee.Reg_Middle_Name__c = attendee.Reg_Middle_Name__c;
            newAttendee.Reg_Preferred_Name__c = attendee.Reg_Preferred_Name__c;
            newAttendee.Reg_Billing_City__c = attendee.Reg_Billing_City__c;
            newAttendee.Reg_Billing_Country__c = attendee.Reg_Billing_Country__c;
            newAttendee.Reg_Billing_State__c = attendee.Reg_Billing_State__c;
            newAttendee.Reg_Billing_Street__c = attendee.Reg_Billing_Street__c;
            newAttendee.Reg_Billing_Zip__c = attendee.Reg_Billing_Zip__c;

            insert newAttendee;

            // Update newOpp: Attendee__c + Invoice handling
            // Always create a NEW invoice for the new opp — never link to the old invoice.
            // Original opp keeps its invoice; Revise_Invoice__c triggers org to update it.
            newOpp.Attendee__c = newAttendee.Id;
            primaryContactId = originalOpp.Primary_Contact__c != null ? originalOpp.Primary_Contact__c : originalOpp.ContactId;
            if (primaryContactId == null && attendee.evt__Contact__c != null) {
                primaryContactId = attendee.evt__Contact__c;
            }
            String nextInvoiceNumber = getNextInvoiceNumber();
            Invoice__c newInvoice = new Invoice__c();
            newInvoice.Opportunity__c = newOpp.Id;
            if (primaryContactId != null) {
                newInvoice.Contact__c = primaryContactId;
            }
            // Set both the Name and Invoice_Number__c fields to use
            // the EE+number convention, matching the client's PROD behavior.
            newInvoice.Name = nextInvoiceNumber;
            newInvoice.Invoice_Number__c = nextInvoiceNumber;
            insert newInvoice;
            newOpp.Invoice__c = newInvoice.Id;
            // Invoice_Auto_Number__c is Decimal — store numeric part only (e.g. 102214 from EE102214)
            if (nextInvoiceNumber.length() > 2 && nextInvoiceNumber.substring(2).isNumeric()) {
                newOpp.Invoice_Auto_Number__c = Decimal.valueOf(nextInvoiceNumber.substring(2));
            }
            newOpp.Invoice_Created__c = Date.today();
            newOpp.Set_Create_Invoice__c = true;
            update newOpp;

            // 10. Payment Handling — DEFERRED to @future to avoid SOQL limit (Payment Master, DLRS)
            // Calculate the new opportunity total amount
            Decimal newOppTotal = request.newProgramFeeAmount != null ? request.newProgramFeeAmount : 0;
            if (request.applyDiscount) {
                Decimal discountToApply = effectiveDiscountAmount > 0 ? effectiveDiscountAmount
                    : (request.discountAmount != null && request.discountAmount > 0 ? request.discountAmount : 0);
                newOppTotal -= discountToApply;
            }
            
            String paymentStatus = originalOpp.Payment_Status__c;
            Boolean isStandalone = originalOpp.Has_Parent_Opportunity__c != 'Yes';
            Boolean hasPaidPayments = originalOpp.Total_Paid__c != null && originalOpp.Total_Paid__c > 0;
            
            List<Id> paymentIdsToMove = new List<Id>();
            for (pymt__PaymentX__c pmt : allPayments) {
                if (isStandalone) {
                    if (pmt.pymt__Status__c == 'Completed' && hasPaidPayments) {
                        paymentIdsToMove.add(pmt.Id);
                    } else if (pmt.pymt__Status__c != 'Completed') {
                        paymentIdsToMove.add(pmt.Id);
                    }
                }
            }
            
            Decimal actualTransferFee = (request.applyTransferFee && request.transferFeeAmount != null && request.transferFeeAmount > 0)
                ? request.transferFeeAmount
                : (request.applyTransferFee && pbeByKey.containsKey('TransferFee') ? pbeByKey.get('TransferFee').UnitPrice : 0);
            Decimal netCredit = 0;
            if (String.isNotBlank(request.settlementType)) {
                netCredit = netOriginalRegistration - actualTransferFee;
            }

            // 11. Settlement Handling — Unapplied Funds stays in main tx (no Payment Master trigger)
            if (String.isNotBlank(request.settlementType) && request.settlementType == 'Unapplied Funds' && netCredit > 0) {
                Unapplied_Funds__c uf = new Unapplied_Funds__c();
                uf.Amount__c = netCredit;
                uf.Contact__c = originalOpp.ContactId;
                uf.Originating_Opportunity__c = originalOpp.Id;
                uf.Applied_Opportunity__c = newOpp.Id;
                uf.Original_Credit_Amount__c = netCredit;
                uf.Memo__c = 'Transfer from ' + originalOpp.Name + ' to ' + newOpp.Name;
                insert uf;
            }

            // 12. Defer payment DML to avoid SOQL limit (Payment Master flow)
            deferTransferPaymentUpdates(
                paymentIdsToMove,
                newOpp.Id,
                newOppTotal,
                originalOpp.Id,
                originalOpp.Name,
                originalOpp.Primary_Contact__c != null ? originalOpp.Primary_Contact__c : originalOpp.ContactId,
                originalOpp.AccountId,
                request.applyTransferFee && actualTransferFee > 0,
                actualTransferFee,
                request.settlementType == 'Refund' && netCredit > 0,
                netCredit,
                originalOpp.Invoice__c != null
            );

            // 13. originalOpp Reg_Change_New_Opportunity__c + Revise_Invoice__c — deferred to @future
            // (avoids Payment Master / Payment Link flow SOQL limit in main transaction)

            // Build result
            result.success = true;
            result.newOpportunityId = newOpp.Id;
            result.newAttendeeId = newAttendee.Id;
            result.newOpportunityName = newOpp.Name;

        } catch (Exception e) {
            Database.rollback(sp);
            result.success = false;
            result.errorMessage = e.getMessage() + ' | ' + e.getStackTraceString();
        }

        return result;
    }

    // --- INVOICE NUMBER SEQUENCE (EE + numeric, via Auto_Number__c) ---
    private static String getNextInvoiceNumber() {
        Integer nextNum = 1;

        try {
            // Primary source of truth: Auto_Number__c where Type__c = 'Invoice Number'.
            // FOR UPDATE ensures we safely increment the counter even under concurrency.
            List<Auto_Number__c> seqList = [
                SELECT Id, Current_Number__c
                FROM Auto_Number__c
                WHERE Type__c = 'Invoice Number'
                LIMIT 1
                FOR UPDATE
            ];

            if (!seqList.isEmpty()) {
                Auto_Number__c seq = seqList[0];
                if (seq.Current_Number__c != null) {
                    nextNum = Integer.valueOf(seq.Current_Number__c) + 1;
                }
                seq.Current_Number__c = nextNum;
                update seq;
            } else {
                // Fallback: if no Auto_Number__c row exists yet, derive next from Invoice__c
                // and create a new sequence record so future calls stay in sync.
                List<Invoice__c> latest = [
                    SELECT Invoice_Number__c
                    FROM Invoice__c
                    WHERE Invoice_Number__c LIKE 'EE%'
                    ORDER BY Invoice_Number__c DESC
                    LIMIT 1
                ];
                if (!latest.isEmpty() && String.isNotBlank(latest[0].Invoice_Number__c)) {
                    String numPart = latest[0].Invoice_Number__c.substring(2);
                    if (numPart.isNumeric()) {
                        nextNum = Integer.valueOf(numPart) + 1;
                    }
                }
                Auto_Number__c newSeq = new Auto_Number__c(
                    Type__c = 'Invoice Number',
                    Current_Number__c = nextNum
                );
                insert newSeq;
            }
        } catch (Exception e) {
            // As a safety net, if anything goes wrong with Auto_Number__c
            // (e.g. object/fields not present in a lower environment),
            // fall back to the legacy max-Invoice__c approach so we
            // never block transfers.
            List<Invoice__c> latest = [
                SELECT Invoice_Number__c
                FROM Invoice__c
                WHERE Invoice_Number__c LIKE 'EE%'
                ORDER BY Invoice_Number__c DESC
                LIMIT 1
            ];
            if (!latest.isEmpty() && String.isNotBlank(latest[0].Invoice_Number__c)) {
                String numPart = latest[0].Invoice_Number__c.substring(2);
                if (numPart.isNumeric()) {
                    nextNum = Integer.valueOf(numPart) + 1;
                }
            }
        }

        return 'EE' + String.valueOf(nextNum);
    }

    // --- DEFERRED PAYMENT UPDATES (avoids SOQL limit from Payment Master flow) ---
    @future
    public static void deferTransferPaymentUpdates(
        List<Id> paymentIdsToMove,
        Id newOppId,
        Decimal newOppTotal,
        Id originalOppId,
        String originalOppName,
        Id contactId,
        Id accountId,
        Boolean createTransferFeePayment,
        Decimal transferFeeAmount,
        Boolean createRefund,
        Decimal refundAmount,
        Boolean setReviseInvoice
    ) {
        if (paymentIdsToMove != null && !paymentIdsToMove.isEmpty()) {
            List<pymt__PaymentX__c> payments = [
                SELECT Id, pymt__Opportunity__c, pymt__Status__c, pymt__Amount__c
                FROM pymt__PaymentX__c
                WHERE Id IN :paymentIdsToMove
            ];
            for (pymt__PaymentX__c pmt : payments) {
                pmt.pymt__Opportunity__c = newOppId;
                if (pmt.pymt__Status__c != 'Completed') {
                    pmt.pymt__Amount__c = newOppTotal;
                }
            }
            update payments;
        }
        if (createTransferFeePayment && transferFeeAmount > 0) {
            pymt__PaymentX__c transferFeePayment = new pymt__PaymentX__c();
            transferFeePayment.pymt__Opportunity__c = originalOppId;
            transferFeePayment.pymt__Amount__c = transferFeeAmount;
            transferFeePayment.pymt__Status__c = 'Scheduled';
            transferFeePayment.pymt__Date__c = Date.today();
            transferFeePayment.pymt__Memo__c = 'Transfer fee for transfer to new registration';
            transferFeePayment.pymt__Contact__c = contactId;
            transferFeePayment.pymt__Account__c = accountId;
            insert transferFeePayment;
        }
        if (createRefund && refundAmount > 0) {
            pymt__PaymentX__c refund = new pymt__PaymentX__c();
            refund.pymt__Opportunity__c = originalOppId;
            refund.pymt__Amount__c = -refundAmount;
            refund.pymt__Status__c = 'Pending';
            refund.pymt__Date__c = Date.today();
            refund.pymt__Memo__c = 'Refund for transfer';
            refund.pymt__Contact__c = contactId;
            refund.pymt__Account__c = accountId;
            refund.RecordTypeId = Schema.SObjectType.pymt__PaymentX__c
                .getRecordTypeInfosByDeveloperName().get('Refund').getRecordTypeId();
            insert refund;
        }
        Opportunity origOpp = new Opportunity(
            Id = originalOppId,
            Reg_Change_New_Opportunity__c = newOppId,
            Revise_Invoice__c = setReviseInvoice
        );
        update origOpp;
    }

    // --- EXECUTE CANCELLATION --------------------------------------------

    @AuraEnabled
    public static CancellationResult executeCancellation(CancellationRequest request) {
        CancellationResult result = new CancellationResult();
        Savepoint sp = Database.setSavepoint();

        try {
            // ── Validate inputs ──────────────────────────────────
            if (request.attendeeId == null) {
                throw new AuraHandledException('attendeeId is null — the component may not have received the record ID.');
            }
            if (request.originalOppId == null) {
                throw new AuraHandledException('originalOppId is null — the original Opportunity ID was not provided.');
            }

            // ── QUERY 1: Attendee ──────────────────────────────────
            List<evt__Attendee__c> attendeeList = [
                SELECT Id, Name, evt__Contact__c, Account__c, Opportunity__c,
                       evt__Invitation_Status__c, evt__Event__c
                FROM evt__Attendee__c
                WHERE Id = :request.attendeeId
                LIMIT 1
            ];
            if (attendeeList.isEmpty()) {
                throw new AuraHandledException('Attendee not found for ID: ' + request.attendeeId);
            }
            evt__Attendee__c attendee = attendeeList[0];

            // ── QUERY 2: Original Opportunity ──────────────────────
            List<Opportunity> oppList = [
                SELECT Id, Name, AccountId, ContactId, OwnerId, Amount,
                       StageName, Pricebook2Id, RecordTypeId,
                       Payment_Status__c, Has_Parent_Opportunity__c,
                       Parent_Opportunity__c, Revise_Invoice__c
                FROM Opportunity
                WHERE Id = :request.originalOppId
                LIMIT 1
            ];
            if (oppList.isEmpty()) {
                throw new AuraHandledException('Original Opportunity not found for ID: ' + request.originalOppId);
            }
            Opportunity originalOpp = oppList[0];

            if (opportunityHasReasonLostField() && String.isBlank(request.reasonLost)) {
                throw new AuraHandledException('Reason Lost is required to cancel this registration.');
            }

            // Original program-fee line PBE (same product as registration) for credit/refund/unapplied lines
            PricebookEntry originalProgramFeePBE = null;
            List<OpportunityLineItem> originalProgramFeeOlis = [
                SELECT PricebookEntryId
                FROM OpportunityLineItem
                WHERE OpportunityId = :originalOpp.Id
                  AND Product_Family__c = 'Program Fee'
                  AND (Reverse_Product_Line_Item__c = false OR Reverse_Product_Line_Item__c = null)
                ORDER BY CreatedDate ASC
                LIMIT 1
            ];
            if (!originalProgramFeeOlis.isEmpty() && originalProgramFeeOlis[0].PricebookEntryId != null) {
                List<PricebookEntry> opfVerify = [
                    SELECT Id
                    FROM PricebookEntry
                    WHERE Id = :originalProgramFeeOlis[0].PricebookEntryId
                      AND IsActive = true
                    LIMIT 1
                ];
                if (!opfVerify.isEmpty()) {
                    originalProgramFeePBE = opfVerify[0];
                }
            }

            // ── QUERY 3: PricebookEntries for cancellation products ─
            Map<String, PricebookEntry> pbeByName = new Map<String, PricebookEntry>();
            if (originalOpp.Pricebook2Id != null) {
                List<PricebookEntry> allPBEs = [
                    SELECT Id, Product2Id, Product2.Name, Product2.Family, UnitPrice
                    FROM PricebookEntry
                    WHERE Pricebook2Id = :originalOpp.Pricebook2Id
                      AND IsActive = true
                      AND (Product2.Name LIKE '%Cancel%'
                           OR Product2.Name LIKE '%Refund%'
                           OR Product2.Name LIKE '%Unapplied%'
                           OR Product2.Family = 'Program Fee')
                ];
                for (PricebookEntry pbe : allPBEs) {
                    pbeByName.put(pbe.Product2.Name, pbe);
                    // First Program Fee in iteration order — avoid last-match overwriting wrong product
                    if (pbe.Product2.Family == 'Program Fee' && !pbeByName.containsKey('ProgramFee')) {
                        pbeByName.put('ProgramFee', pbe);
                    }
                }
            }

            // ── QUERY 4: Payments ───────────────────────────────────
            Id paymentOppId = (originalOpp.Has_Parent_Opportunity__c == 'Yes' && originalOpp.Parent_Opportunity__c != null)
                ? originalOpp.Parent_Opportunity__c
                : originalOpp.Id;

            List<pymt__PaymentX__c> completedPayments = [
                SELECT Id, pymt__Opportunity__c, pymt__Amount__c, pymt__Status__c, pymt__Date__c
                FROM pymt__PaymentX__c
                WHERE pymt__Opportunity__c = :paymentOppId
                  AND pymt__Status__c = 'Completed'
                ORDER BY pymt__Date__c DESC
                LIMIT 1
            ];

            List<pymt__PaymentX__c> pendingPayments = [
                SELECT Id, pymt__Opportunity__c, pymt__Amount__c, pymt__Status__c, pymt__Date__c
                FROM pymt__PaymentX__c
                WHERE pymt__Opportunity__c = :paymentOppId
                  AND pymt__Status__c IN ('Scheduled', 'In Process')
                ORDER BY pymt__Date__c DESC
                LIMIT 1
            ];

            // ── QUERY 5: Parent Opportunity (if exists) ────────────
            Opportunity parentOpp = null;
            if (originalOpp.Parent_Opportunity__c != null) {
                List<Opportunity> parentList = [
                    SELECT Id, Revise_Invoice__c
                    FROM Opportunity
                    WHERE Id = :originalOpp.Parent_Opportunity__c
                    LIMIT 1
                ];
                if (!parentList.isEmpty()) {
                    parentOpp = parentList[0];
                }
            }

            // ════════════════════════════════════════════════════════
            // DML PHASE
            // ════════════════════════════════════════════════════════

            Decimal oppAmount = originalOpp.Amount != null ? originalOpp.Amount : 0;
            Decimal cancellationFee = (request.applyCancellationFee && request.cancellationFeeAmount != null)
                ? request.cancellationFeeAmount : 0;
            Decimal refundAmount = oppAmount - cancellationFee;

            // 1. Update Attendee status to 'Cancelled'
            attendee.evt__Invitation_Status__c = 'Cancelled';
            update attendee;

            // 2. Create line items
            List<OpportunityLineItem> olisToInsert = new List<OpportunityLineItem>();

            // 2a. Cancellation Fee line item (if applicable)
            if (request.applyCancellationFee && cancellationFee > 0) {
                PricebookEntry cancelFeePBE = pbeByName.get('Cancellation Fee');
                if (cancelFeePBE == null) {
                    cancelFeePBE = pbeByName.get('ProgramFee');
                }
                if (cancelFeePBE != null) {
                    OpportunityLineItem cancelFeeOLI = new OpportunityLineItem();
                    cancelFeeOLI.OpportunityId = originalOpp.Id;
                    cancelFeeOLI.PricebookEntryId = cancelFeePBE.Id;
                    cancelFeeOLI.Quantity = 1;
                    cancelFeeOLI.UnitPrice = cancellationFee;
                    cancelFeeOLI.Description = 'Cancellation Fee';
                    olisToInsert.add(cancelFeeOLI);
                }
            }

            // 2b. Credit line item (negative amount = net registration / Opportunity.Amount)
            if (oppAmount > 0) {
                PricebookEntry creditPBE = originalProgramFeePBE;
                if (creditPBE == null) {
                    creditPBE = pbeByName.get('Cancellation Credit');
                }
                if (creditPBE == null) {
                    creditPBE = pbeByName.get('ProgramFee');
                }
                if (creditPBE != null) {
                    OpportunityLineItem creditOLI = new OpportunityLineItem();
                    creditOLI.OpportunityId = originalOpp.Id;
                    creditOLI.PricebookEntryId = creditPBE.Id;
                    creditOLI.Quantity = 1;
                    creditOLI.UnitPrice = -oppAmount;
                    creditOLI.Description = 'Cancellation Credit';
                    olisToInsert.add(creditOLI);
                }
            }

            // Insert line items
            if (!olisToInsert.isEmpty()) {
                insert olisToInsert;
            }

            // 3. Payment handling based on Payment Status
            String paymentStatus = originalOpp.Payment_Status__c;

            if (paymentStatus == 'Not Paid' && !pendingPayments.isEmpty()) {
                // Cancel or update pending payment
                pymt__PaymentX__c pendingPayment = pendingPayments[0];
                if (originalOpp.Has_Parent_Opportunity__c != 'Yes' && !request.applyCancellationFee) {
                    // Cancel the payment
                    pendingPayment.pymt__Status__c = 'Cancelled';
                    update pendingPayment;
                } else {
                    // Update payment amount (subtract opp amount, add cancellation fee)
                    Decimal pendingAmt = pendingPayment.pymt__Amount__c != null ? pendingPayment.pymt__Amount__c : 0;
                    Decimal newAmount = pendingAmt - oppAmount + cancellationFee;
                    pendingPayment.pymt__Amount__c = newAmount;
                    update pendingPayment;
                }
            }

            // 4. Settlement handling (for Paid/Partial Payment)
            if ((paymentStatus == 'Paid' || paymentStatus == 'Partial Payment') && refundAmount > 0) {

                if (request.settlementType == 'Refund') {
                    // Create refund line item
                    PricebookEntry refundPBE = originalProgramFeePBE;
                    if (refundPBE == null) {
                        refundPBE = pbeByName.get('Cancellation Refund');
                    }
                    if (refundPBE == null) {
                        refundPBE = pbeByName.get('ProgramFee');
                    }
                    if (refundPBE != null) {
                        OpportunityLineItem refundOLI = new OpportunityLineItem();
                        refundOLI.OpportunityId = originalOpp.Id;
                        refundOLI.PricebookEntryId = refundPBE.Id;
                        refundOLI.Quantity = 1;
                        refundOLI.UnitPrice = -refundAmount;
                        refundOLI.Description = 'Cancellation Refund';
                        insert refundOLI;
                    }

                    // Create Task for refund processing
                    if (!completedPayments.isEmpty()) {
                        Task refundTask = new Task();
                        refundTask.Subject = 'Process Refund of $' + String.valueOf(refundAmount);
                        refundTask.Description = 'Please process the refund and update this task to complete.';
                        refundTask.ActivityDate = Date.today();
                        refundTask.OwnerId = UserInfo.getUserId();
                        refundTask.Status = 'Not Started';
                        refundTask.Type = 'Other';
                        refundTask.WhatId = completedPayments[0].Id;
                        insert refundTask;

                        result.taskId = refundTask.Id;
                        result.paymentId = completedPayments[0].Id;
                    }
                    result.refundAmount = refundAmount;

                } else if (request.settlementType == 'Unapplied Funds') {
                    // Create "Move to Unapplied Funds" line item
                    PricebookEntry unappliedPBE = originalProgramFeePBE;
                    if (unappliedPBE == null) {
                        unappliedPBE = pbeByName.get('Transfer to Unapplied Funds');
                    }
                    if (unappliedPBE == null) {
                        unappliedPBE = pbeByName.get('ProgramFee');
                    }
                    if (unappliedPBE != null) {
                        OpportunityLineItem unappliedOLI = new OpportunityLineItem();
                        unappliedOLI.OpportunityId = originalOpp.Id;
                        unappliedOLI.PricebookEntryId = unappliedPBE.Id;
                        unappliedOLI.Quantity = 1;
                        unappliedOLI.UnitPrice = -refundAmount;
                        unappliedOLI.Description = 'Transfer to Unapplied Funds';
                        insert unappliedOLI;
                    }

                    // Create Unapplied Funds record
                    Unapplied_Funds__c uf = new Unapplied_Funds__c();
                    uf.Amount__c = refundAmount;
                    uf.Contact__c = attendee.evt__Contact__c;
                    uf.Originating_Opportunity__c = originalOpp.Id;
                    insert uf;

                    result.unappliedFundsId = uf.Id;
                }
                // 'Apply to Remaining Balance' - no additional action needed
            }

            // 5. Update Opportunity
            originalOpp.StageName = 'Canceled';
            originalOpp.Registration_Change_Type__c = 'Canceled';
            originalOpp.Reg_Change_Date__c = Date.today();
            originalOpp.Reg_Change_Processed_By__c = UserInfo.getUserId();
            originalOpp.Reg_Change_Comments__c = request.cancelComments;
            originalOpp.Revise_Invoice__c = true;
            applyReasonLostToOpportunity(originalOpp, request.reasonLost);
            update originalOpp;

            // 6. Update Parent Opportunity (if exists)
            if (parentOpp != null) {
                parentOpp.Revise_Invoice__c = true;
                update parentOpp;
            }

            // Build result
            result.success = true;
            result.opportunityId = originalOpp.Id;

        } catch (Exception e) {
            Database.rollback(sp);
            result.success = false;
            result.errorMessage = e.getMessage() + ' | ' + e.getStackTraceString();
        }

        return result;
    }

    private static Boolean opportunityHasReasonLostField() {
        return resolveOpportunityFieldApiName(OPP_REASON_LOST_FIELD) != null;
    }

    private static String resolveOpportunityFieldApiName(String desiredApi) {
        if (String.isBlank(desiredApi)) {
            return null;
        }
        Map<String, Schema.SObjectField> fm = Schema.SObjectType.Opportunity.fields.getMap();
        for (String k : fm.keySet()) {
            if (k != null && k.equalsIgnoreCase(desiredApi)) {
                return k;
            }
        }
        return null;
    }

    private static void applyReasonLostToOpportunity(Opportunity opp, String reasonLost) {
        if (String.isBlank(reasonLost)) {
            return;
        }
        String fldApi = resolveOpportunityFieldApiName(OPP_REASON_LOST_FIELD);
        if (fldApi == null) {
            return;
        }
        opp.put(fldApi, reasonLost.trim());
    }

    /**
     * First active picklist value for Reason Lost, or a text placeholder — used by tests when the field exists.
     */
    @TestVisible
    private static String sampleReasonLostValueForTests() {
        String fldApi = resolveOpportunityFieldApiName(OPP_REASON_LOST_FIELD);
        if (fldApi == null) {
            return null;
        }
        Schema.DescribeFieldResult dfr = Schema.SObjectType.Opportunity.fields.getMap().get(fldApi).getDescribe();
        if (dfr.getType() == Schema.DisplayType.PICKLIST) {
            for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                if (pe.isActive()) {
                    return pe.getValue();
                }
            }
        }
        return 'Test cancellation reason';
    }

    // --- SEARCH CONTACTS (for Substitution) ------------------------------

    @AuraEnabled
    public static List<ContactSearchResult> searchContacts(String searchTerm, Id accountId) {
        List<ContactSearchResult> results = new List<ContactSearchResult>();

        if (String.isBlank(searchTerm) || searchTerm.length() < 2) {
            return results;
        }

        String searchPattern = '%' + String.escapeSingleQuotes(searchTerm) + '%';

        // If accountId provided, first get contacts from that account, then others
        List<Contact> contacts = new List<Contact>();

        if (accountId != null) {
            // First: contacts from same account (prioritized)
            contacts.addAll([
                SELECT Id, Name, Email, Title, Account.Name
                FROM Contact
                WHERE (Name LIKE :searchPattern OR Email LIKE :searchPattern)
                AND AccountId = :accountId
                ORDER BY Name ASC
                LIMIT 15
            ]);

            // Then: contacts from other accounts
            Integer remaining = 25 - contacts.size();
            if (remaining > 0) {
                contacts.addAll([
                    SELECT Id, Name, Email, Title, Account.Name
                    FROM Contact
                    WHERE (Name LIKE :searchPattern OR Email LIKE :searchPattern)
                    AND AccountId != :accountId
                    ORDER BY Name ASC
                    LIMIT :remaining
                ]);
            }
        } else {
            // No account filter - just search all contacts
            contacts = [
                SELECT Id, Name, Email, Title, Account.Name
                FROM Contact
                WHERE (Name LIKE :searchPattern OR Email LIKE :searchPattern)
                ORDER BY Name ASC
                LIMIT 25
            ];
        }

        for (Contact c : contacts) {
            ContactSearchResult csr = new ContactSearchResult();
            csr.id = c.Id;
            csr.name = c.Name;
            csr.email = c.Email != null ? c.Email : '(No email)';
            csr.title = c.Title;
            csr.accountName = c.Account != null ? c.Account.Name : '';
            results.add(csr);
        }

        return results;
    }

    // --- EXECUTE SUBSTITUTION --------------------------------------------

    @AuraEnabled
    public static SubstitutionResult executeSubstitution(SubstitutionRequest request) {
        SubstitutionResult result = new SubstitutionResult();
        Savepoint sp = Database.setSavepoint();

        try {
            // ── Validate inputs ──────────────────────────────────
            if (request.attendeeId == null) {
                throw new AuraHandledException('attendeeId is null — the component may not have received the record ID.');
            }
            if (request.originalOppId == null) {
                throw new AuraHandledException('originalOppId is null — the original Opportunity ID was not provided.');
            }
            if (request.substituteContactId == null) {
                throw new AuraHandledException('substituteContactId is null — no substitute contact was selected.');
            }

            // ── QUERY 1: Attendee ──────────────────────────────────
            List<evt__Attendee__c> attendeeList = [
                SELECT Id, Name, evt__Contact__c, Account__c, Opportunity__c,
                       evt__Invitation_Status__c, evt__Event__c, Registration_Contact__c
                FROM evt__Attendee__c
                WHERE Id = :request.attendeeId
                LIMIT 1
            ];
            if (attendeeList.isEmpty()) {
                throw new AuraHandledException('Attendee not found for ID: ' + request.attendeeId);
            }
            evt__Attendee__c attendee = attendeeList[0];

            // ── QUERY 2: Original Opportunity ──────────────────────
            List<Opportunity> oppList = [
                SELECT Id, Name, AccountId, ContactId, OwnerId, Amount,
                       StageName, Pricebook2Id, RecordTypeId, CloseDate,
                       EE_Program__c, Special_Event__c, Program_Acronym__c,
                       Payment_Status__c, Has_Parent_Opportunity__c,
                       Parent_Opportunity__c, Invoice__c, Invoice_Auto_Number__c,
                       FA_Response_Id__c, Total_Paid__c,
                       pymt__Number_of_Payments_Made__c, pymt__Paid_Off__c, pymt__Payments_Made__c
                FROM Opportunity
                WHERE Id = :request.originalOppId
                LIMIT 1
            ];
            if (oppList.isEmpty()) {
                throw new AuraHandledException('Original Opportunity not found for ID: ' + request.originalOppId);
            }
            Opportunity originalOpp = oppList[0];

            // ── QUERY 3: Substitute Contact ─────────────────────────
            List<Contact> contactList = [
                SELECT Id, FirstName, LastName, Name, Email, AccountId
                FROM Contact
                WHERE Id = :request.substituteContactId
                LIMIT 1
            ];
            if (contactList.isEmpty()) {
                throw new AuraHandledException('Substitute Contact not found for ID: ' + request.substituteContactId);
            }
            Contact substituteContact = contactList[0];

            // ── QUERY 4: Original Program Fee OLIs (exclude reversal lines; consistent ordering)
            List<OpportunityLineItem> originalProgramFees = [
                SELECT Id, PricebookEntryId, Product2Id, Product2.Name,
                       UnitPrice, Quantity, TotalPrice, Description
                FROM OpportunityLineItem
                WHERE OpportunityId = :originalOpp.Id
                  AND Product_Family__c = 'Program Fee'
                  AND (Reverse_Product_Line_Item__c = false OR Reverse_Product_Line_Item__c = null)
                ORDER BY CreatedDate ASC
                LIMIT 1
            ];

            // ── QUERY 5: Original Discount OLIs ────────────────────
            // Org uses Product_Family__c = 'Discounts' (plural) per Substitution_Subflow
            List<OpportunityLineItem> originalDiscounts = [
                SELECT Id, PricebookEntryId, Product2Id, Product2.Name,
                       UnitPrice, Quantity, TotalPrice, Description
                FROM OpportunityLineItem
                WHERE OpportunityId = :originalOpp.Id
                  AND (Product_Family__c = 'Discount' OR Product_Family__c = 'Discounts')
                LIMIT 1
            ];

            // ── QUERY 6: PricebookEntries ──────────────────────────
            Map<String, PricebookEntry> pbeByName = new Map<String, PricebookEntry>();
            if (originalOpp.Pricebook2Id != null) {
                List<PricebookEntry> allPBEs = [
                    SELECT Id, Product2Id, Product2.Name, Product2.Family, UnitPrice
                    FROM PricebookEntry
                    WHERE Pricebook2Id = :originalOpp.Pricebook2Id
                      AND IsActive = true
                      AND (Product2.Name LIKE '%Substitut%' OR Product2.Family = 'Program Fee')
                ];
                for (PricebookEntry pbe : allPBEs) {
                    pbeByName.put(pbe.Product2.Name, pbe);
                    if (pbe.Product2.Family == 'Program Fee' && !pbeByName.containsKey('ProgramFee')) {
                        pbeByName.put('ProgramFee', pbe);
                    }
                }
            }

            // Substituted-Out credit must use the same product as the registration fee line when possible
            PricebookEntry substitutedOutCreditPBE = null;
            if (!originalProgramFees.isEmpty() && originalProgramFees[0].PricebookEntryId != null) {
                List<PricebookEntry> subFeePbeVerify = [
                    SELECT Id
                    FROM PricebookEntry
                    WHERE Id = :originalProgramFees[0].PricebookEntryId
                      AND IsActive = true
                    LIMIT 1
                ];
                if (!subFeePbeVerify.isEmpty()) {
                    substitutedOutCreditPBE = subFeePbeVerify[0];
                }
            }
            if (substitutedOutCreditPBE == null) {
                substitutedOutCreditPBE = pbeByName.get('ProgramFee');
            }

            if (opportunityHasReasonLostField() && String.isBlank(request.reasonLost)) {
                throw new AuraHandledException('Reason Lost is required to substitute this registration.');
            }

            // ════════════════════════════════════════════════════════
            // DML PHASE
            // ════════════════════════════════════════════════════════

            Decimal oppAmount = originalOpp.Amount != null ? originalOpp.Amount : 0;

            // 1. Update original Attendee
            attendee.evt__Invitation_Status__c = 'Substitution';
            attendee.Substituted_Participant__c = request.substituteContactId;
            update attendee;

            // 2. Create new Opportunity for substitute
            Opportunity newOpp = new Opportunity();
            newOpp.AccountId = originalOpp.AccountId;
            newOpp.OwnerId = originalOpp.OwnerId;
            newOpp.RecordTypeId = originalOpp.RecordTypeId;
            newOpp.Pricebook2Id = originalOpp.Pricebook2Id;
            newOpp.CloseDate = originalOpp.CloseDate;
            newOpp.StageName = originalOpp.StageName;
            newOpp.EE_Program__c = originalOpp.EE_Program__c;
            newOpp.Special_Event__c = originalOpp.Special_Event__c;
            newOpp.Parent_Opportunity__c = originalOpp.Parent_Opportunity__c;
            newOpp.Invoice__c = originalOpp.Invoice__c;
            newOpp.Invoice_Auto_Number__c = originalOpp.Invoice_Auto_Number__c;
            newOpp.FA_Response_Id__c = originalOpp.FA_Response_Id__c;
            newOpp.Payment_Status__c = originalOpp.Payment_Status__c;
            newOpp.Total_Paid__c = originalOpp.Total_Paid__c;
            newOpp.pymt__Number_of_Payments_Made__c = originalOpp.pymt__Number_of_Payments_Made__c;
            newOpp.pymt__Paid_Off__c = originalOpp.pymt__Paid_Off__c;
            newOpp.pymt__Payments_Made__c = originalOpp.pymt__Payments_Made__c;

            newOpp.Primary_Contact__c = request.substituteContactId;
            newOpp.ContactId = request.substituteContactId;
            newOpp.Registration_Change_Type__c = 'Substituted In';
            newOpp.Reg_Change_Date__c = Date.today();
            newOpp.Reg_Change_Processed_By__c = UserInfo.getUserId();
            newOpp.Reg_Change_Comments__c = request.substitutionComments;
            newOpp.Reg_Change_Original_Opportunity__c = originalOpp.Id;

            String oppName = '';
            if (originalOpp.Program_Acronym__c != null) {
                oppName = originalOpp.Program_Acronym__c + ' Registration - ';
            }
            oppName += substituteContact.FirstName != null ? substituteContact.FirstName + ' ' : '';
            oppName += substituteContact.LastName != null ? substituteContact.LastName : '';
            newOpp.Name = oppName.trim();

            insert newOpp;

            result.newOpportunityId = newOpp.Id;
            result.newOpportunityName = newOpp.Name;

            // 3. Create OpportunityContactRole
            OpportunityContactRole ocr = new OpportunityContactRole();
            ocr.OpportunityId = newOpp.Id;
            ocr.ContactId = request.substituteContactId;
            ocr.Role = 'Participant';
            ocr.IsPrimary = true;
            insert ocr;

            // 4. Update original Opportunity
            originalOpp.StageName = 'Closed Lost';
            originalOpp.Substituted_Participant__c = request.substituteContactId;
            originalOpp.Reg_Change_Date__c = Date.today();
            originalOpp.Reg_Change_Processed_By__c = UserInfo.getUserId();
            originalOpp.Reg_Change_New_Opportunity__c = newOpp.Id;
            originalOpp.Registration_Change_Type__c = 'Substituted Out';
            originalOpp.Reg_Change_Comments__c = request.substitutionComments;
            applyReasonLostToOpportunity(originalOpp, request.reasonLost);
            update originalOpp;

            // 5. Create Line Items
            List<OpportunityLineItem> olisToInsert = new List<OpportunityLineItem>();

            // 5a. "Substituted Out" credit line item on original Opp (PBE from original program fee line when available)
            if (oppAmount > 0) {
                if (substitutedOutCreditPBE != null) {
                    OpportunityLineItem creditOLI = new OpportunityLineItem();
                    creditOLI.OpportunityId = originalOpp.Id;
                    creditOLI.PricebookEntryId = substitutedOutCreditPBE.Id;
                    creditOLI.Quantity = 1;
                    creditOLI.UnitPrice = -oppAmount;
                    creditOLI.Description = 'Substituted Out';
                    olisToInsert.add(creditOLI);
                }
            }

            // 5b. Program Fee on new Opp (copy from original)
            if (!originalProgramFees.isEmpty()) {
                OpportunityLineItem origFee = originalProgramFees[0];
                OpportunityLineItem newFeeOLI = new OpportunityLineItem();
                newFeeOLI.OpportunityId = newOpp.Id;
                newFeeOLI.PricebookEntryId = origFee.PricebookEntryId;
                newFeeOLI.Quantity = 1;
                newFeeOLI.UnitPrice = origFee.UnitPrice;
                newFeeOLI.Description = origFee.Description;
                olisToInsert.add(newFeeOLI);
            }

            // 5c. Discount on new Opp (if applicable)
            if (request.applyDiscount && !originalDiscounts.isEmpty()) {
                OpportunityLineItem origDiscount = originalDiscounts[0];
                OpportunityLineItem newDiscountOLI = new OpportunityLineItem();
                newDiscountOLI.OpportunityId = newOpp.Id;
                newDiscountOLI.PricebookEntryId = origDiscount.PricebookEntryId;
                newDiscountOLI.Quantity = 1;
                newDiscountOLI.UnitPrice = origDiscount.UnitPrice;
                newDiscountOLI.Description = origDiscount.Description;
                olisToInsert.add(newDiscountOLI);
            }

            if (!olisToInsert.isEmpty()) {
                insert olisToInsert;
            }

            // 6. Create new Attendee for substitute
            evt__Attendee__c newAttendee = new evt__Attendee__c();
            newAttendee.Opportunity__c = newOpp.Id;
            newAttendee.Registration_Contact__c = attendee.Registration_Contact__c;
            newAttendee.Registration_Path__c = 'Substituted In';
            newAttendee.evt__Category__c = 'Attendee';
            newAttendee.evt__Contact__c = request.substituteContactId;
            newAttendee.evt__Event__c = attendee.evt__Event__c;
            newAttendee.evt__Invitation_Status__c = 'Registered';
            newAttendee.Account__c = substituteContact.AccountId != null ? substituteContact.AccountId : originalOpp.AccountId;
            insert newAttendee;

            result.newAttendeeId = newAttendee.Id;

            // Link Attendee to Opportunity
            newOpp.Attendee__c = newAttendee.Id;
            update newOpp;

            // 7. Payment handling - for standalone registrations
            if (originalOpp.Has_Parent_Opportunity__c != 'Yes') {
                // Move completed payments to new Opp
                List<pymt__PaymentX__c> completedPayments = [
                    SELECT Id, pymt__Opportunity__c
                    FROM pymt__PaymentX__c
                    WHERE pymt__Opportunity__c = :originalOpp.Id
                      AND pymt__Status__c = 'Completed'
                ];
                for (pymt__PaymentX__c pmt : completedPayments) {
                    pmt.pymt__Opportunity__c = newOpp.Id;
                }
                if (!completedPayments.isEmpty()) {
                    update completedPayments;
                }

                // Update Invoice to point to new Opp
                if (originalOpp.Invoice__c != null) {
                    List<Invoice__c> invoices = [
                        SELECT Id, Opportunity__c
                        FROM Invoice__c
                        WHERE Opportunity__c = :originalOpp.Id
                        LIMIT 1
                    ];
                    if (!invoices.isEmpty()) {
                        invoices[0].Opportunity__c = newOpp.Id;
                        update invoices;
                    }

                    // Set flags to generate new invoice
                    newOpp.Invoice_Created__c = Date.today();
                    newOpp.Set_Create_Invoice__c = true;
                    update newOpp;
                }
            } else {
                // Bundled registration - set Revise_Invoice on parent
                if (originalOpp.Parent_Opportunity__c != null) {
                    Opportunity parentOpp = new Opportunity(Id = originalOpp.Parent_Opportunity__c);
                    parentOpp.Revise_Invoice__c = true;
                    update parentOpp;
                }
            }

            // Build result
            result.success = true;

        } catch (Exception e) {
            Database.rollback(sp);
            result.success = false;
            result.errorMessage = e.getMessage() + ' | ' + e.getStackTraceString();
        }

        return result;
    }
}
