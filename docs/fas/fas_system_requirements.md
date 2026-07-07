# FAS System Requirements Document

**System:** Financial Authorization System (FAS)  
**Platform Context:** VisionPLUS / Issuer Processing  
**Document Type:** Requirements Specification  
**Source Basis:** `visionplus_fas_document.txt`  
**Date:** 2026-06-17  
**Status:** Draft for review

## 1. Purpose

This document defines the functional, interface, data, security, operational, and non-functional requirements for the Financial Authorization System (FAS).

FAS is the real-time authorization decision engine within a VisionPLUS issuer processing environment. It receives authorization requests from payment networks and channels, validates the card and account, evaluates limits and risk controls, interacts with security services such as HSM and EMV cryptography, creates memo holds, returns authorization responses, and feeds downstream clearing, matching, settlement, and CMS posting processes.

## 2. Scope

### 2.1 In Scope

The FAS system shall support:

- Real-time authorization processing for card transactions.
- ISO 8583 message parsing and response generation.
- Card, account, product, and relationship validation.
- Credit, cash, daily, transaction, overlimit, and velocity limit checks.
- Memo posting and pending authorization hold management.
- Fraud, geographic, MCC, and risk control evaluation.
- PIN, CVV, EMV ARQC, ARPC, and issuer script processing through HSM integration.
- Visa, Mastercard, ATM, domestic network, and digital transaction authorization flows.
- Stand-in processing and fallback authorization rules.
- Reversals, incremental authorizations, completions, duplicate detection, and exception handling.
- Authorization history, shadow balance, pending authorization, velocity, hot card, and control data stores.
- Clearing match support, FAS-to-CMS posting interface, financial transaction generation, and reconciliation controls.
- Monitoring, operational support, auditability, high availability, performance, and disaster recovery requirements.

### 2.2 Out of Scope

The following functions are outside the direct responsibility of FAS, although FAS shall integrate with them:

- CMS billing, statement generation, collections, interest calculation, and general ledger ownership.
- Network clearing file creation by external card schemes.
- Merchant acquiring host processing.
- Full enterprise fraud case management outside the real-time authorization decision.
- Customer servicing user interfaces, unless required for authorization inquiry or support.

## 3. System Context

FAS acts as the real-time decision layer between payment networks and the issuer account system.

```text
POS / ATM / E-Commerce
        |
    Acquirer
        |
Visa / Mastercard / ATM / Domestic Network
        |
       FAS
        |
  CMS / Fraud / HSM / Control Data
        |
Authorization Response
```

CMS is the system of record for accounts, billing, statements, financial posting, interest, collections, and long-term customer/account management.

FAS is the real-time authorization engine optimized for millisecond decisioning. It shall maintain authorization-ready records, shadow balances, pending holds, velocity counters, and control tables so it does not need to perform slow CMS queries for every transaction.

## 4. Key Business Objectives

- Approve valid transactions quickly and accurately.
- Decline transactions that violate card, account, limit, risk, security, network, or product rules.
- Prevent overspending by maintaining real-time shadow balances and pending authorization holds.
- Support issuer risk controls without disrupting legitimate cardholder usage.
- Preserve authorization history for matching, dispute research, fraud review, and operational investigation.
- Ensure clearing and posting processes can accurately convert authorizations into financial transactions.
- Maintain high availability for cardholder payment activity across POS, ATM, e-commerce, wallet, and network channels.

## 5. Stakeholders

- Issuer business operations.
- Card product owners.
- Authorization platform owners.
- VisionPLUS / FAS solution architects.
- CMS and settlement teams.
- Fraud and risk teams.
- Payment network certification teams.
- HSM and cryptography teams.
- Production support and operations teams.
- Compliance, audit, and information security teams.
- QA, performance, and regression testing teams.

## 6. Assumptions

- FAS operates as the real-time authorization component in a VisionPLUS issuer environment.
- CMS remains the authoritative system for posted balances and account lifecycle data.
- FAS maintains synchronized real-time authorization data derived from CMS and other control sources.
- Payment network messages are primarily ISO 8583-based, with scheme-specific extensions.
- HSM services are available for PIN, CVV, EMV cryptogram, and key-management functions.
- Traditional implementations may use VSAM structures such as KSDS and ESDS; modern equivalents may use functionally similar low-latency data stores.

## 7. Glossary

