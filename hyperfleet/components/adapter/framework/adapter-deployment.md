---
Status: Active
Owner: HyperFleet Adapter Team
Last Updated: 2026-01-02
---

# HyperFleet Adapter Framework - Deployment Guide

## Overview

This document describes how to deploy the HyperFleet Adapter Framework in Kubernetes.

**Related Documentation:**
- [Adapter Framework Design](./adapter-frame-design.md) - Architecture overview
- `adapter-config-template-MVP.yaml` - Configuration structure
- [Adapter Design Decisions](./adapter-design-decisions.md) - Architecture decisions
- [Logging Specification](../../../standards/logging-specification.md) - Logging configuration standards

---

## Table of Contents

1. [Deployment Pattern](#deployment-pattern)
2. [Helm Chart Structure](#helm-chart-structure)
3. [Configuration Loading](#configuration-loading)
4. [Service Account and RBAC](#service-account-and-rbac)
5. [Health and Readiness Probes](#health-and-readiness-probes)
6. [Metrics and Monitoring](#metrics-and-monitoring)
7. [Deployment Commands](#deployment-commands)
8. [Troubleshooting](#troubleshooting)

---

## Deployment Pattern

### Single Image, Multiple Configurations

**Architecture:**
- **One Image**: `quay.io/hyperfleet/adapter-framework:v1.0.0`
- **Multiple Deployments**: Validation, DNS, Placement adapters (same image)
- **Config-Driven**: Different ConfigMaps per adapter type
- **Helm-Managed**: Helm templates generate all resources

**Benefits:**
- ✅ Single binary to build/test/maintain
- ✅ Update adapter logic without rebuilding image
- ✅ Consistent behavior across adapters
- ✅ Easy rollback via Helm

**Configuration Layers:**
1. **Adapter Logic ConfigMap** (per adapter) - event filters, resources, post-processing
2. **Broker ConfigMap** (per environment) - broker connection
3. **Environment ConfigMap** (per environment) - API URL, basic settings
4. **Observability ConfigMap** (per environment) - logging, metrics, tracing
5. **Deployment env vars** (per adapter) - subscription name
6. **Secrets** (per environment) - API tokens

---

## Helm Chart Structure

### Repository Structure

```
hyperfleet-adapter/
├── charts/
│   ├── Chart.yaml
│   ├── values.yaml                      # Defaults
│   ├── values-dev.yaml                  # Dev overrides
│   ├── values-staging.yaml              # Staging overrides
│   ├── values-prod.yaml                 # Production overrides
│   └── templates/
│       ├── _helpers.tpl
│       ├── configmap-environment.yaml   # Environment config
│       ├── configmap-broker.yaml        # Broker config
│       ├── configmap-observability.yaml # Observability config
│       ├── configmap-adapter-*.yaml     # Adapter logic configs
│       ├── deployment-*.yaml            # Deployments per adapter
│       ├── service.yaml
│       ├── serviceaccount.yaml
│       ├── role.yaml
│       ├── rolebinding.yaml
│       └── servicemonitor.yaml
├── configs/
│   ├── validation-adapter.yaml
│   ├── dns-adapter.yaml
│   └── placement-adapter.yaml
└── Dockerfile
```

### Chart.yaml

```yaml
apiVersion: v2
name: hyperfleet-adapter
description: HyperFleet Adapter Framework
type: application
version: 1.0.0
appVersion: "1.0.0"
maintainers:
  - name: HyperFleet Team
```

### values.yaml (Defaults)

```yaml
global:
  imageRegistry: quay.io/hyperfleet
  namespace: hyperfleet-system

environment: production

image:
  repository: adapter-framework
  tag: "1.0.0"
  pullPolicy: IfNotPresent

hyperfleetApi:
  baseUrl: "http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080"
  version: "v1"

broker:
  type: "pubsub"
  pubsub:
    projectId: "my-gcp-project"
    subscriptionId: "hyperfleet-events"
  maxConcurrency: 100

observability:
  logLevel: "info"
  metricsPort: 9090
  healthPort: 8080
  traceEnabled: false
  traceEndpoint: "http://otel-collector.observability.svc.cluster.local:4317"
  traceSampleRate: "0.1"

adapters:
  validation:
    enabled: true
    replicas: 2
    subscriptionName: "validation-adapter-sub"
    configFile: "validation-adapter-config.yaml"
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
  
  dns:
    enabled: true
    replicas: 3
    subscriptionName: "dns-adapter-sub"
    configFile: "dns-adapter-config.yaml"
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi

rbac:
  create: true

serviceMonitor:
  enabled: true
  interval: 30s
```

### values-dev.yaml (Development)

```yaml
environment: development

image:
  tag: "latest"
  pullPolicy: Always

observability:
  logLevel: "debug"
  traceEnabled: true
  traceSampleRate: "1.0"

adapters:
  validation:
    replicas: 1
  dns:
    replicas: 1
```

### values-prod.yaml (Production)

```yaml
environment: production

image:
  tag: "1.0.0"

observability:
  logLevel: "warn"
  traceEnabled: true
  traceSampleRate: "0.1"

adapters:
  validation:
    replicas: 3
    resources:
      requests:
        cpu: 200m
        memory: 256Mi
      limits:
        cpu: 1000m
        memory: 1Gi
  dns:
    replicas: 5
    resources:
      requests:
        cpu: 200m
        memory: 256Mi
      limits:
        cpu: 1000m
        memory: 1Gi
```

### Helm Template Examples

**templates/deployment-validation.yaml:**
```yaml
{{- if .Values.adapters.validation.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "hyperfleet-adapter.fullname" . }}-validation
  namespace: {{ .Values.global.namespace }}
spec:
  replicas: {{ .Values.adapters.validation.replicas }}
  selector:
    matchLabels:
      app: hyperfleet-adapter
      adapter-type: validation
  template:
    metadata:
      labels:
        app: hyperfleet-adapter
        adapter-type: validation
    spec:
      serviceAccountName: {{ include "hyperfleet-adapter.serviceAccountName" . }}-validation
      terminationGracePeriodSeconds: 30
      containers:
        - name: adapter
          image: "{{ .Values.global.imageRegistry }}/{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args:
            - --config=/etc/adapter/config/adapter-config.yaml
          envFrom:
            - configMapRef:
                name: hyperfleet-environment
            - configMapRef:
                name: hyperfleet-broker-config
            - configMapRef:
                name: adapter-observability
          env:
            - name: SUBSCRIPTION_NAME
              value: {{ .Values.adapters.validation.subscriptionName }}
            - name: HYPERFLEET_API_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hyperfleet-api-token
                  key: token
          volumeMounts:
            - name: adapter-config
              mountPath: /etc/adapter/config
              readOnly: true
          ports:
            - name: metrics
              containerPort: {{ .Values.observability.metricsPort }}
              protocol: TCP
            - name: health
              containerPort: {{ .Values.observability.healthPort }}
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /healthz
              port: health
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: health
            initialDelaySeconds: 10
            periodSeconds: 5
          resources:
            {{- toYaml .Values.adapters.validation.resources | nindent 12 }}
      volumes:
        - name: adapter-config
          configMap:
            name: {{ include "hyperfleet-adapter.fullname" . }}-validation
{{- end }}
```

**templates/configmap-adapter-validation.yaml:**
```yaml
{{- if .Values.adapters.validation.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "hyperfleet-adapter.fullname" . }}-validation
  namespace: {{ .Values.global.namespace }}
data:
  adapter-config.yaml: |-
{{ .Files.Get "configs/validation-adapter.yaml" | indent 4 }}
{{- end }}
```

**templates/configmap-environment.yaml:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hyperfleet-environment
  namespace: {{ .Values.global.namespace }}
data:
  ENVIRONMENT: {{ .Values.environment | quote }}
  HYPERFLEET_API_BASE_URL: {{ .Values.hyperfleetApi.baseUrl | quote }}
  HYPERFLEET_API_VERSION: {{ .Values.hyperfleetApi.version | quote }}
```

**templates/configmap-observability.yaml:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: adapter-observability
  namespace: {{ .Values.global.namespace }}
  labels:
    app.kubernetes.io/name: hyperfleet
    app.kubernetes.io/component: observability-config
    hyperfleet.io/environment: {{ .Values.environment }}
data:
  # Logging
  LOG_LEVEL: {{ .Values.observability.logLevel | quote }}
  LOG_FORMAT: "json"
  
  # Metrics (Prometheus)
  METRICS_ENABLED: "true"
  METRICS_PORT: {{ .Values.observability.metricsPort | quote }}
  METRICS_PATH: "/metrics"
  
  # Health Checks
  HEALTH_ENABLED: "true"
  HEALTH_PORT: {{ .Values.observability.healthPort | quote }}
  HEALTH_LIVENESS_PATH: "/healthz"
  HEALTH_READINESS_PATH: "/readyz"
  
  # Tracing (OpenTelemetry)
  TRACE_ENABLED: {{ .Values.observability.traceEnabled | quote }}
  TRACE_ENDPOINT: {{ .Values.observability.traceEndpoint | quote }}
  TRACE_SAMPLE_RATE: {{ .Values.observability.traceSampleRate | quote }}
```

---

## Configuration Loading

Configuration is deployed and managed via Helm charts with Kubernetes ConfigMaps.

**Deployment:**

```yaml
spec:
  containers:
    - name: adapter
      args:
        - --config=/etc/adapter/config/adapter-config.yaml
      volumeMounts:
        - name: adapter-config
          mountPath: /etc/adapter/config
          readOnly: true
  volumes:
    - name: adapter-config
      configMap:
        name: validation-adapter-config
```

**Helm Template:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "hyperfleet-adapter.fullname" . }}-validation
data:
  adapter-config.yaml: |-
{{ .Files.Get "configs/validation-adapter.yaml" | indent 4 }}
```

**Characteristics:**
- ✅ Kubernetes-native, no external dependencies
- ✅ Fast pod startup
- ✅ Works offline
- ✅ Version-controlled through Helm chart versioning
- ✅ Config managed through standard Helm upgrade process
- ❌ Config changes require Helm upgrade + pod restart

---

## Service Account and RBAC

### Service Account

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hyperfleet-adapter-validation
  namespace: hyperfleet-system
```

### Role

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: hyperfleet-adapter-validation
  namespace: hyperfleet-system
rules:
  # Create and manage Jobs
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]
  
  # Create and manage resources
  - apiGroups: [""]
    resources: ["namespaces", "services", "configmaps", "secrets"]
    verbs: ["create", "get", "list", "watch", "update", "patch"]
  
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["create", "get", "list", "watch", "update", "patch"]
  
  # Read-only access for status checking
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
```

### RoleBinding

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: hyperfleet-adapter-validation
  namespace: hyperfleet-system
subjects:
  - kind: ServiceAccount
    name: hyperfleet-adapter-validation
    namespace: hyperfleet-system
roleRef:
  kind: Role
  name: hyperfleet-adapter-validation
  apiGroup: rbac.authorization.k8s.io
```

---

## Health and Readiness Probes

### Implementation

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /readyz
    port: 8080
  initialDelaySeconds: 10
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
```

### Endpoints

**`/healthz` (Liveness):**
- Returns `200 OK` if adapter is alive
- Checks: process running, not deadlocked
- Failure → Kubernetes restarts pod

**`/readyz` (Readiness):**
- Returns `200 OK` if adapter is ready to serve traffic
- Checks: broker connected, API accessible, config loaded
- Failure → Kubernetes removes pod from service

**Port Configuration:**
- Metrics: `9090` (Prometheus scraping)
- Health: `8080` (Liveness and readiness probes)

For complete health and readiness endpoint standards, see [Health Endpoints Specification](../../../standards/health-endpoints.md).

---

## Metrics and Monitoring

### Prometheus Metrics

**Exposed on**: `http://:9090/metrics`

**Key Metrics:**
```
# Events processed
adapter_events_processed_total{adapter_type="validation",status="success"}
adapter_events_processed_total{adapter_type="validation",status="failure"}

# Processing duration
adapter_event_processing_duration_seconds{adapter_type="validation"}

# API calls
adapter_api_calls_total{endpoint="/clusters",method="GET",status="200"}
adapter_api_call_duration_seconds{endpoint="/clusters"}

# Kubernetes operations
adapter_k8s_operations_total{operation="create",resource="job",status="success"}

# Broker
adapter_broker_messages_received_total
adapter_broker_messages_acked_total
adapter_broker_messages_nacked_total

# Resource usage
go_memstats_alloc_bytes
go_goroutines
```

### ServiceMonitor

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: hyperfleet-adapter
  namespace: hyperfleet-system
spec:
  selector:
    matchLabels:
      app: hyperfleet-adapter
  endpoints:
    - port: metrics
      interval: 30s
      scrapeTimeout: 10s
      path: /metrics
```

### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hyperfleet-adapter-validation
  namespace: hyperfleet-system
  labels:
    app: hyperfleet-adapter
    adapter-type: validation
spec:
  type: ClusterIP
  ports:
    - name: metrics
      port: 9090
      targetPort: 9090
      protocol: TCP
    - name: health
      port: 8080
      targetPort: 8080
      protocol: TCP
  selector:
    app: hyperfleet-adapter
    adapter-type: validation
```

---

## Deployment Commands

### Install

```bash
# Development
helm install hyperfleet-adapter ./charts \
  -f charts/values-dev.yaml \
  --namespace hyperfleet-system \
  --create-namespace

# Staging
helm install hyperfleet-adapter ./charts \
  -f charts/values-staging.yaml \
  --namespace hyperfleet-system

# Production
helm install hyperfleet-adapter ./charts \
  -f charts/values-prod.yaml \
  --namespace hyperfleet-system
```

### Upgrade

```bash
# Upgrade with new config
helm upgrade hyperfleet-adapter ./charts \
  -f charts/values-prod.yaml \
  --namespace hyperfleet-system

# Upgrade specific adapter config only
kubectl create configmap validation-adapter-config \
  --from-file=adapter-config.yaml=./configs/validation.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/hyperfleet-adapter-validation
```

### Rollback

```bash
# List releases
helm history hyperfleet-adapter --namespace hyperfleet-system

# Rollback to previous version
helm rollback hyperfleet-adapter --namespace hyperfleet-system

# Rollback to specific revision
helm rollback hyperfleet-adapter 3 --namespace hyperfleet-system
```

### Validate

```bash
# Dry-run install
helm install hyperfleet-adapter ./charts \
  -f charts/values-prod.yaml \
  --namespace hyperfleet-system \
  --dry-run --debug

# Template rendering
helm template hyperfleet-adapter ./charts \
  -f charts/values-prod.yaml \
  --namespace hyperfleet-system
```

### Uninstall

```bash
helm uninstall hyperfleet-adapter --namespace hyperfleet-system
```

---

## Troubleshooting

### Pod Not Starting

```bash
# Check pod status
kubectl get pods -n hyperfleet-system -l app=hyperfleet-adapter

# Check events
kubectl describe pod <pod-name> -n hyperfleet-system

# Check logs
kubectl logs <pod-name> -n hyperfleet-system
```

**Common Issues:**
- ConfigMap not found → Check ConfigMap exists: `kubectl get cm -n hyperfleet-system`
- Secret not found → Check Secret exists: `kubectl get secret hyperfleet-api-token -n hyperfleet-system`
- ImagePullBackOff → Check image tag and registry access
- CrashLoopBackOff → Check application logs for errors

### Broker Connection Issues

```bash
# Check broker config
kubectl get cm hyperfleet-broker-config -n hyperfleet-system -o yaml

# Check adapter logs for connection errors
kubectl logs -n hyperfleet-system -l adapter-type=validation --tail=100

# Check network policies
kubectl get networkpolicy -n hyperfleet-system
```

### API Connection Issues

```bash
# Check API service
kubectl get svc hyperfleet-api -n hyperfleet-system

# Test API connectivity from adapter pod
kubectl exec -it <pod-name> -n hyperfleet-system -- \
  curl http://hyperfleet-api.hyperfleet-system.svc.cluster.local:8080/health

# Check API token secret
kubectl get secret hyperfleet-api-token -n hyperfleet-system -o yaml
```

### Configuration Issues

```bash
# View effective configuration
kubectl get cm <adapter-config-name> -n hyperfleet-system -o yaml

# Validate YAML syntax
kubectl get cm <adapter-config-name> -n hyperfleet-system -o jsonpath='{.data.adapter-config\.yaml}' | yq eval

# Check adapter is reading config
kubectl logs <pod-name> -n hyperfleet-system | grep "config loaded"
```

### RBAC Issues

```bash
# Check service account
kubectl get sa hyperfleet-adapter-validation -n hyperfleet-system

# Check role
kubectl get role hyperfleet-adapter-validation -n hyperfleet-system -o yaml

# Check role binding
kubectl get rolebinding hyperfleet-adapter-validation -n hyperfleet-system -o yaml

# Check permissions
kubectl auth can-i create jobs --as=system:serviceaccount:hyperfleet-system:hyperfleet-adapter-validation -n hyperfleet-system
```

### Performance Issues

```bash
# Check resource usage
kubectl top pod -n hyperfleet-system -l app=hyperfleet-adapter

# Check metrics
curl http://<pod-ip>:9090/metrics

# Check for OOMKilled
kubectl get pods -n hyperfleet-system -l app=hyperfleet-adapter -o jsonpath='{.items[*].status.containerStatuses[*].lastState}'

# Increase resources
helm upgrade hyperfleet-adapter ./charts \
  --set adapters.validation.resources.limits.memory=1Gi \
  --namespace hyperfleet-system
```

---

## Deployment Checklist

### Pre-Deployment

- [ ] Helm chart values configured for environment
- [ ] Adapter config files created and validated
- [ ] API token secret created
- [ ] Broker configuration validated
- [ ] Image built and pushed to registry
- [ ] Namespace created
- [ ] RBAC permissions reviewed

### Deployment

- [ ] Run `helm install --dry-run` to validate
- [ ] Deploy to dev/staging first
- [ ] Verify pods are running
- [ ] Check logs for errors
- [ ] Test event processing
- [ ] Verify metrics endpoint
- [ ] Check API connectivity

### Post-Deployment

- [ ] Monitor logs for errors
- [ ] Check Prometheus metrics
- [ ] Verify events are being processed
- [ ] Test status reporting to API
- [ ] Verify resource creation in cluster
- [ ] Set up alerts for failures
- [ ] Document any issues encountered

---

## Configuration Update Workflow

### Update Adapter Logic

```bash
# 1. Edit config file
vim configs/validation-adapter.yaml

# 2. Update ConfigMap
kubectl create configmap validation-adapter-config \
  --from-file=adapter-config.yaml=./configs/validation-adapter.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Restart adapter
kubectl rollout restart deployment/hyperfleet-adapter-validation -n hyperfleet-system

# 4. Verify
kubectl rollout status deployment/hyperfleet-adapter-validation -n hyperfleet-system
kubectl logs -n hyperfleet-system -l adapter-type=validation --tail=50
```

### Update Environment Config

```bash
# 1. Update Helm values
vim charts/values-prod.yaml

# 2. Upgrade release
helm upgrade hyperfleet-adapter ./charts \
  -f charts/values-prod.yaml \
  --namespace hyperfleet-system

# 3. Verify
kubectl get cm hyperfleet-environment -n hyperfleet-system -o yaml
```

---

## Post-MVP Enhancements

### KEDA Autoscaling

Scale adapters based on message queue depth using KEDA (Kubernetes Event-Driven Autoscaling). Enables scale-to-zero when no messages in queue (cost savings), automatic scale-up based on queue backlog, and supports Pub/Sub, SQS, and RabbitMQ triggers.

---

## References

- [Adapter Framework Design](./adapter-frame-design.md)
- `adapter-config-template-MVP.yaml`
- [Adapter Design Decisions](./adapter-design-decisions.md)
- [HyperFleet Tracing Standard](../../../standards/tracing.md)
- [HyperFleet Logging Specification](../../../standards/logging-specification.md)
- [Helm Documentation](https://helm.sh/docs/)
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Prometheus Operator](https://prometheus-operator.dev/)
- [KEDA Documentation](https://keda.sh/docs/)
