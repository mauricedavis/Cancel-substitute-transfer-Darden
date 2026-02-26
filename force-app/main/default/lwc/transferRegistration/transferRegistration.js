/**
 * @description  Transfer Registration LWC - Quick Action on evt__Attendee__c
 *               Replaces the Registration Change Request parent flow + subflows.
 *               Step 0: Change Type (Cancellation / Substitution / Transfer)
 *               Transfer path: Select Program → Transfer Details → Review → Complete
 *               Cancellation/Substitution: Stubbed for future phases.
 *
 * @author       Maury Davis (MJD) - Attain Partners
 * @date         2026-02-15
 * @ticket       EELL-216
 */
import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';

import getInitData from '@salesforce/apex/TransferRegistrationController.getInitData';
import getProgramDetails from '@salesforce/apex/TransferRegistrationController.getProgramDetails';
import executeTransfer from '@salesforce/apex/TransferRegistrationController.executeTransfer';
import executeCancellation from '@salesforce/apex/TransferRegistrationController.executeCancellation';
import searchContacts from '@salesforce/apex/TransferRegistrationController.searchContacts';
import executeSubstitution from '@salesforce/apex/TransferRegistrationController.executeSubstitution';

const PROGRAM_COLUMNS = [
    { label: 'Program Name', fieldName: 'Name', type: 'text', sortable: true, wrapText: true, initialWidth: 250 },
    { label: 'Code', fieldName: 'Program_Code__c', type: 'text', sortable: true, initialWidth: 120 },
    { label: 'Acronym', fieldName: 'Program_Acronym__c', type: 'text', sortable: true, initialWidth: 90 },
    { label: 'Start Date', fieldName: 'evt__Start__c', type: 'date', sortable: true, initialWidth: 110,
        typeAttributes: { month: 'short', day: '2-digit', year: 'numeric' }
    },
    { label: 'End Date', fieldName: 'evt__End__c', type: 'date', sortable: true, initialWidth: 110,
        typeAttributes: { month: 'short', day: '2-digit', year: 'numeric' }
    },
    { label: 'Expected Fee', fieldName: 'Expected_Program_Fee__c', type: 'currency', sortable: true, initialWidth: 120,
        typeAttributes: { currencyCode: 'USD' }
    }
];

const SETTLEMENT_OPTIONS = [
    { label: '-- None --', value: '' },
    { label: 'Refund', value: 'Refund' },
    { label: 'Unapplied Funds', value: 'Unapplied Funds' }
];

const CANCEL_SETTLEMENT_OPTIONS_PAID = [
    { label: 'Refund', value: 'Refund' },
    { label: 'Unapplied Funds', value: 'Unapplied Funds' }
];

const CANCEL_SETTLEMENT_OPTIONS_BUNDLE = [
    { label: 'Apply to Remaining Balance', value: 'Apply to Remaining Balance' },
    { label: 'Refund', value: 'Refund' },
    { label: 'Unapplied Funds', value: 'Unapplied Funds' }
];

const CURRENCY_FORMATTER = new Intl.NumberFormat('en-US', {
    style: 'currency', currency: 'USD'
});

export default class TransferRegistration extends NavigationMixin(LightningElement) {
    @api recordId; // Attendee Id from Quick Action

    // ═══════════════ STATE ═══════════════
    @track currentStep = '0';
    @track changeType = '';       // 'Cancellation', 'Substitution', 'Transfer'
    @track isLoading = true;
    @track isProcessing = false;
    @track hasError = false;
    @track errorMessage = '';

    // Data from init
    @track initData = {};
    @track availablePrograms = [];

    // Step 1 - Program Selection (Transfer path)
    @track programSearchTerm = '';
    @track filteredPrograms = [];
    @track selectedProgram = null;
    @track selectedProgramRows = [];
    @track programDetails = null;

    // Step 2 - Transfer Details
    @track newProgramFeeAmount = 0;
    @track applyTransferFee = true;
    @track transferFeeAmount = 0;
    @track settlementType = '';
    @track applyDiscount = false;
    @track discountAmount = 0;
    @track discountCode = '';
    @track regChangeComments = '';

    // Step 4 - Results
    @track transferResult = {};

    // ═══════════════ CANCELLATION STATE ═══════════════
    @track applyCancellationFee = false;
    @track cancellationFeeAmount = 0;
    @track cancelSettlementType = '';
    @track cancelComments = '';
    @track cancellationResult = {};