| Term | Definition |
| --- | --- |
| FAS | Financial Authorization System; real-time authorization decision engine. |
| CMS | Card Management System; system of record for accounts, billing, posting, statements, and financial lifecycle. |
| Authorization | Real-time approval, decline, referral, capture, or partial approval decision. |
| Clearing | Financial record received later from a network for settlement and posting. |
| Memo Posting | Temporary authorization hold created by FAS before clearing/posting. |
| Shadow Balance | FAS-calculated exposure including posted balance and pending authorizations. |
| CAF | Card Authorization File containing card-level authorization data. |
| AAF | Account Authorization File containing account-level authorization data. |
| STIP | Stand-In Processing used when issuer, processor, CMS, or connectivity is unavailable. |
| HSM | Hardware Security Module used for PIN, CVV, EMV, and key operations. |
| ARQC | Authorization Request Cryptogram generated by EMV chip card. |
| ARPC | Authorization Response Cryptogram generated by issuer/HSM. |
| DE55 | ISO 8583 data element containing EMV tag data. |
| FTR | Financial Transaction Record generated for CMS posting. |

## 8. High-Level Processing Flow

The system shall support the following authorization lifecycle:

1. Receive authorization message from network or channel.
2. Validate message structure, source, session, and routing.
3. Parse ISO 8583 fields and scheme-specific data.
4. Identify card, account, product, and relationship.
5. Validate card status, expiry, block codes, hot card status, and security data.
6. Validate account status, delinquency, collections, charge-off, and fraud blocks.
7. Evaluate transaction type, MCC, country, currency, POS entry mode, and product controls.
8. Validate PIN, CVV, EMV cryptograms, and other authentication data where applicable.
9. Calculate available credit or available funds using posted balance plus pending authorizations.
10. Evaluate credit, cash, single-transaction, daily, weekly, monthly, overlimit, and velocity limits.
11. Evaluate fraud, geographic, merchant, channel, digital wallet, and behavioral controls.
12. Determine authorization decision.
13. Create or update memo hold, shadow balance, history, and velocity records.
14. Generate network-compliant response code and response message.
15. Return authorization response within the defined service-level objective.
16. Support subsequent reversal, incremental, completion, clearing match, and posting flows.

## 9. Functional Requirements

### 9.1 Authorization Gateway

| ID | Requirement |
| --- | --- |
| FAS-FR-001 | The system shall receive authorization requests from Visa, Mastercard, ATM networks, domestic switches, processors, and approved digital channels. |
| FAS-FR-002 | The system shall validate source connectivity, session state, protocol rules, and message integrity before processing a request. |
| FAS-FR-003 | The system shall route requests to the appropriate internal authorization flow based on network, message type, BIN/product, transaction type, and channel. |
| FAS-FR-004 | The system shall reject malformed, unsupported, duplicate, or unauthorized messages using appropriate response codes and audit records. |
| FAS-FR-005 | The system shall support online authorization, advice, reversal, incremental authorization, completion, and network-specific variants where applicable. |

### 9.2 ISO 8583 Message Processing

| ID | Requirement |
| --- | --- |
| FAS-FR-006 | The system shall parse ISO 8583 MTI and data elements required for issuer authorization. |
| FAS-FR-007 | The system shall support processing of PAN, processing code, transaction amount, POS entry mode, track data, terminal ID, merchant ID, PIN block, EMV data, additional network data, and original data elements. |
| FAS-FR-008 | The system shall map network message fields into an internal FAS transaction object for validation and decisioning. |
| FAS-FR-009 | The system shall construct authorization responses with network-compliant MTI, response code, approval code, EMV response data, and required echo fields. |
| FAS-FR-010 | The system shall support scheme-specific fields for Visa, Mastercard, ATM, domestic, and wallet transaction processing. |

### 9.3 Card Validation

| ID | Requirement |
| --- | --- |
| FAS-FR-011 | The system shall validate that the PAN exists in the card authorization data store. |
| FAS-FR-012 | The system shall validate card expiry date against the authorization request and card record. |
| FAS-FR-013 | The system shall validate card status, including active, inactive, blocked, lost, stolen, hot card, expired, and closed states. |
| FAS-FR-014 | The system shall validate BIN, card range, product, logo, plan, and card type. |
| FAS-FR-015 | The system shall immediately decline transactions for lost, stolen, hot-carded, expired, or blocked cards where configured. |
| FAS-FR-016 | The system shall support validation of primary, supplementary, corporate, fleet, virtual, and tokenized card relationships. |

### 9.4 Account Validation

| ID | Requirement |
| --- | --- |
| FAS-FR-017 | The system shall identify the account associated with the card through card-to-account reference data. |
| FAS-FR-018 | The system shall validate account status, including open, closed, delinquent, collections, charge-off, fraud-blocked, and restricted states. |
| FAS-FR-019 | The system shall decline or refer transactions based on configured account-level blocks and risk indicators. |
| FAS-FR-020 | The system shall apply relationship-level controls for primary/supplementary, corporate hierarchy, fleet hierarchy, and shared-limit accounts. |

