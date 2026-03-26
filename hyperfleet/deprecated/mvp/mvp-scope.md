---
Status: Historical
Owner: HyperFleet Leadership
Last Updated: 2026-03-25
---

# HyperFleet MVP Scope

> Documents the approved MVP scope for HyperFleet as of October 31, 2024, including the core components in scope, features explicitly excluded, and the success criteria for the MVP release. This document is historical — the MVP phase is complete. Use post-MVP planning documents and current JIRA epics for active scope.

---

**Date**: October 31, 2024
---
Status: Approved
---

**Source**: Leadership Presentation

---

## Executive Summary

Leadership has approved the HyperFleet MVP with the following key decisions:
- **Timeline**: 12-week handover-ready MVP 
- **Cloud Provider**: GCP for MVP
- **Scope**: Full platform foundation with production-ready quality 

---

## Timeline (12 Weeks) 

**APPROVED: 12-week timeline for handover-ready platform**

### What We're Building
A **handover-ready platform** (not a prototype) that includes:
- Complete platform foundation (API, Sentinels, adapters, message broker)
- Cluster creation capability (clusters + node pools)
- Production-ready quality (tests, observability, CI/CD, documentation)
- Handover package (training, documentation, support plan)

### What This Means
- **Weeks 1-12**: Build handover-ready MVP with cluster creation capability
- **Week 13+**: Post-handover iteration by team
  - Full CRUD support (updates, deletion, patching)
  - Additional cloud providers (AWS FedRamp, etc.)
  - BU-specific features
  - Advanced capabilities (IDPs, autoscalers, etc.)

### Why 12 Weeks?
This is a **distributed system with 7+ services**, not a single application:
- API Service 
- 2 Sentinel deployments 
- Message broker integration 
- Adapter service framework
- 5+ cloud-specific adapters
- Testing, observability, documentation 

### Suggested Milestones for MVP Delivery

These milestones represent the suggested phases for delivering the MVP

#### Milestone 1: Foundation
**Deliverables**:
- API service operational (clusters + node pools)
- Database schema deployed
- Message broker deployed
- Adapter service framework complete
- One working adapter (end-to-end validation)
- CI pipeline operational

**Success Criteria**: Foundation working, architecture validated

#### Milestone 2: Core Implementation
**Deliverables**:
- Both Sentinels operational (cluster + node pool)
- All 5 cluster adapters implemented
- Node pool adapters implemented
- Integration tests passing
- Observability stack deployed (Prometheus, Grafana)
- E2E test framework operational

**Success Criteria**: Full cluster provisioning working end-to-end

#### Milestone 3: Handover Readiness
**Deliverables**:
- CI/CD pipeline complete (Prow)
- Documentation complete (API, runbooks, architecture)
- Security scanning and hardening
- Load testing and performance validation
- Handover documentation and training

**Success Criteria**: Ready for GCP team handover

#### Milestone 4: Post-Handover Iteration
**Focus Areas**:
- Full CRUD support (cluster and node pool updates, deletion, patching)
- Additional cloud providers (AWS FedRamp, other providers)
- BU-specific features (custom requirements from business units)
- Advanced capabilities (IDPs, autoscalers, cost tracking, templates)
- Support and iteration with GCP team on production issues and enhancements

**Success Criteria**: Continuous delivery of enhancements and multi-cloud expansion

---

## MVP Scope Alignment 

**APPROVED: handover-ready platform foundation**

### Core Platform Components

#### 1. HyperFleet API Service
**Scope**:
- Cluster lifecycle API (create, read, status)
- Node Pool lifecycle API (create, read, status)
- Status aggregation across all adapters
- REST API with OpenAPI specification
- Database schema and migrations

**Why This Scope**:
- Clusters AND node pools = complete resource model
- Status aggregation = core orchestration capability
- Both resources share same patterns = validate architecture thoroughly


---

#### 2. Sentinel Service
**Scope**:
- Cluster Sentinel (monitors cluster resources)
- Node Pool Sentinel (monitors node pool resources)
- CloudEvent generation and publishing
- Sharding support for scale
- Config-driven deployment

**Why Both Sentinels**:
- Validates sentinel pattern works for multiple resource types
- Tests sharding logic under realistic load
- Proves config-driven approach is reusable

**Key Design Features**:
- **Multiple Sentinels**: One per resource type (clusters, node pools)
- **Sharding**: Distributes load across sentinel instances to prevent API overload
- **Config-Driven**: Resource-agnostic framework reusable for all resource types
- **Max Age Strategies**: Different polling intervals for Ready vs Not Ready resources

---

#### 3. Message Broker Abstraction Layer
**Scope**:
- Abstraction layer for messaging patterns
- RabbitMQ for local development
- GCP Pub/Sub for production
- Fanout pattern implementation
- Dead-letter queue support

**Why Abstraction Layer**:
- Enables cloud provider flexibility
- Can switch messaging patterns without code changes
- Supports both GCP (Pub/Sub) and RabbitMQ equally
- Future-proof for messaging strategy evolution


**MVP Messaging Strategy**:
- Fanout pattern: Sentinel publishes, all adapters subscribe
- Each adapter receives every event and decides if it should act
- Simple, parallel execution, loose coupling