    // ═══════════════ SUBSTITUTION STATE ═══════════════
    @track contactSearchTerm = '';
    @track contactSearchResults = [];
    @track selectedContact = null;
    @track applySubstitutionDiscount = true;
    @track substitutionComments = '';
    @track substitutionResult = {};
    @track isSearchingContacts = false;

    programColumns = PROGRAM_COLUMNS;
    settlementOptions = SETTLEMENT_OPTIONS;

    // ═══════════════ LIFECYCLE ═══════════════

    connectedCallback() {
        this.loadInitData();
    }

    async loadInitData() {
        this.isLoading = true;
        this.hasError = false;
        try {
            this.initData = await getInitData({ attendeeId: this.recordId });
            this.availablePrograms = this.initData.availablePrograms || [];
        } catch (error) {
            this.hasError = true;
            this.errorMessage = this.extractErrorMessage(error);
        } finally {
            this.isLoading = false;
        }
    }

    // ═══════════════ CHANGE TYPE (STEP 0) ═══════════════

    get isStep0() { return this.currentStep === '0'; }

    get isCancellationSelected() { return this.changeType === 'Cancellation'; }
    get isSubstitutionSelected() { return this.changeType === 'Substitution'; }
    get isTransferSelected() { return this.changeType === 'Transfer'; }

    get isTransferPath() { return this.changeType === 'Transfer'; }
    get isCancellationPath() { return this.changeType === 'Cancellation'; }
    get isSubstitutionPath() { return this.changeType === 'Substitution'; }

    handleChangeTypeSelect(event) {
        this.changeType = event.target.value;
    }

    handleCancellationClick() {
        this.changeType = 'Cancellation';
    }

    handleSubstitutionClick() {
        this.changeType = 'Substitution';
    }

    handleTransferClick() {
        this.changeType = 'Transfer';
    }

    // ═══════════════ STEP COMPUTED PROPERTIES ═══════════════

    get isTransferStep1() { return this.isTransferPath && this.currentStep === '1'; }
    get isTransferStep2() { return this.isTransferPath && this.currentStep === '2'; }
    get isTransferStep3() { return this.isTransferPath && this.currentStep === '3'; }
    get isTransferStep4() { return this.isTransferPath && this.currentStep === '4'; }

    get isCancellationStep1() { return this.isCancellationPath && this.currentStep === '1'; }
    get isCancellationStep2() { return this.isCancellationPath && this.currentStep === '2'; }
    get isCancellationStep3() { return this.isCancellationPath && this.currentStep === '3'; }
    get isCancellationStep4() { return this.isCancellationPath && this.currentStep === '4'; }

    get isSubstitutionStep1() { return this.isSubstitutionPath && this.currentStep === '1'; }
    get isSubstitutionStep2() { return this.isSubstitutionPath && this.currentStep === '2'; }
    get isSubstitutionStep3() { return this.isSubstitutionPath && this.currentStep === '3'; }

    get isStubStep() {
        return false;
    }

    get requiresSettlementScreen() {
        const status = this.paymentStatus;
        return status === 'Paid' || status === 'Partial Payment';
    }

    get isBundledRegistration() {
        return this.initData?.originalOpp?.Has_Parent_Opportunity__c === 'Yes';
    }

    get isReady() {
        return !this.isLoading && !this.hasError;
    }

    get showFooter() {
        return !this.isLoading && !this.hasError && !this.isTransferStep4 && !this.isCancellationStep4 && !this.isSubstitutionStep3;
    }

    get showBackButton() {
        return this.currentStep !== '0';
    }

    get showWarningBanner() {
        if (this.isTransferPath) {
            return this.currentStep === '1' || this.currentStep === '2' || this.currentStep === '3';
        }
        if (this.isCancellationPath) {
            return this.currentStep === '1' || this.currentStep === '2' || this.currentStep === '3';
        }
        if (this.isSubstitutionPath) {
            return this.currentStep === '1' || this.currentStep === '2';
        }
        return false;
    }

    get disableNext() {
        if (this.isStep0) {
            return !this.changeType;
        }
        if (this.isTransferStep1) {
            return !this.selectedProgram;
        }
        if (this.isCancellationStep1) {
            return this.applyCancellationFee && (!this.cancellationFeeAmount || Number(this.cancellationFeeAmount) <= 0);
        }
        if (this.isCancellationStep2) {
            return !this.cancelSettlementType;
        }
        if (this.isSubstitutionStep1) {
            return !this.selectedContact;
        }
        return false;
    }