### 9.5 Product and Transaction Controls

| ID | Requirement |
| --- | --- |
| FAS-FR-021 | The system shall apply product-level rules based on logo, plan, product type, card type, and customer segment. |
| FAS-FR-022 | The system shall determine whether transaction types are allowed for the product, including purchase, cash advance, ATM withdrawal, refund, balance inquiry, e-commerce, recurring, contactless, wallet, and card-not-present transactions. |
| FAS-FR-023 | The system shall enforce product controls for domestic, international, cash, e-commerce, contactless, fallback, and offline transaction permissions. |
| FAS-FR-024 | The system shall classify transactions using processing code, POS entry mode, MCC, merchant data, network indicators, and EMV data. |

### 9.6 Limit and Available Credit Processing

| ID | Requirement |
| --- | --- |
| FAS-FR-025 | The system shall calculate available credit or available funds using credit limit, posted balance, pending authorizations, cash balance, fees, and configured exclusions. |
| FAS-FR-026 | The system shall maintain shadow exposure using posted balance plus pending authorization holds. |
| FAS-FR-027 | The system shall evaluate credit limit, cash limit, daily amount limit, single-transaction limit, international limit, MCC limit, ATM limit, and product-specific limits. |
| FAS-FR-028 | The system shall support hard decline, soft decline, tolerance-based approval, and overlimit approval rules. |
| FAS-FR-029 | The system shall decline transactions when available credit or configured limits are insufficient, using appropriate response codes. |
| FAS-FR-030 | The system shall support partial approval where permitted by network, product, merchant, and issuer configuration. |

### 9.7 Memo Posting and Pending Holds

| ID | Requirement |
| --- | --- |
| FAS-FR-031 | The system shall create memo holds for approved authorizations that reserve available credit or funds before financial posting. |
| FAS-FR-032 | The system shall support hold types for retail, hotel, car rental, fuel, e-commerce, ATM, and other configured transaction classes. |
| FAS-FR-033 | The system shall store pending authorization amount, currency, merchant, terminal, approval code, authorization date/time, expiry date, and matching keys. |
| FAS-FR-034 | The system shall release, reduce, extend, or replace holds based on reversals, completions, incremental authorizations, expiry rules, and clearing match outcomes. |
| FAS-FR-035 | The system shall ensure memo holds affect available credit but do not create financial ledger posting in CMS until clearing/posting occurs. |

### 9.8 Velocity Controls

| ID | Requirement |
| --- | --- |
| FAS-FR-036 | The system shall maintain transaction velocity counters by card, account, product, channel, transaction type, MCC, merchant, country, and configurable risk dimensions. |
| FAS-FR-037 | The system shall support velocity limits for count and amount over configurable windows including minutes, hours, days, weeks, and months. |
| FAS-FR-038 | The system shall decline, refer, or flag transactions that exceed velocity thresholds. |
| FAS-FR-039 | The system shall update velocity counters in real time for approved and configured declined transactions. |

### 9.9 Fraud, MCC, and Geographic Controls

| ID | Requirement |
| --- | --- |
| FAS-FR-040 | The system shall evaluate fraud rules using transaction amount, channel, POS entry mode, merchant, MCC, country, velocity, historical usage, and risk flags. |
| FAS-FR-041 | The system shall support geographic restrictions by country, region, issuer-defined high-risk list, domestic/international indicator, and impossible-travel rules. |
| FAS-FR-042 | The system shall support MCC controls for blocked, restricted, high-risk, cash-equivalent, gambling, crypto, adult, money-transfer, and issuer-defined categories. |
| FAS-FR-043 | The system shall support merchant-level and terminal-level blocking or risk treatment. |
| FAS-FR-044 | The system shall support approve, decline, refer, capture, and flag outcomes from risk evaluation. |
| FAS-FR-045 | The system shall log risk-rule outcomes for audit, support, fraud investigation, and model tuning. |

### 9.10 PIN, CVV, and HSM Processing

| ID | Requirement |
| --- | --- |
| FAS-FR-046 | The system shall integrate with HSM services for PIN validation, PIN block translation, CVV1, CVV2, iCVV, and EMV cryptographic operations. |
| FAS-FR-047 | The system shall validate online PIN where required by transaction type, POS entry mode, network, product, and issuer rules. |
| FAS-FR-048 | The system shall maintain or reference PIN try counter rules and decline transactions with invalid PIN or exceeded try limits. |
| FAS-FR-049 | The system shall validate CVV1 for magstripe transactions, CVV2 for card-not-present transactions, and iCVV where applicable. |
| FAS-FR-050 | The system shall return appropriate response codes for wrong PIN, CVV failure, cryptographic failure, and security validation errors. |
| FAS-FR-051 | The system shall not store clear PIN, clear PIN block, CVV, or sensitive cryptographic material in logs or application data stores. |