---

#### 4. Config-Driven Adapter Service
**Scope**:
- Single binary adapter service
- Configuration schema (preconditions, postconditions, templates)
- Multi-resource type support (clusters, node pools, etc.)
- Kubernetes resource lifecycle management
- Status reporting framework
- Retry and error handling
- Horizontal scaling support

**Why Config-Driven**:
- Build once, reuse for every adapter
- Cloud-agnostic implementation
- Extensible through configuration alone
- No code changes needed for new cloud providers

**Key Capabilities**:
- **Single Binary**: One adapter service, infinite configurations
- **Multi-Resource**: Handles clusters, node pools, any future resource type
- **K8s Lifecycle**: Creates and manages Jobs, Deployments, StatefulSets, ConfigMaps
- **Scale**: Handles high message volume from fanout pattern with horizontal scaling

---

#### 5. GCP Cluster Adapters (5 Adapters)
**Scope**: ~5 adapters for GCP cluster provisioning
1. **Validation Adapter** - Check GCP prerequisites
2. **DNS Adapter** - Create Cloud DNS records
3. **Placement Adapter** - Select region and management cluster
4. **Pull Secret Adapter** - Store credentials in Secret Manager
5. **HyperShift Adapter** - Create HostedCluster CR

**Additional**: Node pool adapters (count TBD)

**Per Adapter Requirements**:
- Configuration files (preconditions, postconditions, templates)
- GCP service integration and error handling
- Unit tests (80% coverage requirement)
- Integration tests (with GCP test environment)
- E2E tests (full cluster provisioning flow)
- Observability instrumentation (metrics, logs, traces)
- Documentation

**Why Each Adapter Takes Time**:
- Configuration is non-trivial (understanding full workflow)
- GCP integration has edge cases (quotas, rate limits, IAM issues)
- Testing requires real GCP environment
- Must be production-ready (handle all error cases, retries, timeouts)


---

### Production Readiness Requirements

#### Testing
- **Unit Tests**: Individual component testing
- **Integration Tests**: Multiple components with mocked externals
- **E2E Tests**: Full system with real GCP

#### Observability
- **Metrics**: Prometheus metrics for all components
- **Dashboard**:  Single Grafana dashboard for monitoring
- **Alerts**: Critical alert definitions
- **Logs**: Structured logging across all services

#### CI/CD
- **Helm Chart**: Deployment automation
- **Automated testing**: All tests run in CI
- **Security scanning**: Automated vulnerability scanning

#### Documentation
- **API Documentation**: OpenAPI specs, usage guides
- **Runbooks**: Operational procedures, troubleshooting guides
- **Architecture Documentation**: System design, component interactions
- **Training Materials**: Handover documentation for GCP team


---

### What's NOT in MVP Scope

These capabilities are deferred to **post-handover iteration (Week 13+)**:

#### Deferred Features
- **Full CRUD Operations**: Cluster/node pool updates, deletion, patching
- **Multiple Cloud Providers**: AWS FedRamp, other providers
- **Advanced Features**: IDPs, autoscalers, cost tracking, templates
- **BU-Specific Customizations**: Custom requirements from business units

**Why Deferred**:
- Validate architecture with single cloud first
- Deliver handover-ready foundation faster
- Learn from production usage before expanding
- GCP team continues iteration post-handover

---

## Architecture Principles

### 1. Event-Driven Design
- Loose coupling between components
- Parallel execution (adapters run simultaneously)
- Fault isolation (one adapter failure doesn't cascade)
- Easy to add/remove/modify adapters

### 2. Cloud-Agnostic Foundation
- API design independent of cloud provider
- Message broker abstraction supports multiple providers
- Adapter framework works for any cloud
- Config-driven approach eliminates code changes for new clouds

### 3. Production-Ready from Day One
- Comprehensive error handling
- Tests, observability, documentation included
- Secure, scalable, maintainable
- Can be operated and supported
- Foundation for the future (build on it, not throw it away)


---

## Risks and Mitigations

### High-Risk Areas
1. **Adapter failure and retry strategy** - Addressed with comprehensive config-driven retry logic
2. **Concurrent event handling** - Mitigated with horizontal scaling architecture
3. **Status condition schema** - Design validated early in foundation phase
4. **Database performance** - Upfront schema design and optimization 
5. **Configuration management** - Config-driven approach with validation

### Mitigation Strategy
- **Milestone checkpoints** at Weeks 4, 8, 12 with go/no-go decisions
- **2-week buffer** built into timeline
- **Parallel development** where possible (adapters, testing)
- **Early validation** of critical patterns (foundation phase)

---

## Commitments

### What We Commit To
- Handover-ready platform in 12 weeks (cluster creation capability)
- Milestone checkpoints with go/no-go decisions (Weeks 4, 8, 12)
- Cloud-agnostic foundation enabling rapid multi-cloud expansion
- Smooth handover to GCP team with full documentation and training
- Post-handover: Continue iteration on full CRUD, additional clouds, BU features
- Transparency on progress, risks, and blockers
- Protection from scope creep during 12-week foundation phase
- Support for quality-first approach

