# Registration Change Management LWC

**Ticket:** EELL-216  
**Replaces:** Cancellations_Subflow, Substitution_Subflow, Transfer_Subflow

## Overview

Lightning Web Component that consolidates three Salesforce Flow processes into a unified interface for managing registration changes on Attendee records. Launched as a Quick Action from the Attendee record page.

### Supported Change Types

| Change Type | Description |
|-------------|-------------|
| **Cancellation** | Cancel registration with fee handling, settlement options (Refund, Unapplied Funds, Apply to Balance) |
| **Substitution** | Replace registrant with a different contact for the same program |
| **Transfer** | Move registrant to a different program with fee/discount handling |

## Features

### Cancellation Flow
- Cancellation fee option (Yes/No with custom amount)
- Settlement type selection for paid registrations
- Automatic OLI creation (Cancellation Fee, Credit, Refund)
- Credit amount and review UI use **net registration** (`Opportunity.Amount`), not raw program-fee subtotal, so discounts are reflected
- Credit / refund / unapplied lines prefer the **original program fee line’s** `PricebookEntry` so the product name matches the registration (not a generic Program Fee from the pricebook)
- Bundled registration support (parent invoice revision)
- Task creation for refund processing

### Transfer Flow
- Program search and selection with auto-populated fees
- Transfer fee application (customizable amount)
- Discount copying with automatic recalculation
- Invoice record updates
- Payment record transfer to new Opportunity
- Naming convention: `{ProgramAcronym} Registration - {FirstName} {LastName}`

### Substitution Flow
- Contact search (by name or email) with account prioritization
- Original discount application option
- New Opportunity and Attendee creation
- **Substituted Out** credit on the original opportunity uses the **same program fee** `PricebookEntry` as the registration line (avoids wrong product labels such as another Program Fee in the same pricebook)
- OpportunityContactRole creation
- Payment redirection or invoice revision

## Project Structure

```
force-app/main/default/
  classes/
    TransferRegistrationController.cls          # Apex controller (6 @AuraEnabled methods)
    TransferRegistrationController.cls-meta.xml
    TransferRegistrationControllerTest.cls      # Test class
    TransferRegistrationControllerTest.cls-meta.xml
  lwc/
    transferRegistration/
      transferRegistration.js                   # LWC JavaScript (~900 lines)
      transferRegistration.html                 # LWC Template (~1000 lines)
      transferRegistration.css                  # LWC Styles
      transferRegistration.js-meta.xml          # LWC metadata config

test-plan/
  Transfer_Registration_Test_Plan.csv           # 36 test cases

docs/
  PROJECT_SUMMARY.md                            # Detailed project documentation
```

## Deployment

```bash
# Authenticate to FULLSB sandbox
sf org login web --alias darden-fullsb --instance-url https://test.salesforce.com

# Deploy everything
sf project deploy start --source-dir force-app --target-org darden-fullsb --wait 10

# Production (example): validate with specified tests
sf project deploy start --target-org darden-prod \
  --source-dir force-app/main/default/classes/TransferRegistrationController.cls \
  --source-dir force-app/main/default/classes/TransferRegistrationControllerTest.cls \
  --source-dir force-app/main/default/lwc/transferRegistration \
  --test-level RunSpecifiedTests --tests TransferRegistrationControllerTest --wait 90
```

### darden-fullsb: automated tests vs org automation

Heavy flows on `evt__Attendee__c` (e.g. SLX Attendee Sync, Contact UTM updates, DLRS) can push **SOQL over the 101 limit** when tests call `insert` on Attendee. In that environment, **not all** `TransferRegistrationControllerTest` methods may pass in a single run, even though the same tests are used for **production** validation where limits differ.

**What was verified (CLI, darden-fullsb, synchronous run):** tests that do **not** insert an Attendee (e.g. discount-by-code, program details, contact search, transfer error handling) **passed**. Tests that call `insertAttendee` failed with `LIMIT_EXCEEDED` / flow trigger errors in that org snapshot.

**What to rely on for sign-off:** manual UAT on cancellation and substitution (credit / Substituted Out product and amounts) in fullsb after deploy, and **`RunSpecifiedTests` on `TransferRegistrationControllerTest` when deploying to production** (see history below).

## Key Data Model References

| Object | API Name | Purpose |
|--------|----------|---------|
| Attendee | `evt__Attendee__c` | Registration / attendee record |
| Special Event | `evt__Special_Event__c` | Program (source & destination) |
| Opportunity | `Opportunity` | Registration opportunity |
| OpportunityLineItem | `OpportunityLineItem` | Fees, credits, discounts |
| Payment | `pymt__PaymentX__c` | LinvioPay payment records |
| Unapplied Funds | `Unapplied_Funds__c` | Credit/settlement tracking |
| Invoice | `Invoice__c` | Invoice records |
| Contact | `Contact` | Registrant/substitute contact |

## Apex Controller Methods

| Method | Purpose |
|--------|---------|
| `getInitData(Id attendeeId)` | Initialize component with Attendee, Opportunity, and program data |
| `getProgramDetails(Id specialEventId, Id pricebook2Id)` | Get program fee details for transfer |
| `executeTransfer(TransferRequest request)` | Process transfer to new program |
| `executeCancellation(CancellationRequest request)` | Process cancellation with settlement |
| `searchContacts(String searchTerm, Id accountId)` | Search contacts for substitution |
| `executeSubstitution(SubstitutionRequest request)` | Process contact substitution |

## Version History

| Date | Version | Description |
|------|---------|-------------|
| 2026-02-17 | 1.0 | Initial implementation of all three change types |
| 2026-02-19 | 1.1 | Bug fixes: Program fee auto-populate, discount copying, invoice handling, naming convention |
| 2026-03-26 | 1.2 | Cancellation: LWC review shows credit from `Opportunity.Amount`; Apex credit/refund/unapplied use original program fee `PricebookEntry` when present; tests adjusted for prod coverage and org rollups |
| 2026-04-02 | 1.3 | Substitution: **Substituted Out** credit uses original program fee line’s `PricebookEntry` (same pattern as cancellation); fullsb deploy validated with `NoTestRun` where deploy-time tests hit sandbox SOQL limits |

## Authors

- Maury Davis (MJD) — Attain Partners