    get executeButtonLabel() {
        if (this.isCancellationPath) {
            return this.isProcessing ? 'Processing...' : 'Execute Cancellation';
        }
        if (this.isSubstitutionPath) {
            return this.isProcessing ? 'Processing...' : 'Execute Substitution';
        }
        return this.isProcessing ? 'Processing...' : 'Execute Transfer';
    }

    get showExecuteButton() {
        return this.isTransferStep3 || this.isCancellationStep3 || this.isSubstitutionStep2;
    }

    // ═══════════════ CANCELLATION DISPLAY PROPERTIES ═══════════════

    get cancelSettlementOptions() {
        if (this.isBundledRegistration && this.paymentStatus === 'Partial Payment') {
            return CANCEL_SETTLEMENT_OPTIONS_BUNDLE;
        }
        return CANCEL_SETTLEMENT_OPTIONS_PAID;
    }

    get formattedCancellationFee() {
        return CURRENCY_FORMATTER.format(this.cancellationFeeAmount || 0);
    }

    get cancellationRefundAmount() {
        const oppAmount = this.initData?.originalOpp?.Amount || 0;
        const fee = this.applyCancellationFee ? (Number(this.cancellationFeeAmount) || 0) : 0;
        return oppAmount - fee;
    }

    get formattedCancellationRefund() {
        return CURRENCY_FORMATTER.format(this.cancellationRefundAmount);
    }

    get cancelSettlementDescription() {
        if (this.cancelSettlementType === 'Refund') {
            return 'A Task will be created to process the refund for ' + this.formattedCancellationRefund + '.';
        }
        if (this.cancelSettlementType === 'Unapplied Funds') {
            return 'An Unapplied Funds record will be created for ' + this.formattedCancellationRefund + '.';
        }
        if (this.cancelSettlementType === 'Apply to Remaining Balance') {
            return 'The amount will be applied to the remaining balance on the bundled registration.';
        }
        return '';
    }

    get cancellationOppUrl() {
        return `/lightning/r/Opportunity/${this.cancellationResult?.opportunityId}/view`;
    }

    get cancellationPaymentUrl() {
        return `/lightning/r/pymt__PaymentX__c/${this.cancellationResult?.paymentId}/view`;
    }

    get cancellationUnappliedFundsUrl() {
        return `/lightning/r/Unapplied_Funds__c/${this.cancellationResult?.unappliedFundsId}/view`;
    }

    get showRefundInfo() {
        return this.cancellationResult?.refundAmount && this.cancellationResult?.paymentId;
    }

    get showUnappliedFundsInfo() {
        return this.cancellationResult?.unappliedFundsId;
    }

    get isSettlementRefund() {
        return this.cancelSettlementType === 'Refund';
    }

    get isSettlementUnappliedFunds() {
        return this.cancelSettlementType === 'Unapplied Funds';
    }

    get isSettlementApplyToBalance() {
        return this.cancelSettlementType === 'Apply to Remaining Balance';
    }

    get notApplyCancellationFee() {
        return !this.applyCancellationFee;
    }

    // ═══════════════ SUBSTITUTION DISPLAY PROPERTIES ═══════════════

    get hasContactSearchResults() {
        return this.contactSearchResults && this.contactSearchResults.length > 0;
    }

    get hasOriginalDiscount() {
        return this.initData?.discountTotal && this.initData.discountTotal !== 0;
    }

    get substitutionNewOppUrl() {
        return `/lightning/r/Opportunity/${this.substitutionResult?.newOpportunityId}/view`;
    }

    get substitutionNewAttendeeUrl() {
        return `/lightning/r/evt__Attendee__c/${this.substitutionResult?.newAttendeeId}/view`;
    }

    get notApplySubstitutionDiscount() {
        return !this.applySubstitutionDiscount;
    }

    get discountAppliedLabel() {
        return this.applySubstitutionDiscount ? '(Applied)' : '(Not Applied)';
    }

    // ═══════════════ DISPLAY PROPERTIES ═══════════════

    get attendeeName() {
        const att = this.initData?.attendee;
        if (!att) return '';
        return `${att.evt__First_Name__c || ''} ${att.evt__Last_Name__c || ''}`.trim() || att.Name;
    }

