# Transfer Registration LWC - Project Summary

## Overview
This Lightning Web Component (LWC) consolidates three Salesforce Flow processes into a single, unified interface for managing registration changes on Attendee records.

## Replaced Flows
| Original Flow | Functionality |
|--------------|---------------|
| `Cancellations_Subflow` | Cancel registrations with fee handling, refunds, and unapplied funds |
| `Substitution_Subflow` | Replace registrant with different contact for same program |
| `Transfer_Subflow` | Transfer registrant to a different program |

## Components Developed

### Apex Controller
**File:** `force-app/main/default/classes/TransferRegistrationController.cls`

| Method | Purpose |
|--------|---------|
| `getInitData(Id attendeeId)` | Initialize component with Attendee, Opportunity, and Contact data |
| `getProgramDetails(String programCode)` | Retrieve available programs for transfer |
| `executeTransfer(TransferRequest request)` | Process transfer to new program |
| `executeCancellation(CancellationRequest request)` | Process cancellation with fee/settlement handling |
| `searchContacts(String searchTerm, Id accountId)` | Search contacts for substitution |
| `executeSubstitution(SubstitutionRequest request)` | Process contact substitution |

### Lightning Web Component
**Files:**
- `force-app/main/default/lwc/transferRegistration/transferRegistration.js`
- `force-app/main/default/lwc/transferRegistration/transferRegistration.html`
- `force-app/main/default/lwc/transferRegistration/transferRegistration.css`
- `force-app/main/default/lwc/transferRegistration/transferRegistration.js-meta.xml`

### Key Features
- **Multi-step wizard interface** with progress indicator
- **Dynamic path routing** based on selected change type
- **Real-time contact search** with account prioritization
- **Comprehensive validation** and error handling
- **Responsive UI** optimized for modal display

## Business Logic Implementation

### Cancellation Flow
1. Select cancellation fee option (Yes/No with amount)
2. Settlement selection for paid registrations:
   - Refund
   - Unapplied Funds
   - Apply to Remaining Balance
3. Creates appropriate OLIs (Cancellation Fee, Credit, Refund)
4. Updates Attendee status to 'Cancelled'
5. Updates Opportunity stage to 'Canceled'
6. Handles bundled registrations (flags parent for invoice revision)

### Transfer Flow
1. Search and select target program
2. Calculate price difference
3. Create new Opportunity and Attendee for target program
4. Update original records (Transferred Out status)
5. Handle payment transfers and discounts

### Substitution Flow
1. Search and select substitute contact
2. Option to apply original discount
3. Create new Opportunity and Attendee for substitute
4. Create OpportunityContactRole
5. Update original Attendee to 'Substitution' status
6. Handle payment redirection or invoice revision

## Data Model References

### Primary Objects
- `evt__Attendee__c` - Registration record
- `Opportunity` - Financial record for registration
- `OpportunityLineItem` - Fee, credit, and discount line items
- `Contact` - Registrant information

### Supporting Objects
- `evt__Special_Event__c` - Program/Event details
- `pymt__PaymentX__c` - Payment records
- `Unapplied_Funds__c` - Credit balance records
- `Invoice__c` - Invoice records
- `Task` - Follow-up tasks

## Deployment

### Prerequisites
- Salesforce CLI installed
- Authenticated to target org

### Deploy Command
```bash
sf project deploy start --source-dir force-app --target-org <org-alias>
```

## Testing
See `test-plan/Transfer_Registration_Test_Plan.csv` for comprehensive test cases covering:
- 10 Cancellation scenarios
- 10 Transfer scenarios
- 11 Substitution scenarios
- 5 General functionality tests

## Technical Notes

### LWC Template Limitations
The following patterns are NOT supported in LWC templates and required computed properties:
- Direct comparison operators in `lwc:if` (e.g., `value === 'test'`)
- Unary operators (e.g., `!booleanValue`)
- Ternary operators (e.g., `condition ? 'A' : 'B'`)

### Shadow DOM Considerations
`lightning-textarea` and similar components have shadow DOM encapsulation. Custom labels with `variant="label-hidden"` were used to ensure proper styling on dark backgrounds.

## Files Structure
```
transfer-registration-lwc/
├── force-app/main/default/
│   ├── classes/
│   │   ├── TransferRegistrationController.cls
│   │   └── TransferRegistrationController.cls-meta.xml
│   └── lwc/transferRegistration/
│       ├── transferRegistration.js
│       ├── transferRegistration.html
│       ├── transferRegistration.css
│       └── transferRegistration.js-meta.xml
├── test-plan/
│   └── Transfer_Registration_Test_Plan.csv
├── docs/
│   └── PROJECT_SUMMARY.md
└── README.md
```

## Version History
| Date | Description |
|------|-------------|
| 2026-02-17 | Initial implementation of Transfer functionality |
| 2026-02-17 | Added Cancellation flow with settlement options |
| 2026-02-17 | Added Substitution flow with contact search |
| 2026-02-17 | UI refinements and bug fixes |
| 2026-02-18 | Contact search fix and UI styling updates |