### 9.11 EMV and Chip Processing

| ID | Requirement |
| --- | --- |
| FAS-FR-052 | The system shall parse EMV data from ISO 8583 DE55 and scheme-specific EMV containers. |
| FAS-FR-053 | The system shall support key EMV tags including ARQC, TVR, IAD, ATC, AIP, CVM results, transaction date, amount, and application identifiers. |
| FAS-FR-054 | The system shall validate ARQC through HSM using PAN, ATC, transaction data, issuer keys, and EMV cryptographic rules. |
| FAS-FR-055 | The system shall evaluate TVR, TSI, CVM result, ATC, IAD, fallback indicators, and terminal risk indicators as part of the authorization decision. |
| FAS-FR-056 | The system shall generate ARPC for approved or configured declined EMV transactions where issuer authentication is required. |
| FAS-FR-057 | The system shall support issuer scripts for card blocking, parameter updates, and other issuer-approved chip commands. |
| FAS-FR-058 | The system shall decline or refer EMV transactions when cryptographic validation fails, chip data is missing, fallback is not allowed, or risk rules require action. |

### 9.12 Network Processing

| ID | Requirement |
| --- | --- |
| FAS-FR-059 | The system shall support Visa authorization processing, including dual-message and single-message flows where applicable. |
| FAS-FR-060 | The system shall support Mastercard authorization processing, including Banknet/MIP/CIS-aligned processing where applicable. |
| FAS-FR-061 | The system shall support ATM network processing for cash withdrawal, balance inquiry, reversal, and domestic/shared network flows. |
| FAS-FR-062 | The system shall support domestic network processing with issuer-specific routing, field mapping, response code mapping, and settlement behavior. |
| FAS-FR-063 | The system shall support network-specific response code translation between internal, ISO, Visa, Mastercard, ATM, and domestic codes. |

### 9.13 Authorization Decision Engine

| ID | Requirement |
| --- | --- |
| FAS-FR-064 | The system shall evaluate authorization rules in a deterministic and configurable decision sequence. |
| FAS-FR-065 | The system shall combine card validation, account validation, product controls, limit checks, risk checks, security validation, and network rules into a final decision. |
| FAS-FR-066 | The system shall support final decisions including approve, decline, partial approve, refer, capture, pickup, and stand-in approve/decline. |
| FAS-FR-067 | The system shall support override logic where issuer-approved configuration permits exceptions. |
| FAS-FR-068 | The system shall record the decision path, failed rule, response code, and approval code for each processed authorization. |

### 9.14 Response Code Framework

| ID | Requirement |
| --- | --- |
| FAS-FR-069 | The system shall maintain internal response codes and map them to network response codes. |
| FAS-FR-070 | The system shall support common response outcomes such as approved, do not honor, insufficient funds, expired card, transaction not permitted, wrong PIN, limit exceeded, suspected fraud, restricted card, and system malfunction. |
| FAS-FR-071 | The system shall generate approval codes for approved authorizations according to issuer and network rules. |
| FAS-FR-072 | The system shall preserve original response information for reversals, completions, clearing match, and support research. |

### 9.15 Stand-In Processing

| ID | Requirement |
| --- | --- |
| FAS-FR-073 | The system shall support stand-in processing when CMS, issuer services, processor services, or connectivity are unavailable. |
| FAS-FR-074 | The system shall support local, issuer, processor, and network stand-in rules as configured. |
| FAS-FR-075 | The system shall apply emergency limits, floor limits, product restrictions, card status, hot card checks, risk rules, and fallback controls during stand-in processing. |
| FAS-FR-076 | The system shall record all stand-in decisions for later reconciliation and issuer review. |
| FAS-FR-077 | The system shall restrict high-risk transactions during stand-in processing based on issuer configuration. |

### 9.16 Reversals

| ID | Requirement |
| --- | --- |
| FAS-FR-078 | The system shall process full and partial authorization reversals. |
| FAS-FR-079 | The system shall identify the original authorization using original data elements, approval code, amount, date/time, network reference, merchant, and terminal data. |
| FAS-FR-080 | The system shall release or reduce pending authorization holds based on reversal amount and matching rules. |
| FAS-FR-081 | The system shall handle unmatched reversals through configured exception logic. |
| FAS-FR-082 | The system shall detect and prevent duplicate reversal processing. |

### 9.17 Incremental Authorizations and Completions