    get currentProgramName() {
        return this.initData?.attendee?.evt__Event__r?.Name || '';
    }

    get originalOppName() {
        return this.initData?.originalOpp?.Name || '';
    }

    // ── Financial Summary Fields ──

    get paymentStatus() {
        return this.initData?.originalOpp?.Payment_Status__c || 'N/A';
    }

    get formattedOriginalFee() {
        return CURRENCY_FORMATTER.format(this.initData?.originalProgramFeeTotal || 0);
    }

    get formattedOriginalDiscount() {
        return CURRENCY_FORMATTER.format(this.initData?.originalOpp?.Discount_Amount__c || 0);
    }

    get formattedRegistrationTotal() {
        return CURRENCY_FORMATTER.format(this.initData?.originalOpp?.Amount || 0);
    }

    get formattedPaymentBalance() {
        return CURRENCY_FORMATTER.format(this.initData?.originalOpp?.pymt__Balance__c || 0);
    }

    // ── Transfer Detail Formatters ──

    get formattedExpectedFee() {
        const fee = this.selectedProgram?.Expected_Program_Fee__c
            || this.programDetails?.expectedProgramFee || 0;
        return CURRENCY_FORMATTER.format(fee);
    }

    get formattedNewFee() {
        return CURRENCY_FORMATTER.format(this.newProgramFeeAmount || 0);
    }

    get formattedTransferFee() {
        return CURRENCY_FORMATTER.format(this.transferFeeAmount || 0);
    }

    get formattedCreditAmount() {
        return CURRENCY_FORMATTER.format(-(this.initData?.originalProgramFeeTotal || 0));
    }

    get formattedDiscountAmount() {
        return CURRENCY_FORMATTER.format(-(this.discountAmount || 0));
    }

    get formattedNetCredit() {
        return CURRENCY_FORMATTER.format(this.netCreditAmount);
    }

    get netCreditAmount() {
        const originalFee = this.initData?.originalProgramFeeTotal || 0;
        const transferFee = this.applyTransferFee ? (this.transferFeeAmount || 0) : 0;
        return originalFee - transferFee;
    }

    get showSettlementInfo() {
        return this.settlementType !== '';
    }

    get settlementDescription() {
        if (this.settlementType === 'Refund') {
            return 'A refund payment record will be created for the net credit amount.';
        }
        if (this.settlementType === 'Unapplied Funds') {
            return 'An Unapplied Funds record will be created and linked to both opportunities.';
        }
        return '';
    }

    get reviewDiscountCode() {
        return this.discountCode ? ` (${this.discountCode})` : '';
    }

    get hasFilteredPrograms() {
        return this.filteredPrograms && this.filteredPrograms.length > 0;
    }

    get selectedProgramStartDate() {
        if (!this.selectedProgram?.evt__Start__c) return '';
        return new Date(this.selectedProgram.evt__Start__c).toLocaleDateString('en-US', {
            month: 'short', day: '2-digit', year: 'numeric'
        });
    }

    get sameProgramTransfer() {
        if (!this.selectedProgram || !this.initData?.attendee?.evt__Event__c) return false;
        return this.selectedProgram.Id === this.initData.attendee.evt__Event__c;
    }

    get newOppUrl() {
        return `/lightning/r/Opportunity/${this.transferResult?.newOpportunityId}/view`;
    }

    get newAttendeeUrl() {
        return `/lightning/r/evt__Attendee__c/${this.transferResult?.newAttendeeId}/view`;
    }

    // ═══════════════ STEP 1: PROGRAM SEARCH ═══════════════

    handleProgramSearch(event) {
        this.programSearchTerm = event.target.value;
        if (!this.programSearchTerm || this.programSearchTerm.length < 2) {
            this.filteredPrograms = [];
            return;
        }
        const term = this.programSearchTerm.toLowerCase();
        this.filteredPrograms = this.availablePrograms.filter(p => {
            return (p.Name && p.Name.toLowerCase().includes(term))
                || (p.Program_Code__c && p.Program_Code__c.toLowerCase().includes(term))
                || (p.Program_Acronym__c && p.Program_Acronym__c.toLowerCase().includes(term));
        });
    }

    handleProgramSelect(event) {
        const selectedRows = event.detail.selectedRows;
        if (selectedRows && selectedRows.length > 0) {
            this.selectedProgram = selectedRows[0];
            this.selectedProgramRows = [selectedRows[0].Id];
        } else {
            this.selectedProgram = null;
            this.selectedProgramRows = [];
        }
    }

