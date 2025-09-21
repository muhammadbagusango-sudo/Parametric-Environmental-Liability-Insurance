;; title: cleanup-cost-estimator
;; version: 1.0.0
;; summary: Automated cleanup cost calculation and insurance payout processing
;; description: Advanced system for calculating environmental cleanup costs and processing insurance claims

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-INVALID-CLAIM (err u201))
(define-constant ERR-CLAIM-EXISTS (err u202))
(define-constant ERR-INSUFFICIENT-COVERAGE (err u203))
(define-constant ERR-CLAIM-EXPIRED (err u204))
(define-constant ERR-INVALID-ASSESSMENT (err u205))
(define-constant ERR-PAYOUT-FAILED (err u206))
(define-constant ERR-POLICY-INACTIVE (err u207))
(define-constant ERR-INVALID-PREMIUM (err u208))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MIN-POLICY-PREMIUM u500000) ;; 0.5 STX
(define-constant MAX-POLICY-COVERAGE u100000000000) ;; 100,000 STX
(define-constant CLAIM-PROCESSING-FEE u50000) ;; 0.05 STX
(define-constant ASSESSMENT-VALIDITY-PERIOD u2592000) ;; 30 days in seconds
(define-constant MAX-CLAIMS-PER-POLICY u10)
(define-constant RISK-MULTIPLIER-BASE u100)

;; Pollution type cost multipliers (per unit of concentration)
(define-constant CHEMICAL-SPILL-MULTIPLIER u150)
(define-constant OIL-SPILL-MULTIPLIER u200)
(define-constant TOXIC-GAS-MULTIPLIER u180)
(define-constant RADIOACTIVE-MULTIPLIER u300)
(define-constant PLASTIC-WASTE-MULTIPLIER u80)
(define-constant HEAVY-METALS-MULTIPLIER u250)

;; Data variables
(define-data-var next-policy-id uint u1)
(define-data-var next-claim-id uint u1)
(define-data-var total-policies uint u0)
(define-data-var total-claims-processed uint u0)
(define-data-var total-payouts uint u0)
(define-data-var contract-paused bool false)
(define-data-var insurance-fund uint u0)

;; Insurance policies
(define-map insurance-policies
    { policy-id: uint }
    {
        holder: principal,
        coverage-amount: uint,
        premium-paid: uint,
        policy-start: uint,
        policy-end: uint,
        risk-category: (string-ascii 20),
        location: { lat: int, lng: int },
        status: (string-ascii 10),
        claims-count: uint
    }
)

;; Environmental assessments
(define-map environmental-assessments
    { assessment-id: uint }
    {
        assessor: principal,
        location: { lat: int, lng: int },
        pollution-type: (string-ascii 20),
        severity-level: uint,
        affected-area: uint,
        contamination-depth: uint,
        estimated-cost: uint,
        assessment-date: uint,
        verified: bool
    }
)

;; Cleanup cost claims
(define-map cleanup-claims
    { claim-id: uint }
    {
        policy-id: uint,
        claimant: principal,
        assessment-id: uint,
        requested-amount: uint,
        approved-amount: uint,
        status: (string-ascii 15),
        claim-date: uint,
        processing-date: (optional uint),
        payout-date: (optional uint),
        evidence-hash: (optional (buff 32))
    }
)

;; Authorized assessors
(define-map authorized-assessors
    { assessor: principal }
    {
        authorized: bool,
        specialization: (string-ascii 30),
        certification-level: uint,
        assessments-completed: uint
    }
)

;; Risk factor calculations
(define-map risk-factors
    { factor-type: (string-ascii 20) }
    { multiplier: uint, weight: uint }
)

;; Payout history for transparency
(define-map payout-history
    { payout-id: uint }
    {
        claim-id: uint,
        recipient: principal,
        amount: uint,
        timestamp: uint,
        transaction-hash: (optional (buff 32))
    }
)

;; Public function: Purchase insurance policy
(define-public (purchase-policy 
    (coverage-amount uint) 
    (risk-category (string-ascii 20))
    (lat int)
    (lng int)
    (duration-blocks uint)
)
    (let (
        (policy-id (var-get next-policy-id))
        (caller tx-sender)
        (current-block burn-block-height)
        (premium (calculate-premium coverage-amount risk-category duration-blocks))
    )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (>= coverage-amount MIN-POLICY-PREMIUM) ERR-INVALID-PREMIUM)
        (asserts! (<= coverage-amount MAX-POLICY-COVERAGE) ERR-INVALID-PREMIUM)
        (asserts! (> duration-blocks u0) ERR-INVALID-PREMIUM)
        
        ;; Collect premium
        (try! (stx-transfer? premium caller CONTRACT-OWNER))
        
        ;; Add premium to insurance fund
        (var-set insurance-fund (+ (var-get insurance-fund) premium))
        
        ;; Create policy
        (map-set insurance-policies
            { policy-id: policy-id }
            {
                holder: caller,
                coverage-amount: coverage-amount,
                premium-paid: premium,
                policy-start: current-block,
                policy-end: (+ current-block duration-blocks),
                risk-category: risk-category,
                location: { lat: lat, lng: lng },
                status: "active",
                claims-count: u0
            }
        )
        
        ;; Update counters
        (var-set next-policy-id (+ policy-id u1))
        (var-set total-policies (+ (var-get total-policies) u1))
        
        (ok policy-id)
    )
)

