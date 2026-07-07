# Card & Payments Platform Comparison — Way4 / VisionPLUS / Prime / PowerCARD / momentPay

Base table: `Way4-VisionPlus-Prime-PowerCARD.txt` (as provided). Added: a **Business Domain** column, a **momentPay** column, and a **% Match** column.

**Business Domain** groups each row under: Card, Issuing, Merchant Acquiring, Payment Switching, Authorization, Merchant Management, Terminal Management, Fraud, Loyalty, Tokenization, Wallet, Digital Banking, Clearing, Settlement, Pricing, Dispute, Reconciliation (list as requested). 12 rows are pure infrastructure/architecture capabilities that don't map cleanly to any of those business domains (e.g., Cloud Native, Microservices, Scalability) — these are tagged **Platform/Architecture** rather than forced into a business-domain label; flagged in the caveats below.

**% Match methodology:** a directional estimate of how completely momentPay's current, documented build covers each row — based on `IssuingPlatfrom.md.txt` (E-VisionPlus issuing platform), `Intial-Write-up.txt` (ecosystem components), `way-momentpay-wallet-gap.txt` (detailed wallet gap analysis), `Way-4-Product_and_momentPay.txt` (architecture notes), and clarifications provided during this review (live APMs, merchant hierarchy, benchmark data, ISO 27001, etc.). **This is not a certified benchmark or third-party audit** — treat it as a working estimate to sanity-check and correct.

