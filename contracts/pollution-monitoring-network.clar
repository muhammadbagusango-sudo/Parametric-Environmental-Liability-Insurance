;; title: pollution-monitoring-network
;; version: 1.0.0
;; summary: Satellite and ground sensor integration for environmental contamination detection
;; description: A comprehensive system for monitoring environmental pollution through multiple sensor networks

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-SENSOR (err u101))
(define-constant ERR-SENSOR-EXISTS (err u102))
(define-constant ERR-INVALID-DATA (err u103))
(define-constant ERR-THRESHOLD-EXCEEDED (err u104))
(define-constant ERR-SENSOR-INACTIVE (err u105))
(define-constant ERR-INVALID-LOCATION (err u106))
(define-constant ERR-INSUFFICIENT-FUNDS (err u107))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MAX-SENSORS u1000)
(define-constant MIN-READING-INTERVAL u3600) ;; 1 hour in seconds
(define-constant POLLUTION-CRITICAL-THRESHOLD u80)
(define-constant POLLUTION-WARNING-THRESHOLD u60)
(define-constant SENSOR-REGISTRATION-FEE u100000) ;; 0.1 STX in microSTX

;; Data variables
(define-data-var next-sensor-id uint u1)
(define-data-var total-active-sensors uint u0)
(define-data-var contract-paused bool false)
(define-data-var emergency-contact principal tx-sender)

;; Sensor data structure
(define-map sensors
    { sensor-id: uint }
    {
        owner: principal,
        sensor-type: (string-ascii 20),
        location: { lat: int, lng: int },
        status: (string-ascii 10),
        last-reading-time: uint,
        registration-block: uint,
        metadata: (optional (string-ascii 100))
    }
)

;; Pollution readings data
(define-map pollution-readings
    { sensor-id: uint, timestamp: uint }
    {
        pollutant-type: (string-ascii 20),
        concentration: uint,
        air-quality-index: uint,
        temperature: int,
        humidity: uint,
        verified: bool
    }
)

;; Sensor authorization map
(define-map authorized-operators
    { operator: principal }
    { authorized: bool, authorization-level: uint }
)

;; Alert system map
(define-map pollution-alerts
    { alert-id: uint }
    {
        sensor-id: uint,
        alert-level: (string-ascii 10),
        timestamp: uint,
        resolved: bool,
        response-team: (optional principal)
    }
)

;; Geographic coverage areas
(define-map coverage-areas
    { area-id: uint }
    {
        name: (string-ascii 50),
        boundaries: { north: int, south: int, east: int, west: int },
        sensor-count: uint,
        risk-level: (string-ascii 10)
    }
)

;; Public function: Register new sensor
(define-public (register-sensor (sensor-type (string-ascii 20)) (lat int) (lng int) (metadata (optional (string-ascii 100))))
    (let (
        (sensor-id (var-get next-sensor-id))
        (caller tx-sender)
    )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (<= (var-get total-active-sensors) MAX-SENSORS) ERR-INVALID-SENSOR)
        (asserts! (and (>= lat -90000000) (<= lat 90000000)) ERR-INVALID-LOCATION)
        (asserts! (and (>= lng -180000000) (<= lng 180000000)) ERR-INVALID-LOCATION)
        
        ;; Charge registration fee
        (try! (stx-transfer? SENSOR-REGISTRATION-FEE caller CONTRACT-OWNER))
        
        ;; Register sensor
        (map-set sensors
            { sensor-id: sensor-id }
            {
                owner: caller,
                sensor-type: sensor-type,
                location: { lat: lat, lng: lng },
                status: "active",
                last-reading-time: u0,
                registration-block: burn-block-height,
                metadata: metadata
            }
        )
        
        ;; Update counters
        (var-set next-sensor-id (+ sensor-id u1))
        (var-set total-active-sensors (+ (var-get total-active-sensors) u1))
        
        (ok sensor-id)
    )
)

