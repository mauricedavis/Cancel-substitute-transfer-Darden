# Opportunity Tracker flow – avoiding transfer errors

If testers still see **"Opportunity Tracker" process failed** when running a transfer (e.g. "5. Update Opportunity"), do the following.

## 1. Confirm the latest Apex is deployed

Ensure the **TransferRegistrationController** in the org is the version that:

- Updates the original Opportunity to **StageName = Transferred Out** and **Registration_Change_Type__c = Transferred Out** *before* inserting the credit and transfer-fee line items.

That order prevents the flow from treating the opp as "Registered + Paid + no change type" when Amount changes.

## 2. Add a safeguard in the Opportunity Tracker flow

So the flow never runs its “Paid registration” action on transferred/canceled or negative-amount opps:

1. In **Setup → Flows**, open **Opportunity_Tracker** (record-triggered, Opportunity).
2. Find the decision/rule that leads to the **FlowActionCall** that fails (e.g. the path where **StageName = Registered**, **Payment_Status_2__c = Paid**, **Registration_Change_Type__c = null** — often labeled like **myRule_31**).
3. Add **one or more** of these so that path does **not** run when:
   - **Registration_Change_Type__c** is not null, **or**
   - **StageName** is **Transferred Out**, **Canceled**, or **Closed Lost**, **or**
   - **Amount** is less than or equal to **0**.

That way the flow will not execute the failing action on transfer-out or similar records, even if something else triggers the flow.

## 3. Check the failing interview

Use the **Error ID** from the failure email and **Setup → Flow → Flow Interview Logs** (or debug logs) to see which element failed. The fix above targets the “Paid + Registered + null change type” path that runs the FlowActionCall; if the failure is on a different path, add similar safeguards to that path (e.g. exclude Transferred Out / non-null **Registration_Change_Type__c** / non-positive Amount as appropriate).