| ID | Requirement |
| --- | --- |
| FAS-FR-083 | The system shall support incremental authorizations for hotel, car rental, restaurant, fuel, and other merchant categories configured for incremental processing. |
| FAS-FR-084 | The system shall increase, reduce, or replace pending holds based on incremental authorization rules. |
| FAS-FR-085 | The system shall process completion messages that finalize or adjust previously approved authorizations. |
| FAS-FR-086 | The system shall support authorization amount, completion amount, tolerance, partial completion, and multiple completion scenarios. |
| FAS-FR-087 | The system shall detect unmatched, duplicate, excessive, and expired completion scenarios and route exceptions appropriately. |

### 9.18 Duplicate Detection

| ID | Requirement |
| --- | --- |
| FAS-FR-088 | The system shall detect duplicate authorization requests caused by network retries, timeouts, merchant repeats, or host resubmissions. |
| FAS-FR-089 | The system shall compare configurable matching keys including PAN, amount, merchant, terminal, STAN, RRN, transaction date/time, approval code, and network reference. |
| FAS-FR-090 | The system shall return the original decision where duplicate replay handling is configured. |
| FAS-FR-091 | The system shall detect duplicate reversals, duplicate completions, duplicate clearing records, and duplicate posting records. |

### 9.19 Clearing Match and Settlement Interaction

| ID | Requirement |
| --- | --- |
| FAS-FR-092 | The system shall provide authorization data required for clearing match. |
| FAS-FR-093 | The system shall match clearing records to authorizations using approval code, PAN/token, amount, merchant, terminal, network reference, transaction date, and other configured keys. |
| FAS-FR-094 | The system shall support matched clearing, unmatched clearing, expired authorization, forced posting, partial clearing, multiple clearing, and amount-difference scenarios. |
| FAS-FR-095 | The system shall support tolerance rules for clearing amounts that differ from authorization amounts. |
| FAS-FR-096 | The system shall release, adjust, or expire authorization holds after clearing match and posting handoff. |
| FAS-FR-097 | The system shall support settlement file control totals, reconciliation totals, and exception reporting. |

### 9.20 FAS-to-CMS Posting Interface

| ID | Requirement |
| --- | --- |
| FAS-FR-098 | The system shall generate or provide data for financial transaction records based on clearing, completion, reversal, fee, interest, refund, and adjustment events as applicable. |
| FAS-FR-099 | The system shall assign transaction codes based on transaction type, MCC, channel, cash-equivalent treatment, debit/credit indicator, and product rules. |
| FAS-FR-100 | The system shall distinguish authorization holds from CMS financial postings. |
| FAS-FR-101 | The system shall support batch posting and near real-time posting interface patterns. |
| FAS-FR-102 | The system shall validate posting data including account, amount, currency, transaction code, debit/credit indicator, transaction date, posting date, merchant, and network reference. |
| FAS-FR-103 | The system shall route invalid or duplicate posting data to posting exception handling. |
| FAS-FR-104 | The system shall preserve data required by CMS for balances, interest, fees, billing, statement display, accounting, and general ledger mapping. |

### 9.21 Authorization History and Research

| ID | Requirement |
| --- | --- |
| FAS-FR-105 | The system shall store authorization history for approved, declined, referred, reversed, timed-out, stand-in, and exception transactions. |
| FAS-FR-106 | Authorization history shall include card/account references, transaction amount, currency, merchant, MCC, terminal, network, response code, approval code, date/time, decision reason, and message identifiers. |
| FAS-FR-107 | Authorization history shall support duplicate detection, fraud review, clearing match, customer dispute research, operational investigation, and audit. |

## 10. Data Requirements

### 10.1 Internal Data Stores

| Data Store | Purpose |
| --- | --- |
| Card Authorization File (CAF) | Card-level authorization data such as PAN, expiry, status, product, block codes, PIN flags, and fraud indicators. |
| Account Authorization File (AAF) | Account-level authorization data such as account status, credit limit, available credit, delinquency, and charge-off indicators. |
| Card-to-Account Cross Reference | Maps PAN, token, virtual card, or supplementary card to account relationship. |
| Authorization History | Stores processed authorization events for matching, research, fraud, duplicate detection, and audit. |
| Pending Authorization File | Stores active memo holds and pending authorization records. |
| Velocity File | Stores real-time transaction counters and amount totals. |
| Hot Card File | Stores lost, stolen, blocked, and fraud card records. |
| Fraud/Risk Files | Stores risk scores, fraud flags, country risk, merchant risk, and behavioral indicators. |
| Stand-In File | Stores fallback and emergency authorization parameters. |
| Control Files | Stores response code tables, product rules, country tables, MCC tables, risk parameters, and network mappings. |
| Clearing/Matching File | Stores authorization-to-clearing linkage and match outcomes. |
| Posting Interface File | Stores records generated or prepared for CMS financial posting. |