;; Public function: Submit pollution reading
(define-public (submit-reading 
    (sensor-id uint) 
    (pollutant-type (string-ascii 20)) 
    (concentration uint) 
    (air-quality-index uint)
    (temperature int)
    (humidity uint)
)
    (let (
        (sensor (unwrap! (map-get? sensors { sensor-id: sensor-id }) ERR-INVALID-SENSOR))
        (current-time burn-block-height)
        (caller tx-sender)
    )
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get owner sensor) caller) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status sensor) "active") ERR-SENSOR-INACTIVE)
        (asserts! (> concentration u0) ERR-INVALID-DATA)
        (asserts! (<= air-quality-index u500) ERR-INVALID-DATA)
        
        ;; Check if enough time has passed since last reading
        (asserts! 
            (> (- current-time (get last-reading-time sensor)) MIN-READING-INTERVAL)
            ERR-INVALID-DATA
        )
        
        ;; Store reading
        (map-set pollution-readings
            { sensor-id: sensor-id, timestamp: current-time }
            {
                pollutant-type: pollutant-type,
                concentration: concentration,
                air-quality-index: air-quality-index,
                temperature: temperature,
                humidity: humidity,
                verified: false
            }
        )
        
        ;; Update sensor last reading time
        (map-set sensors
            { sensor-id: sensor-id }
            (merge sensor { last-reading-time: current-time })
        )
        
        ;; Check for pollution alerts
        (if (>= air-quality-index POLLUTION-CRITICAL-THRESHOLD)
            (begin
                (create-pollution-alert sensor-id "critical")
                true
            )
            (if (>= air-quality-index POLLUTION-WARNING-THRESHOLD)
                (begin
                    (create-pollution-alert sensor-id "warning")
                    true
                )
                true
            )
        )
        
        (ok true)
    )
)

;; Public function: Verify reading (for authorized operators)
(define-public (verify-reading (sensor-id uint) (timestamp uint))
    (let (
        (caller tx-sender)
        (reading (unwrap! (map-get? pollution-readings { sensor-id: sensor-id, timestamp: timestamp }) ERR-INVALID-DATA))
        (operator-auth (default-to { authorized: false, authorization-level: u0 } 
                       (map-get? authorized-operators { operator: caller })))
    )
        (asserts! (get authorized operator-auth) ERR-NOT-AUTHORIZED)
        (asserts! (>= (get authorization-level operator-auth) u1) ERR-NOT-AUTHORIZED)
        
        (map-set pollution-readings
            { sensor-id: sensor-id, timestamp: timestamp }
            (merge reading { verified: true })
        )
        
        (ok true)
    )
)

;; Public function: Deactivate sensor
(define-public (deactivate-sensor (sensor-id uint))
    (let (
        (sensor (unwrap! (map-get? sensors { sensor-id: sensor-id }) ERR-INVALID-SENSOR))
        (caller tx-sender)
    )
        (asserts! (or (is-eq (get owner sensor) caller) (is-eq caller CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)
        
        (map-set sensors
            { sensor-id: sensor-id }
            (merge sensor { status: "inactive" })
        )
        
        (var-set total-active-sensors (- (var-get total-active-sensors) u1))
        
        (ok true)
    )
)

;; Private function: Create pollution alert
(define-private (create-pollution-alert (sensor-id uint) (alert-level (string-ascii 10)))
    (let (
        (alert-id (var-get total-active-sensors)) ;; Use sensor count as alert ID
        (current-time burn-block-height)
    )
        (map-set pollution-alerts
            { alert-id: alert-id }
            {
                sensor-id: sensor-id,
                alert-level: alert-level,
                timestamp: current-time,
                resolved: false,
                response-team: none
            }
        )
        alert-id
    )
)

;; Read-only function: Get sensor details
(define-read-only (get-sensor-info (sensor-id uint))
    (map-get? sensors { sensor-id: sensor-id })
)

;; Read-only function: Get pollution reading
(define-read-only (get-reading (sensor-id uint) (timestamp uint))
    (map-get? pollution-readings { sensor-id: sensor-id, timestamp: timestamp })
)

;; Read-only function: Get total sensors
(define-read-only (get-total-sensors)
    (var-get total-active-sensors)
)

;; Read-only function: Check sensor status
(define-read-only (is-sensor-active (sensor-id uint))
    (match (map-get? sensors { sensor-id: sensor-id })
        sensor (is-eq (get status sensor) "active")
        false
    )
)

;; Admin function: Authorize operator
(define-public (authorize-operator (operator principal) (level uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (map-set authorized-operators
            { operator: operator }
            { authorized: true, authorization-level: level }
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