    // ═══════════════ STEP 2: DETAIL HANDLERS ═══════════════

    handleFeeChange(event) {
        this.newProgramFeeAmount = event.target.value;
    }

    handleTransferFeeToggle(event) {
        this.applyTransferFee = event.target.checked;
    }

    handleTransferFeeAmountChange(event) {
        this.transferFeeAmount = event.target.value;
    }

    handleSettlementChange(event) {
        this.settlementType = event.detail.value;
    }

    handleDiscountToggle(event) {
        this.applyDiscount = event.target.checked;
        if (!this.applyDiscount) {
            this.discountAmount = 0;
            this.discountCode = '';
        }
    }

    handleDiscountAmountChange(event) {
        this.discountAmount = event.target.value;
    }

    handleDiscountCodeChange(event) {
        this.discountCode = event.target.value;
    }

    handleCommentsChange(event) {
        this.regChangeComments = event.target.value;
    }

    // ═══════════════ CANCELLATION HANDLERS ═══════════════

    handleCancelFeeToggle(event) {
        this.applyCancellationFee = event.target.checked;
        if (!this.applyCancellationFee) {
            this.cancellationFeeAmount = 0;
        }
    }

    handleCancelFeeAmountChange(event) {
        this.cancellationFeeAmount = event.target.value;
    }

    handleCancelSettlementChange(event) {
        this.cancelSettlementType = event.detail.value;
    }

    handleCancelCommentsChange(event) {
        this.cancelComments = event.target.value;
    }

    // ═══════════════ SUBSTITUTION HANDLERS ═══════════════

    async handleContactSearch(event) {
        this.contactSearchTerm = event.target.value;
        if (!this.contactSearchTerm || this.contactSearchTerm.length < 2) {
            this.contactSearchResults = [];
            return;
        }

        this.isSearchingContacts = true;
        try {
            // Use Opportunity's AccountId (matches original flow behavior)
            const oppAccountId = this.initData?.originalOpp?.AccountId;
            console.log('[Substitution] Searching contacts with term:', this.contactSearchTerm, 'accountId:', oppAccountId);

            this.contactSearchResults = await searchContacts({
                searchTerm: this.contactSearchTerm,
                accountId: oppAccountId
            });

            console.log('[Substitution] Search returned', this.contactSearchResults?.length || 0, 'contacts');
        } catch (error) {
            console.error('[Substitution] Contact search error:', error);
            this.showToast('Error', 'Failed to search contacts: ' + this.extractErrorMessage(error), 'error');
            this.contactSearchResults = [];
        } finally {
            this.isSearchingContacts = false;
        }
    }

    handleContactSelect(event) {
        const contactId = event.currentTarget.dataset.id;
        this.selectedContact = this.contactSearchResults.find(c => c.id === contactId);
    }

    handleClearContactSelection() {
        this.selectedContact = null;
        this.contactSearchTerm = '';
        this.contactSearchResults = [];
    }

    handleSubstitutionDiscountToggle(event) {
        this.applySubstitutionDiscount = event.target.value === 'yes';
    }

    handleSubstitutionCommentsChange(event) {
        this.substitutionComments = event.target.value;
    }

    // ═══════════════ NAVIGATION ═══════════════

    async handleNext() {
        if (this.currentStep === '0') {
            if (!this.changeType) {
                this.showToast('Error', 'Please select a change type.', 'error');
                return;
            }
            this.currentStep = '1';
            return;
        }

        if (this.isTransferPath) {
            if (this.currentStep === '1') {
                if (!this.selectedProgram) {
                    this.showToast('Error', 'Please select a program to transfer to.', 'error');
                    return;
                }
                await this.loadProgramDetails();
                this.currentStep = '2';

            } else if (this.currentStep === '2') {
                if (!this.validateStep2()) return;
                this.currentStep = '3';
            }
        }

        if (this.isCancellationPath) {
            if (this.currentStep === '1') {
                if (this.applyCancellationFee && (!this.cancellationFeeAmount || Number(this.cancellationFeeAmount) <= 0)) {
                    this.showToast('Error', 'Please enter a valid cancellation fee amount.', 'error');
                    return;
                }
                if (this.requiresSettlementScreen) {
                    this.currentStep = '2';
                } else {
                    this.currentStep = '3';
                }

            } else if (this.currentStep === '2') {
                if (!this.cancelSettlementType) {
                    this.showToast('Error', 'Please select a settlement type.', 'error');
                    return;
                }
                this.currentStep = '3';
            }
        }

        if (this.isSubstitutionPath) {
            if (this.currentStep === '1') {
                if (!this.selectedContact) {
                    this.showToast('Error', 'Please select a substitute contact.', 'error');
                    return;
                }
                this.currentStep = '2';
            }
        }
    }