### 10.2 Data Access Requirements

| ID | Requirement |
| --- | --- |
| FAS-DR-001 | Authorization-critical data stores shall support direct low-latency lookup by PAN, token, account, merchant, or configured authorization key. |
| FAS-DR-002 | Card and account lookups shall complete within the authorization processing latency budget. |
| FAS-DR-003 | Pending hold, velocity, hot card, and authorization history updates shall be transactionally consistent for authorization decision purposes. |
| FAS-DR-004 | Data synchronization from CMS and control systems shall prevent inconsistent card/account decisions. |
| FAS-DR-005 | The system shall support recovery and rebuild procedures for authorization files after failure, corruption, or disaster recovery activation. |

## 11. Interface Requirements

### 11.1 External Interfaces

| Interface | Direction | Purpose |
| --- | --- | --- |
| Visa | Inbound/Outbound | Authorization request/response, advice, reversal, and scheme data exchange. |
| Mastercard | Inbound/Outbound | Authorization request/response, advice, reversal, and scheme data exchange. |
| ATM Network | Inbound/Outbound | ATM withdrawal, balance inquiry, reversal, and domestic/shared ATM authorization. |
| Domestic Switch | Inbound/Outbound | Local network card transaction processing. |
| HSM | Request/Response | PIN, CVV, EMV ARQC/ARPC, and key-related cryptographic services. |
| CMS | Inbound/Outbound | Account/card data synchronization, posting handoff, and exception resolution support. |
| Fraud Engine | Request/Response or File/Event | Real-time risk score, fraud rule evaluation, and risk flags. |
| Settlement/Clearing | Inbound/Outbound | Clearing match, completion, settlement, and posting preparation. |
| Operations/Monitoring | Outbound | Metrics, alerts, logs, traces, and exception events. |

### 11.2 Interface Requirements

| ID | Requirement |
| --- | --- |
| FAS-IR-001 | The system shall support network-specific message formats and mapping to internal authorization structures. |
| FAS-IR-002 | The system shall support configurable timeout handling for each external interface. |
| FAS-IR-003 | The system shall support retry, failover, and duplicate-safe behavior for network, HSM, fraud, and posting interfaces. |
| FAS-IR-004 | The system shall produce interface logs and correlation IDs for every inbound and outbound message. |
| FAS-IR-005 | The system shall protect sensitive fields in logs, traces, support screens, and reports. |

## 12. Security Requirements

| ID | Requirement |
| --- | --- |
| FAS-SR-001 | The system shall comply with applicable payment security requirements for PAN, PIN, CVV, EMV, cryptographic keys, and sensitive authentication data. |
| FAS-SR-002 | The system shall use HSM services for cryptographic operations and shall not expose cryptographic keys to application code or logs. |
| FAS-SR-003 | The system shall mask or tokenize PAN wherever full PAN is not operationally required. |
| FAS-SR-004 | The system shall not persist CVV, clear PIN, clear PIN block, or prohibited sensitive authentication data. |
| FAS-SR-005 | The system shall enforce role-based access to authorization inquiry, configuration, support, and operational functions. |
| FAS-SR-006 | The system shall maintain audit logs for configuration changes, rule updates, manual exception handling, and access to sensitive transaction data. |
| FAS-SR-007 | The system shall support secure communication channels for network, HSM, CMS, fraud, and operational interfaces. |

## 13. Non-Functional Requirements

### 13.1 Performance

| ID | Requirement |
| --- | --- |
| FAS-NFR-001 | The system shall process authorization decisions within the issuer-defined latency target under normal and peak load. |
| FAS-NFR-002 | The target internal authorization decision time should support sub-second processing and be suitable for end-to-end network response expectations of approximately 1 to 3 seconds. |
| FAS-NFR-003 | The system shall support peak TPS sizing based on issuer portfolio volume, network traffic, retry behavior, and seasonal peaks. |
| FAS-NFR-004 | Authorization file lookups, HSM calls, risk evaluation, and response generation shall be monitored individually for latency contribution. |

### 13.2 Availability and Resilience

| ID | Requirement |
| --- | --- |
| FAS-NFR-005 | The system shall support high availability suitable for issuer authorization operations, with a target of 99.99% or higher where required by business SLA. |
| FAS-NFR-006 | The system shall support active/active or active/passive deployment patterns based on issuer architecture. |
| FAS-NFR-007 | The system shall support disaster recovery with replicated authorization-critical files and tested failover procedures. |
| FAS-NFR-008 | The system shall support graceful degradation and stand-in processing during dependency outage. |
| FAS-NFR-009 | The system shall recover without double approving, double reversing, double completing, or double posting transactions. |

### 13.3 Scalability