| Feature / Capability | Business Domain | Way4 | VisionPLUS | Prime | PowerCARD | momentPay | % Match |
| --- | --- | :---: | :---: | :---: | :---: | :---: | :---: |
| Credit Card Issuing | Issuing | ✅ | ✅ | ✅ | ✅ | ✅ Native (VisionPlus-parity) | 95% |
| Debit Card Issuing | Issuing | ✅ | ✅ | ✅ | ✅ | Missing | 10% |
| Prepaid Cards | Card | ✅ | ✅ | ✅ | ✅ | Partial (in progress) | 40% |
| Virtual Cards | Card | ✅ | Limited | ✅ | ✅ | Partial | 45% |
| Corporate Cards | Card | ✅ | ✅ | ✅ | ✅ | Missing (roadmap) | 10% |
| Fleet Cards | Card | ✅ Native | Limited | Limited | ✅ | Missing | 0% |
| BNPL | Issuing | ✅ Native | Extension | Extension | ✅ | Partial (EMI only, no merchant BNPL) | 30% |
| Tokenized Cards | Tokenization | ✅ | Extension | ✅ | ✅ | Missing | 10% |
| Digital Wallet | Wallet | ✅ Native | Integration | Integration | ✅ | Partial (11/14 areas built) | 60% |
| Apple Pay / Google Pay | Tokenization | ✅ | Integration | ✅ | ✅ | Missing | 5% |
| QR Payments | Payment Switching | ✅ | Limited | Limited | ✅ | Partial (merchant QR live, scan-to-pay pending) | 55% |
| Instant Payments | Payment Switching | ✅ | Limited | Limited | ✅ | Partial (UAE Open Finance live, payout pending) | 45% |
| Account-to-Account (A2A) | Payment Switching | ✅ | No | Partial | Partial | Partial (virtual IBAN inbound only) | 40% |
| Merchant Acquiring | Merchant Acquiring | ✅ | Limited | Partial | ✅ | ✅ | 80% |
| Payment Switching | Payment Switching | ✅ | TRAMS/FAS based | Partial | ✅ | Partial (H2H certification pending) | 55% |
| ATM Switching | Payment Switching | ✅ | Partial | Partial | ✅ | Missing | 5% |
| POS Switching | Payment Switching | ✅ | Partial | Partial | ✅ | ✅ | 85% |
| ISO8583 Support | Payment Switching | ✅ | ✅ | ✅ | ✅ | Partial (dialect coverage in progress) | 70% |
| ISO20022 | Payment Switching | ✅ | Limited | Limited | ✅ | Limited | 25% |
| Card Authorization Engine | Authorization | ✅ | FAS | ✅ | ✅ | ✅ | 95% |
| Clearing | Clearing | ✅ | CMS/TRAMS | ✅ | ✅ | ✅ | 85% |
| Settlement | Settlement | ✅ | CMS | ✅ | ✅ | ✅ | 85% |
| Chargeback Management | Dispute | ✅ | Basic | ✅ | ✅ | ✅ (scheme reason codes pending) | 75% |
| Dispute Management | Dispute | ✅ | Basic | ✅ | ✅ | ✅ | 85% |
| Merchant Management | Merchant Management | ✅ | Limited | Partial | ✅ | ✅ | 80% |
| Terminal Management (TMS) | Terminal Management | Partial | No | No | ✅ | ✅ | 85% |
| Risk Engine | Fraud | Advanced | Basic | Advanced | Advanced | Good (not fully inline on auth path) | 65% |
| Fraud Detection | Fraud | AI + Rules | Rules | Rules | AI + Rules | Rules (AI roadmap) | 50% |
| AML Integration | Fraud | ✅ | Via Integration | Via Integration | ✅ | ✅ | 85% |
| KYC | Fraud | ✅ | External | External | ✅ | Partial (instant eKYC/liveness pending) | 65% |
| Loyalty Engine | Loyalty | Advanced | Basic | Advanced | Advanced | Partial (points/offers live, no coupons/referrals) | 45% |
| Campaign Management | Loyalty | ✅ | Limited | Partial | ✅ | Partial / unclear (Aritic CRM status to confirm) | 35% |
| Pricing Engine | Pricing | Advanced | Good | Good | Advanced | Partial (Interchange++ pending) | 55% |
| Fee Management | Pricing | ✅ | ✅ | ✅ | ✅ | ✅ | 85% |
| Billing Engine | Issuing | ✅ | ✅ | ✅ | ✅ | ✅ | 90% |
| Interest Calculation | Issuing | ✅ | ✅ | ✅ | ✅ | ✅ | 90% |
| Collections | Issuing | Partial | CTA | Integrated | Integrated | Partial (delinquency tracking only) | 40% |
| Multi-Currency | Digital Banking | Unlimited | Good | Excellent | Excellent | Partial (sub-wallets live, no live FX feed) | 60% |
| Multi-Language | Digital Banking | ✅ | Limited | ✅ | ✅ | Unclear / not evidenced | 25% |
| Multi-Entity | Digital Banking | Unlimited | Good | Excellent | Excellent | Partial (merchant hierarchy only) | 45% |
| Multi-Tenant | Platform/Architecture | Native | No | Partial | Yes | Partial (isolated per-instance) | 35% |
| SaaS Deployment | Platform/Architecture | ✅ | Limited | Partial | ✅ | Partial | 35% |
| Cloud Native | Platform/Architecture | ✅ | Legacy | Hybrid | Hybrid | ✅ (Elixir/BEAM) | 90% |
| Microservices | Platform/Architecture | Mostly | No | Partial | Partial | ✅ (30+ modular apps) | 85% |
| API First | Platform/Architecture | Extensive | Limited | Good | Extensive | Good (REST layer shipping, coverage partial) | 65% |
| Event Driven | Platform/Architecture | ✅ | No | Partial | Partial | ✅ (actor-model architecture) | 80% |
| Workflow Engine | Digital Banking | Advanced | Limited | Good | Advanced | Partial (maker-checker exists, not generalized) | 45% |
| Business Rules Engine | Digital Banking | Excellent | Good | Excellent | Excellent | Good (policy engine, narrower than claimed 95%) | 55% |
| No-Code Configuration | Digital Banking | ~95% parameter-driven | Medium | Good | Good | Partial (many behaviors still code-defined) | 30% |
| AI Ready | Platform/Architecture | Native | No | Partial | Partial | Partial / aspirational (no live ML models yet) | 25% |
| Analytics Dashboard | Digital Banking | Advanced | Basic | Good | Advanced | Partial (reporting app, no BI warehouse) | 45% |
| Real-Time Processing | Platform/Architecture | 100% | Mostly | Mostly | 100% | ✅ | 90% |
| High Availability | Platform/Architecture | Active-Active | Yes | Yes | Active-Active | Good (DR readiness gating, Active-Active unconfirmed) | 65% |
| Scalability | Platform/Architecture | Very High | High | Very High | Very High | Benchmarked, not production-proven (1.3M-connection test vs. 100K txn/day live) | 50% |

---

## Reading the % Match Column

- **≥70% (19 rows):** core issuing (auth, clearing, settlement, disputes, billing, interest), merchant acquiring/management, POS switching, TMS, AML, cloud-native architecture, microservices, event-driven design, real-time processing. This is momentPay's genuine strength zone — largely matching or approaching the other four platforms.
- **40–69% (21 rows):** wallet, QR, instant payments, A2A, payment switching, ISO8583, risk/fraud, KYC, loyalty, pricing, multi-currency, multi-enti