    handleBack() {
        if (this.currentStep === '1') {
            this.currentStep = '0';
        } else if (this.currentStep === '2') {
            this.currentStep = '1';
        } else if (this.currentStep === '3') {
            if (this.isCancellationPath && !this.requiresSettlementScreen) {
                this.currentStep = '1';
            } else {
                this.currentStep = '2';
            }
        }
    }

    handleCancel() {
        // Reset to initial state
        this.currentStep = '0';
        this.changeType = '';
        // Transfer state
        this.programSearchTerm = '';
        this.filteredPrograms = [];
        this.selectedProgram = null;
        this.selectedProgramRows = [];
        this.programDetails = null;
        this.newProgramFeeAmount = 0;
        this.applyTransferFee = true;
        this.transferFeeAmount = 0;
        this.settlementType = '';
        this.applyDiscount = false;
        this.discountAmount = 0;
        this.discountCode = '';
        this.regChangeComments = '';
        this.transferResult = {};
        // Cancellation state
        this.applyCancellationFee = false;
        this.cancellationFeeAmount = 0;
        this.cancelSettlementType = '';
        this.cancelComments = '';
        this.cancellationResult = {};
        // Substitution state
        this.contactSearchTerm = '';
        this.contactSearchResults = [];
        this.selectedContact = null;
        this.applySubstitutionDiscount = true;
        this.substitutionComments = '';
        this.substitutionResult = {};
        this.isSearchingContacts = false;
        this.isProcessing = false;
    }

    // ═══════════════ PROGRAM DETAILS LOAD ═══════════════