| ID | Requirement |
| --- | --- |
| FAS-NFR-010 | The system shall scale to support millions of daily transactions and issuer-defined peak authorization traffic. |
| FAS-NFR-011 | The system shall support volume growth across cards, accounts, tokens, authorization history, pending holds, velocity counters, and control tables. |
| FAS-NFR-012 | The system shall support capacity planning for CPU, memory, file I/O, HSM throughput, network I/O, storage, and replication. |

### 13.4 Observability

| ID | Requirement |
| --- | --- |
| FAS-NFR-013 | The system shall provide monitoring for TPS, approval rate, decline rate, response time, timeout rate, error rate, HSM latency, file lookup latency, and interface availability. |
| FAS-NFR-014 | The system shall provide decision tracing for support investigation, including evaluated rule, failed validation, response code, and data source. |
| FAS-NFR-015 | The system shall provide operational dashboards and alerts for authorization degradation, dependency failure, settlement mismatch, and exception queue growth. |

### 13.5 Audit and Compliance

| ID | Requirement |
| --- | --- |
| FAS-NFR-016 | The system shall retain authorization logs and history according to issuer retention policy and regulatory requirements. |
| FAS-NFR-017 | The system shall support audit review of authorization configuration changes and operational interventions. |
| FAS-NFR-018 | The system shall provide traceability from authorization request to response, memo hold, clearing match, posting record, and exception outcome. |

## 14. Operational Requirements

| ID | Requirement |
| --- | --- |
| FAS-OR-001 | Operations teams shall be able to monitor authorization traffic volume, response latency, timeouts, decline spikes, and dependency health. |
| FAS-OR-002 | Support teams shall be able to investigate authorization failures using card/account lookup, message field analysis, decision trace, response code, and rule evaluation. |
| FAS-OR-003 | The system shall provide exception queues for unmatched clearing, duplicate events, posting failures, reversal mismatches, expired holds, and authorization file errors. |
| FAS-OR-004 | The system shall support operational reports for declined transactions, approvals, stand-in events, high-risk decisions, HSM failures, and network errors. |
| FAS-OR-005 | The system shall support controlled configuration updates for products, limits, countries, MCCs, response codes, velocity rules, fraud rules, and stand-in rules. |

## 15. Exception Handling Requirements

| ID | Requirement |
| --- | --- |
| FAS-EH-001 | The system shall route authorization failures caused by missing card, missing account, invalid data, file error, HSM error, or network timeout to appropriate response handling and logging. |
| FAS-EH-002 | The system shall support suspense or manual review queues for clearing, posting, matching, and reconciliation exceptions. |
| FAS-EH-003 | The system shall prevent inconsistent balance impact when reversals, completions, clearing records, or posting records fail. |
| FAS-EH-004 | The system shall preserve enough transaction data for manual investigation and correction. |

## 16. Configuration Requirements

The system shall provide controlled configuration for:

- Product and logo authorization controls.
- Card/account block and status handling.
- Credit, cash, daily, transaction, overlimit, and tolerance limits.
- Velocity counters and windows.
- MCC and merchant restrictions.
- Country and regional restrictions.
- Fraud and risk parameters.
- EMV validation and fallback rules.
- PIN/CVV validation requirements.
- Response code mapping.
- Stand-in and emergency processing rules.
- Hold expiry and release rules.
- Clearing match tolerance.
- Posting transaction-code mapping.

## 17. Reporting Requirements

| ID | Requirement |
| --- | --- |
| FAS-RR-001 | The system shall provide authorization summary reporting by date, network, product, response code, channel, country, MCC, and merchant category. |
| FAS-RR-002 | The system shall provide decline analysis reporting by reason, response code, rule, product, and channel. |
| FAS-RR-003 | The system shall provide stand-in reporting including approved, declined, and restricted transactions. |
| FAS-RR-004 | The system shall provide pending authorization and expired hold reporting. |
| FAS-RR-005 | The system shall provide clearing match, unmatched clearing, duplicate clearing, and posting exception reporting. |
| FAS-RR-006 | The system shall provide fraud/risk decision reporting for tuning and investigation. |

## 18. Testing Requirements

Testing shall cover:

- ISO 8583 parsing, field mapping, and response generation.
- Visa, Mastercard, ATM, domestic, and digital wallet authorization cases.
- Card validation, account validation, product controls, and relationship validation.
- Available credit, cash limit, overlimit, tolerance, and partial approval scenarios.
- Memo hold creation, release, expiry, reversal, completion, and clearing adjustment.
- Velocity, MCC, geographic, fraud, and merchant controls.
- PIN, CVV, EMV ARQC validation, ARPC generation, and issuer scripts.
- Stand-in processing under CMS, HSM, issuer, processor, or network failure.
- Duplicate authorization, duplicate reversal, duplicate completion, and duplicate clearing.
- Matched, unmatched, partial, multiple, expired, and forced clearing.
- Posting interface validation and exception handling.
- Performance, failover, disaster recovery, and operational monitoring.

