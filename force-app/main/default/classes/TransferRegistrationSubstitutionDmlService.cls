/**
 * DML in without-sharing context for the substitution "close out" path.
 *
 * Users with access to the Transfer Registration LWC and substitution action may
 * still lack OWD/row sharing **Edit** on the original program Opportunity or
 * on line items for that opportunity (read-only or team sharing) while the flow
 * should still complete. This class performs that DML outside the controller's
 * with-sharing rules.
 *
 * Other updates in the same flow (linked Invoice, parent bundled Opportunity)
 * stay in the controller: if they fail with the same error, they can be moved
 * here under the same security review.
 *
 * Field-level access: the controller (assertOpportunityFieldsUpdateableForSubstitutedOut)
 * surfaces clear errors when key Opportunity fields are not updateable. Admin
 * runbook: grant Edit on Opportunity and Edit FLS for Stage, Substituted_Participant,
 * Reg_Change* , and Reason_Lost (if used) to substitution user profiles/permission sets.
 */
public without sharing class TransferRegistrationSubstitutionDmlService {

    public static void updateOriginalOpportunitySubstitutedOut(Opportunity o) {
        if (o == null || o.Id == null) {
            throw new AuraHandledException(
                'Internal error: no Opportunity to update for substitution close-out.'
            );
        }
        update o;
    }

    public static void insertLineItemsForSubstitution(List<OpportunityLineItem> olis) {
        if (olis == null || olis.isEmpty()) {
            return;
        }
        insert olis;
    }
}