;; Public function: Submit environmental assessment (for authorized assessors)
(define-public (submit-assessment
    (lat int)
    (lng int)
    (pollution-type (string-ascii 20))
    (severity-level uint)
    (affected-area uint)
    (contamination-depth uint)
)
    (let (
        (assessment-id (+ (var-get next-claim-id) u1000)) ;; Offset to avoid collision
        (caller tx-sender)
        (assessor (default-to { authorized: false, specialization: "", certification-level: u0, assessments-completed: u0 }
                               (map-get? authorized-assessors { assessor: caller })))
        (estimated-cost (calculate-cleanup-cost pollution-type severity-level affected-area contamination-depth))
        (current-time burn-block-height)
    )
        (asserts! (get authorized assessor) ERR-NOT-AUTHORIZED)
        (asserts! (> severity-level u0) ERR-INVALID-ASSESSMENT)
        (asserts! (<= severity-level u10) ERR-INVALID-ASSESSMENT)
        (asserts! (> affected-area u0) ERR-INVALID-ASSESSMENT)
        
        ;; Store assessment
        (map-set environmental-assessments
            { assessment-id: assessment-id }
            {
                assessor: caller,
                location: { lat: lat, lng: lng },
                pollution-type: pollution-type,
                severity-level: severity-level,
                affected-area: affected-area,
                contamination-depth: contamination-depth,
                estimated-cost: estimated-cost,
                assessment-date: current-time,
                verified: false
            }
        )
        
        ;; Update assessor stats
        (map-set authorized-assessors
            { assessor: caller }
            (merge assessor { assessments-completed: (+ (get assessments-completed assessor) u1) })
        )
        
        (ok assessment-id)
    )
)

;; Public function: File cleanup claim
(define-public (file-claim (policy-id uint) (assessment-id uint) (requested-amount uint) (evidence-hash (optional (buff 32))))
    (let (
        (claim-id (var-get next-claim-id))
        (caller tx-sender)
        (policy (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR-INVALID-CLAIM))
        (assessment (unwrap! (map-get? environmental-assessments { assessment-id: assessment-id }) ERR-INVALID-ASSESSMENT))
        (current-block burn-block-height)
        (current-time burn-block-height)
    )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get holder policy) caller) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status policy) "active") ERR-POLICY-INACTIVE)
        (asserts! (< current-block (get policy-end policy)) ERR-CLAIM-EXPIRED)
        (asserts! (< (get claims-count policy) MAX-CLAIMS-PER-POLICY) ERR-INVALID-CLAIM)
        (asserts! (<= requested-amount (get coverage-amount policy)) ERR-INSUFFICIENT-COVERAGE)
        
        ;; Charge processing fee
        (try! (stx-transfer? CLAIM-PROCESSING-FEE caller CONTRACT-OWNER))
        
        ;; Create claim
        (map-set cleanup-claims
            { claim-id: claim-id }
            {
                policy-id: policy-id,
                claimant: caller,
                assessment-id: assessment-id,
                requested-amount: requested-amount,
                approved-amount: u0,
                status: "pending",
                claim-date: current-time,
                processing-date: none,
                payout-date: none,
                evidence-hash: evidence-hash
            }
        )
        
        ;; Update policy claims count
        (map-set insurance-policies
            { policy-id: policy-id }
            (merge policy { claims-count: (+ (get claims-count policy) u1) })
        )
        
        ;; Update global counter
        (var-set next-claim-id (+ claim-id u1))
        
        (ok claim-id)
    )
)