## 19. Acceptance Criteria

The FAS system shall be considered acceptable when:

1. It can receive, parse, validate, decide, and respond to supported authorization messages within the agreed service-level target.
2. It correctly approves eligible transactions and declines or refers ineligible transactions based on configured rules.
3. It correctly maintains pending authorizations, shadow balances, velocity counters, and authorization history.
4. It correctly validates PIN, CVV, and EMV cryptograms through HSM integration.
5. It correctly handles reversals, incrementals, completions, duplicate events, and stand-in scenarios.
6. It provides clearing match and posting interface data required for CMS financial lifecycle processing.
7. It provides auditable decision traces, operational monitoring, and exception handling.
8. It passes network certification, regression testing, performance testing, failover testing, and security review.

## 20. Traceability Matrix

| Source Topic | Requirement Areas |
| --- | --- |
| FAS Architecture Overview | System context, objectives, FAS vs CMS, high-level flow, availability. |
| FAS Components & Internal Modules | Gateway, parser, card/account/product engines, rules engine, memo posting, response generation. |
| FAS Data Structures | CAF, AAF, pending authorization, shadow balance, authorization history, velocity, hot card, control files. |
| End-to-End Authorization Flow | Functional authorization processing lifecycle. |
| ISO 8583 Processing | Message parsing, field mapping, network response construction. |
| Authorization Decision Tree | Decision engine, response code framework, rule sequencing. |
| Card & Account Validation | Card validation, account validation, relationship validation. |
| Limit Management | Available credit, memo holds, cash limits, daily limits, overlimit processing. |
| Risk & Fraud Controls | Velocity, geography, MCC, fraud scoring, behavioral rules. |
| EMV & Chip Processing | DE55, ARQC, ARPC, EMV tags, issuer scripts, fallback controls. |
| Network Processing | Visa, Mastercard, ATM, domestic network support. |
| STIP | Stand-in processing and fallback rules. |
| Reversals & Exceptions | Reversals, incrementals, completions, duplicate detection, exception queues. |
| Settlement Interaction | Authorization vs clearing, match logic, unmatched transactions, forced posting. |
| FAS-CMS Posting Interface | FTR generation, transaction codes, posting validation, GL/accounting handoff. |
| Operations & Support | Monitoring, debugging, decision trace, support queues. |
| Advanced Architecture | HA, DR, performance, scalability, digital extensions. |

## 21. Open Items for Business and Architecture Review

- Confirm exact supported networks and message variants for the implementation.
- Confirm issuer-specific response code mappings.
- Confirm latency, TPS, availability, and disaster recovery targets.
- Confirm whether authorization data stores are VSAM-based, database-based, cache-based, or hybrid.
- Confirm integration style for fraud engine and CMS synchronization.
- Confirm detailed product, MCC, geography, velocity, and stand-in rules.
- Confirm retention period for authorization history and audit logs.
- Confirm network certification scope and test simulators.
- Confirm PCI, key-management, and HSM operational requirements.

## 22. Appendix A: Common Authorization Response Examples

| Response | Meaning |
| --- | --- |
| 00 | Approved. |
| 05 | Do not honor. |
| 51 | Insufficient funds or available credit. |
| 54 | Expired card. |
| 55 | Incorrect PIN. |
| 57 | Transaction not permitted to cardholder. |
| 61 | Exceeds withdrawal or amount limit. |
| 62 | Restricted card. |
| 91 | Issuer or switch inoperative. |
| 96 | System malfunction. |

## 23. Appendix B: Typical Internal Lookup Flow

```text
Incoming Authorization
        |
Message Parsing
        |
CAF Lookup
        |
Card-to-Account Cross Reference
        |
AAF Lookup
        |
Hot Card / Block Check
        |
Product and Relationship Controls
        |
PIN / CVV / EMV / HSM Validation
        |
Limit and Shadow Balance Evaluation
        |
Velocity / MCC / Country / Fraud Evaluation
        |
Authorization Decision
        |
History, Hold, and Counter Update
        |
Response Generation
```

## 24. Appendix C: End-to-End Financial Lifecycle

```text
Authorization Request
        |
FAS Decision
        |
Memo Hold / Pending Authorization
        |
Clearing Record
        |
Authorization Match
        |
Financial Transaction Record
        |
Posting Interface
        |
CMS Ledger Update
        |
Billing / Interest / Statement / GL
```