    async loadProgramDetails() {
        this.isLoading = true;
        try {
            this.programDetails = await getProgramDetails({
                specialEventId: this.selectedProgram.Id,
                pricebook2Id: this.initData?.originalOpp?.Pricebook2Id
            });

            this.newProgramFeeAmount = this.programDetails?.expectedProgramFee
                || this.selectedProgram.Expected_Program_Fee__c || 0;

            if (this.programDetails?.transferFeePBE) {
                this.transferFeeAmount = this.programDetails.transferFeePBE.UnitPrice || 0;
            }
        } catch (error) {
            this.showToast('Error', 'Failed to load program details: ' + this.extractErrorMessage(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ═══════════════ VALIDATION ═══════════════

    validateStep2() {
        if (this.newProgramFeeAmount === null || this.newProgramFeeAmount === undefined || this.newProgramFeeAmount === '') {
            this.showToast('Validation Error', 'Please enter the new program fee amount.', 'error');
            return false;
        }
        if (Number(this.newProgramFeeAmount) < 0) {
            this.showToast('Validation Error', 'Program fee amount cannot be negative.', 'error');
            return false;
        }
        if (this.applyDiscount) {
            const hasAmount = this.discountAmount && Number(this.discountAmount) > 0;
            const hasCode = this.discountCode && String(this.discountCode).trim().length > 0;
            if (!hasAmount && !hasCode) {
                this.showToast('Validation Error', 'Please enter either a discount amount or a discount code.', 'error');
                return false;
            }
        }
        return true;
    }

    // ═══════════════ EXECUTE TRANSFER ═══════════════

    async handleExecuteTransfer() {
        this.isProcessing = true;

        try {
            // Use attendee ID from initData (already fetched) as fallback
            // in case recordId becomes unavailable in Quick Action context
            const attendeeId = this.recordId || this.initData?.attendee?.Id;

            // Debug logging - check browser console (F12) if issues persist
            console.log('[TransferRegistration] handleExecuteTransfer called');
            console.log('[TransferRegistration] recordId:', this.recordId);
            console.log('[TransferRegistration] initData.attendee.Id:', this.initData?.attendee?.Id);
            console.log('[TransferRegistration] resolved attendeeId:', attendeeId);

            // Robust validation - check for null, undefined, and empty string
            if (!attendeeId || attendeeId === '' || attendeeId.length < 15) {
                this.showToast(
                    'Error',
                    `Unable to determine Attendee ID. recordId=${this.recordId}, initData.attendee.Id=${this.initData?.attendee?.Id}. Please refresh and try again.`,
                    'error'
                );
                this.isProcessing = false;
                return;
            }

            const request = {
                attendeeId: attendeeId,
                originalOppId: this.initData.originalOpp.Id,
                newSpecialEventId: this.selectedProgram.Id,
                applyTransferFee: this.applyTransferFee,
                transferFeeAmount: this.applyTransferFee ? Number(this.transferFeeAmount) : 0,
                applyDiscount: this.applyDiscount,
                discountAmount: this.applyDiscount ? Number(this.discountAmount) : 0,
                discountCode: this.applyDiscount ? this.discountCode : '',
                sameProgramTransfer: this.sameProgramTransfer,
                newProgramFeeAmount: Number(this.newProgramFeeAmount),
                regChangeComments: this.regChangeComments || ''
            };

            const result = await executeTransfer({ request: request });

            if (result.success) {
                this.transferResult = result;
                this.currentStep = '4';
                this.showToast(
                    'Transfer Successful',
                    `${this.attendeeName} transferred to ${this.selectedProgram.Name}`,
                    'success'
                );
            } else {
                this.showToast('Transfer Failed', result.errorMessage, 'error');
            }
        } catch (error) {
            this.showToast('Error', this.extractErrorMessage(error), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    // ═══════════════ EXECUTE CANCELLATION ═══════════════

    async handleExecuteCancellation() {
        this.isProcessing = true;

        try {
            const attendeeId = this.recordId || this.initData?.attendee?.Id;

            if (!attendeeId || attendeeId === '' || attendeeId.length < 15) {
                this.showToast(
                    'Error',
                    'Unable to determine Attendee ID. Please refresh and try again.',
                    'error'
                );
                this.isProcessing = false;
                return;
            }

            const request = {
                attendeeId: attendeeId,
                originalOppId: this.initData.originalOpp.Id,
                applyCancellationFee: this.applyCancellationFee,
                cancellationFeeAmount: this.applyCancellationFee ? Number(this.cancellationFeeAmount) : 0,
                settlementType: this.cancelSettlementType || null,
                cancelComments: this.cancelComments || ''
            };

            const result = await executeCancellation({ request: request });

            if (result.success) {
                this.cancellationResult = result;
                this.currentStep = '4';
                this.showToast(
                    'Cancellation Successful',
                    `${this.attendeeName}'s registration has been cancelled.`,
                    'success'
                );
            } else {
                this.showToast('Cancellation Failed', result.errorMessage, 'error');
            }
        } catch (error) {
            this.showToast('Error', this.extractErrorMessage(error), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    // ═══════════════ EXECUTE SUBSTITUTION ═══════════════

    async handleExecuteSubstitution() {
        this.isProcessing = true;

        try {
            const attendeeId = this.recordId || this.initData?.attendee?.Id;

            if (!attendeeId || attendeeId === '' || attendeeId.length < 15) {
                this.showToast(
                    'Error',
                    'Unable to determine Attendee ID. Please refresh and try again.',
                    'error'
                );
                this.isProcessing = false;
                return;
            }

            if (!this.selectedContact) {
                this.showToast('Error', 'No substitute contact selected.', 'error');
                this.isProcessing = false;
                return;
            }

            const request = {
                attendeeId: attendeeId,
                originalOppId: this.initData.originalOpp.Id,
                substituteContactId: this.selectedContact.id,
                applyDiscount: this.hasOriginalDiscount ? this.applySubstitutionDiscount : false,
                substitutionComments: this.substitutionComments || ''
            };

            const result = await executeSubstitution({ request: request });

            if (result.success) {
                this.substitutionResult = result;
                this.currentStep = '3';
                this.showToast(
                    'Substitution Successful',
                    `${this.attendeeName} has been substituted with ${this.selectedContact.name}.`,
                    'success'
                );
            } else {
                this.showToast('Substitution Failed', result.errorMessage, 'error');
            }
        } catch (error) {
            this.showToast('Error', this.extractErrorMessage(error), 'error');
        } finally {
            this.isProcessing = false;
        }
    }

    // ═══════════════ UTILITIES ═══════════════

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    extractErrorMessage(error) {
        if (typeof error === 'string') return error;
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        return JSON.stringify(error);
    }
}