;; Public function: Process claim (admin only)
(define-public (process-claim (claim-id uint) (approved-amount uint))
    (let (
        (claim (unwrap! (map-get? cleanup-claims { claim-id: claim-id }) ERR-INVALID-CLAIM))
        (current-time burn-block-height)
        (caller tx-sender)
    )
        (asserts! (is-eq caller CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status claim) "pending") ERR-INVALID-CLAIM)
        (asserts! (<= approved-amount (get requested-amount claim)) ERR-INVALID-CLAIM)
        (asserts! (<= approved-amount (var-get insurance-fund)) ERR-INSUFFICIENT-COVERAGE)
        
        ;; Update claim status
        (map-set cleanup-claims
            { claim-id: claim-id }
            (merge claim {
                approved-amount: approved-amount,
                status: "approved",
                processing-date: (some current-time)
            })
        )
        
        ;; Execute payout if approved amount > 0
        (if (> approved-amount u0)
            (begin
                (try! (stx-transfer? approved-amount CONTRACT-OWNER (get claimant claim)))
                (var-set insurance-fund (- (var-get insurance-fund) approved-amount))
                (var-set total-payouts (+ (var-get total-payouts) approved-amount))
                
                ;; Update claim with payout date
                (map-set cleanup-claims
                    { claim-id: claim-id }
                    (merge (unwrap-panic (map-get? cleanup-claims { claim-id: claim-id }))
                           { payout-date: (some current-time) })
                )
                
                ;; Record payout in history
                (map-set payout-history
                    { payout-id: (var-get total-claims-processed) }
                    {
                        claim-id: claim-id,
                        recipient: (get claimant claim),
                        amount: approved-amount,
                        timestamp: current-time,
                        transaction-hash: none
                    }
                )
            )
            true
        )
        
        (var-set total-claims-processed (+ (var-get total-claims-processed) u1))
        
        (ok true)
    )
)

;; Private function: Calculate cleanup cost based on pollution parameters
(define-private (calculate-cleanup-cost 
    (pollution-type (string-ascii 20)) 
    (severity-level uint) 
    (affected-area uint) 
    (contamination-depth uint)
)
    (let (
        (base-multiplier (get-pollution-multiplier pollution-type))
        (area-factor (* affected-area u10))
        (depth-factor (* contamination-depth u5))
        (severity-factor (* severity-level u100))
    )
        (* (* (* base-multiplier area-factor) depth-factor) severity-factor)
    )
)

;; Private function: Get pollution type multiplier
(define-private (get-pollution-multiplier (pollution-type (string-ascii 20)))
    (if (is-eq pollution-type "chemical-spill")
        CHEMICAL-SPILL-MULTIPLIER
        (if (is-eq pollution-type "oil-spill")
            OIL-SPILL-MULTIPLIER
            (if (is-eq pollution-type "toxic-gas")
                TOXIC-GAS-MULTIPLIER
                (if (is-eq pollution-type "radioactive")
                    RADIOACTIVE-MULTIPLIER
                    (if (is-eq pollution-type "plastic-waste")
                        PLASTIC-WASTE-MULTIPLIER
                        (if (is-eq pollution-type "heavy-metals")
                            HEAVY-METALS-MULTIPLIER
                            u100 ;; Default multiplier
                        )
                    )
                )
            )
        )
    )
)

;; Private function: Calculate insurance premium
(define-private (calculate-premium (coverage-amount uint) (risk-category (string-ascii 20)) (duration-blocks uint))
    (let (
        (base-premium (/ coverage-amount u1000)) ;; 0.1% of coverage
        (risk-multiplier (get-risk-multiplier risk-category))
        (duration-factor (/ duration-blocks u144)) ;; Assuming ~144 blocks per day
    )
        (* (* base-premium risk-multiplier) duration-factor)
    )
)

;; Private function: Get risk category multiplier
(define-private (get-risk-multiplier (risk-category (string-ascii 20)))
    (if (is-eq risk-category "low")
        u50
        (if (is-eq risk-category "medium")
            u100
            (if (is-eq risk-category "high")
                u200
                u150 ;; Default for unknown categories
            )
        )
    )
)

;; Read-only function: Get policy details
(define-read-only (get-policy-info (policy-id uint))
    (map-get? insurance-policies { policy-id: policy-id })
)

;; Read-only function: Get claim details
(define-read-only (get-claim-info (claim-id uint))
    (map-get? cleanup-claims { claim-id: claim-id })
)

;; Read-only function: Get assessment details
(define-read-only (get-assessment-info (assessment-id uint))
    (map-get? environmental-assessments { assessment-id: assessment-id })
)

;; Read-only function: Get insurance fund balance
(define-read-only (get-insurance-fund)
    (var-get insurance-fund)
)

;; Read-only function: Get contract statistics
(define-read-only (get-contract-stats)
    {
        total-policies: (var-get total-policies),
        total-claims-processed: (var-get total-claims-processed),
        total-payouts: (var-get total-payouts),
        insurance-fund: (var-get insurance-fund)
    }
)

;; Admin function: Authorize assessor
(define-public (authorize-assessor 
    (assessor principal) 
    (specialization (string-ascii 30)) 
    (certification-level uint)
)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (map-set authorized-assessors
            { assessor: assessor }
            {
                authorized: true,
                specialization: specialization,
                certification-level: certification-level,
                assessments-completed: u0
            }
        )
        (ok true)
    )
)

;; Admin function: Emergency pause
(define-public (emergency-pause)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (var-set contract-paused true)
        (ok true)
    )
)

;; Admin function: Resume operations
(define-public (resume-operations)
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (var-set contract-paused false)
        (ok true)
    )
)
