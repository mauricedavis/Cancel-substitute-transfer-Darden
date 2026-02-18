# Transfer Registration LWC

**Ticket:** EELL-216
**Replaces:** Transfer_Subflow (Screen Flow, v15)

## Overview

Lightning Web Component that handles transferring a registrant (Attendee) from one
Executive Education program (Special Event) to another, including:

- Credit line item creation (itemized, per Finance requirements)
- Transfer fee application
- Opportunity stage updates (Transferred Out / Transferred In)
- Payment record moves and updates (`pymt__PaymentX__c`)
- Settlement handling (Unapplied Funds or Refund)
- Invoice reassignment
- New Attendee and Registration Opportunity creation

## Project Structure

```
force-app/main/default/
  classes/
    TransferRegistrationController.cls          # Apex controller (3 @AuraEnabled methods)
    TransferRegistrationController.cls-meta.xml
    TransferRegistrationControllerTest.cls      # Test class (5 scenarios)
    TransferRegistrationControllerTest.cls-meta.xml
  lwc/
    transferRegistration/
      transferRegistration.js                   # LWC JavaScript (placeholder - Part 3)
      transferRegistration.html                 # LWC Template (placeholder - Part 3)
      transferRegistration.css                  # LWC Styles (placeholder - Part 3)
      transferRegistration.js-meta.xml          # LWC metadata config
```

## Deployment

```bash
# Authenticate to FULLSB sandbox
sf org login web --alias darden-fullsb --instance-url https://test.salesforce.com

# Deploy Apex classes first
sf project deploy start --source-dir force-app/main/default/classes --target-org darden-fullsb

# Run tests
sf apex run test --class-names TransferRegistrationControllerTest --target-org darden-fullsb --wait 10

# Deploy everything (after LWC is complete)
sf project deploy start --source-dir force-app --target-org darden-fullsb
```

## Key Data Model References

| Object | API Name | Purpose |
|--------|----------|---------|
| Attendee | `evt__Attendee__c` | Registration / attendee record |
| Special Event | `evt__Special_Event__c` | Program (transfer source & destination) |
| Opportunity | `Opportunity` | Registration opportunity |
| Payment | `pymt__PaymentX__c` | LinvioPay payment records |
| Unapplied Funds | `Unapplied_Funds__c` | Credit/settlement tracking |

## Authors

- Maury Davis (MJD) — Attain Partners
