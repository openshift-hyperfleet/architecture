---
Status: Active
Owner: HyperFleet Adapter Team
Last Updated: 2025-12-08
---

# Maestro Integration Guide for HyperFleet Adapters

## Overview


**Purpose**: This guide shows adapter developers how to use the Maestro SDK to create and manage resources in management
clusters.

**Applies to**: Any adapter that creates resources in management clusters (HostedCluster, NodePool, etc.)

---

## What is Maestro?

Maestro enables adapters in regional clusters to create resources in management clusters without direct kubeconfig
access. Adapters use the Maestro SDK to create **ManifestWork** resources (wrapping Kubernetes resources) which Maestro
routes to the target **consumer** (management cluster name like `us-east-mgmt-01`).

---

## ManifestWork Structure

ManifestWork wraps Kubernetes resources for cross-cluster delivery. The `metadata.namespace` field determines which
management cluster (consumer) receives the resource.

```go
import (
    workv1 "open-cluster-management.io/api/work/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/runtime"
)

work := &workv1.ManifestWork{
    ObjectMeta: metav1.ObjectMeta{
        Name:      "hostedcluster-abc123",
        Namespace: "us-east-mgmt-01", // Consumer name (target management cluster)
        Labels: map[string]string{
            "hyperfleet.io/cluster-id": "abc123",
            "hyperfleet.io/adapter":    "controlplane",
        },
    },
    Spec: workv1.ManifestWorkSpec{
        Workload: workv1.ManifestsTemplate{
            Manifests: []workv1.Manifest{
                {
                    RawExtension: runtime.RawExtension{
                        Raw: []byte(`{
                            "apiVersion": "hypershift.openshift.io/v1beta1",
                            "kind": "HostedCluster",
                            "metadata": {
                                "name": "my-cluster",
                                "namespace": "clusters"
                            },
                            "spec": {
                                ...HostedCluster spec...
                            }
                        }`),
                    },
                },
            },
        },
        ManifestConfigs: []workv1.ManifestConfigOption{
            {
                ResourceIdentifier: workv1.ResourceIdentifier{
                    Group:     "hypershift.openshift.io",
                    Resource:  "hostedclusters",
                    Namespace: "clusters",
                    Name:      "my-cluster",
                },
                UpdateStrategy: &workv1.UpdateStrategy{
                    Type: workv1.UpdateStrategyTypeServerSideApply,
                },
                // FeedbackRules: Tell Maestro what status to watch and return
                // Without feedbackRules, you won't get any status information back
                FeedbackRules: []workv1.FeedbackRule{
                    {
                        Type: workv1.JSONPathsType,
                        JsonPaths: []workv1.JsonPath{
                            {
                                Name: "status",  // You'll reference this name when reading feedback
                                Path: ".status", // JSONPath to extract from the resource
                            },
                            // You can add multiple paths:
                            // {Name: "replicas", Path: ".status.replicas"},
                            // {Name: "conditions", Path: ".status.conditions"},
                        },
                    },
                },
            },
        },
        DeleteOption: &workv1.DeleteOption{
            PropagationPolicy: workv1.DeletePropagationPolicyTypeForeground,
        },
    },
}
```

**Key Fields**:

- **`metadata.namespace`**: Consumer name (target management cluster) - **this determines routing**
- **`metadata.name`**: Unique identifier (e.g., `hostedcluster-abc123`)
- **`spec.workload.manifests`**: Array of Kubernetes resources to create
- **`spec.manifestConfigs[].resourceIdentifier`**: Identifies each resource (group, resource type, namespace, name)
- **`spec.manifestConfigs[].feedbackRules`**: What status information to report back

---

## FeedbackRules Explained

**Purpose**: FeedbackRules tell Maestro what information to watch and return from the management cluster. Without feedback rules, you won't get any status information.

**How it works**:
1. You create ManifestWork with feedbackRules specifying JSONPaths to watch
2. Maestro creates the resource on the management cluster
3. Maestro watches the resource and extracts fields per your JSONPath specifications
4. When you GET the ManifestWork, Maestro includes the extracted values in the response
5. You parse the feedback to make decisions in your adapter

**Example**:

```go
FeedbackRules: []workv1.FeedbackRule{
    {
        Type: workv1.JSONPathsType,
        JsonPaths: []workv1.JsonPath{
            {
                Name: "status",      // Identifier you'll use when reading feedback
                Path: ".status",     // JSONPath to extract from the resource
            },
            {
                Name: "replicas",
                Path: ".status.replicas",
            },
            {
                Name: "conditions",
                Path: ".status.conditions",
            },
        },
    },
},
```

**What You Get**: Maestro returns the exact JSON from each JSONPath. For example, with `Path: ".status"` on a HostedCluster, you'll get the complete HostedCluster status object.

---

## SDK Usage

```go
import (
    "github.com/openshift-online/maestro/pkg/api/openapi"
    "github.com/openshift-online/maestro/pkg/client/cloudevents/grpcsource"
    "github.com/openshift-online/ocm-sdk-go/logging"
    workv1 "open-cluster-management.io/api/work/v1"
    "open-cluster-management.io/sdk-go/pkg/cloudevents/generic/options/grpc"
)

func main() {
    ctx := context.Background()

    // 1. Create REST API client (used internally by SDK)
    maestroAPIClient := openapi.NewAPIClient(&openapi.Configuration{
        Servers: openapi.ServerConfigurations{{URL: os.Getenv("MAESTRO_API_URL")}},
    })

    // 2. Create Maestro SDK client
    token, _ := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
    logger, _ := logging.NewStdLoggerBuilder().Build()
    workClient, err := grpcsource.NewMaestroGRPCSourceWorkClient(
        ctx, logger, maestroAPIClient,
        &grpc.GRPCOptions{
            Dialer: &grpc.GRPCDialer{
                URL:   os.Getenv("MAESTRO_GRPC_URL"),
                Token: string(token),
            },
        },
        "adapter-source-id",
    )

    // 3. Build ManifestWork
    consumerName := "us-east-mgmt-01" // Target management cluster
    work := &workv1.ManifestWork{
        ObjectMeta: metav1.ObjectMeta{
            Name:      "hostedcluster-abc123",
            Namespace: consumerName,
        },
        Spec: workv1.ManifestWorkSpec{
            Workload: workv1.ManifestsTemplate{
                Manifests: []workv1.Manifest{ /* your resources */ },
            },
            ManifestConfigs: []workv1.ManifestConfigOption{ /* feedback rules */ },
        },
    }

    // 4. Check if exists (idempotency)
    existing, err := workClient.ManifestWorks(consumerName).Get(ctx, work.Name, metav1.GetOptions{})
    if errors.IsNotFound(err) {
        // Create if doesn't exist
        _, err = workClient.ManifestWorks(consumerName).Create(ctx, work, metav1.CreateOptions{})
    }

    // 5. Query status
    updated, _ := workClient.ManifestWorks(consumerName).Get(ctx, work.Name, metav1.GetOptions{})
    log.Printf("Status: %+v", updated.Status)
}
```

---

## Reading Resource Status from ManifestWork Feedback

After creating a ManifestWork with feedbackRules, you can retrieve the resource status from the management cluster. Maestro watches the resource and stores status updates in the ManifestWork.

**How it works**:
1. You create ManifestWork with feedbackRules specifying which fields to watch
2. Maestro creates the resource on the management cluster
3. Maestro watches the resource and extracts fields per feedbackRules
4. When you GET the ManifestWork, status feedback is included in the response
5. You parse the feedback to get your resource's current status

**Example Code**:

```go
// Get the ManifestWork from Maestro
work, err := workClient.ManifestWorks(consumerName).Get(ctx, workName, metav1.GetOptions{})
if err != nil {
    return err
}

// Extract status feedback from the ManifestWork
for _, manifestStatus := range work.Status.ResourceStatus.Manifests {
    for _, feedback := range manifestStatus.StatusFeedbacks.Values {
        if feedback.Name == "status" {  // Matches the feedbackRule name
            statusJSON := *feedback.Value.JsonRaw

            // Parse into your resource's status struct
            var resourceStatus MyResourceStatus
            if err := json.Unmarshal([]byte(statusJSON), &resourceStatus); err != nil {
                return fmt.Errorf("failed to parse status: %w", err)
            }

            // Use resourceStatus to make decisions
            fmt.Printf("Resource status: %+v\n", resourceStatus)
        }
    }
}
```

**What gets returned**: The exact JSON from the resource's field specified in the feedbackRule path. For example, if you have `path: ".status"` on a HostedCluster, you'll get the complete HostedCluster status object.

**ManifestWork.Status.ResourceStatus Structure**:

```json
{
  "status": {
    "resourceStatus": {
      "manifests": [
        {
          "resourceMeta": {
            "group": "hypershift.openshift.io",
            "kind": "HostedCluster",
            "name": "my-cluster",
            "namespace": "clusters"
          },
          "statusFeedbacks": {
            "values": [
              {
                "name": "status",
                "fieldValue": {
                  "type": "JsonRaw",
                  "jsonRaw": "{\"conditions\":[{\"type\":\"Available\",\"status\":\"True\"...}]}"
                }
              }
            ]
          }
        }
      ]
    }
  }
}
```

---

## Authentication

Set `serviceAccountName: maestro-adapter-sa` in your Job spec (Maestro team creates the ServiceAccount). Kubernetes
auto-mounts the token at `/var/run/secrets/kubernetes.io/serviceaccount/token`. Environment variables `MAESTRO_API_URL`
and `MAESTRO_GRPC_URL` are provided by the adapter framework.

---

## Error Handling

| Error Type                               | Retry? | Action                                   |
|------------------------------------------|--------|------------------------------------------|
| Network timeout / gRPC unavailable (503) | Yes    | Retry with exponential backoff           |
| Authentication failure (401)             | No     | Exit with error                          |
| Not Found (404)                          | No     | Expected for GET before Create - proceed |
| Already Exists (409)                     | No     | Check ownership, report status           |
| Invalid spec (400)                       | No     | Exit with validation error               |

Use `errors.IsServerTimeout()`, `errors.IsServiceUnavailable()`, and `errors.IsTooManyRequests()` to identify retryable
errors.

---

## Consumer Targeting

The `metadata.namespace` field determines which management cluster receives the ManifestWork. This is called the "consumer name" (e.g., `us-east-mgmt-01`).

**Getting the consumer name**:

### Option 1: Static Configuration (MVP Approach)

For MVP, use a static consumer name from adapter configuration:

```yaml
# In Job manifest
env:
  - name: MANAGEMENT_CLUSTER_CONSUMER
    value: "us-east-mgmt-01"  # Hardcoded per region for MVP
```

```go
// In adapter code
consumerName := os.Getenv("MANAGEMENT_CLUSTER_CONSUMER")
```

### Option 2: From ConfigMap

```yaml
# In Job manifest
env:
  - name: MANAGEMENT_CLUSTER_CONSUMER
    valueFrom:
      configMapKeyRef:
        name: controlplane-adapter-config
        key: management_cluster_consumer
```

### Option 3: Dynamic Selection (Post-MVP)

Query the HyperFleet API to get available management clusters based on region and availability:

```go
// Query HyperFleet API for healthy management clusters in region
resp, _ := http.Get(fmt.Sprintf("%s/api/v1/management-clusters?region=%s&status=healthy",
    apiURL, region))

var clusters []ManagementCluster
json.NewDecoder(resp.Body).Decode(&clusters)

// Select cluster (round-robin, least-loaded, etc.)
consumerName := selectCluster(clusters)
```

---

## Complete End-to-End Example

Here's a complete example showing the full workflow: create ManifestWork, wait for it to be applied, and read status feedback.

```go
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "os"
    "time"

    "github.com/openshift-online/maestro/pkg/api/openapi"
    "github.com/openshift-online/maestro/pkg/client/cloudevents/grpcsource"
    "github.com/openshift-online/ocm-sdk-go/logging"
    workv1 "open-cluster-management.io/api/work/v1"
    "open-cluster-management.io/sdk-go/pkg/cloudevents/generic/options/grpc"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/runtime"
    "k8s.io/apimachinery/pkg/api/errors"
)

func main() {
    ctx := context.Background()

    // 1. Setup Maestro client
    token, _ := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
    logger, _ := logging.NewStdLoggerBuilder().Build()

    maestroAPIClient := openapi.NewAPIClient(&openapi.Configuration{
        Servers: openapi.ServerConfigurations{{URL: os.Getenv("MAESTRO_API_URL")}},
    })

    workClient, err := grpcsource.NewMaestroGRPCSourceWorkClient(
        ctx, logger, maestroAPIClient,
        &grpc.GRPCOptions{
            Dialer: &grpc.GRPCDialer{
                URL:   os.Getenv("MAESTRO_GRPC_URL"),
                Token: string(token),
            },
        },
        "my-adapter",
    )
    if err != nil {
        panic(err)
    }

    consumerName := os.Getenv("MANAGEMENT_CLUSTER_CONSUMER")
    workName := "hostedcluster-abc123"

    // 2. Check if ManifestWork exists
    existing, err := workClient.ManifestWorks(consumerName).Get(ctx, workName, metav1.GetOptions{})

    if errors.IsNotFound(err) {
        // 3. Create ManifestWork
        work := &workv1.ManifestWork{
            ObjectMeta: metav1.ObjectMeta{
                Name:      workName,
                Namespace: consumerName,
            },
            Spec: workv1.ManifestWorkSpec{
                Workload: workv1.ManifestsTemplate{
                    Manifests: []workv1.Manifest{
                        {
                            RawExtension: runtime.RawExtension{
                                Raw: []byte(`{
                                    "apiVersion": "hypershift.openshift.io/v1beta1",
                                    "kind": "HostedCluster",
                                    "metadata": {
                                        "name": "my-cluster",
                                        "namespace": "clusters"
                                    },
                                    "spec": {
                                        "platform": {"type": "GCP"},
                                        "release": {"image": "quay.io/openshift-release-dev/ocp-release:4.14.0"}
                                    }
                                }`),
                            },
                        },
                    },
                },
                ManifestConfigs: []workv1.ManifestConfigOption{
                    {
                        ResourceIdentifier: workv1.ResourceIdentifier{
                            Group:     "hypershift.openshift.io",
                            Resource:  "hostedclusters",
                            Namespace: "clusters",
                            Name:      "my-cluster",
                        },
                        FeedbackRules: []workv1.FeedbackRule{
                            {
                                Type: workv1.JSONPathsType,
                                JsonPaths: []workv1.JsonPath{
                                    {Name: "status", Path: ".status"},
                                },
                            },
                        },
                    },
                },
            },
        }

        _, err = workClient.ManifestWorks(consumerName).Create(ctx, work, metav1.CreateOptions{})
        if err != nil {
            panic(err)
        }

        fmt.Println("ManifestWork created")

        // Write results indicating Applied=True, Available=False
        results := map[string]interface{}{
            "conditions": []map[string]string{
                {"type": "Applied", "status": "True", "reason": "ManifestWorkCreated"},
                {"type": "Available", "status": "False", "reason": "Provisioning"},
                {"type": "Health", "status": "True", "reason": "NoIssues"},
            },
        }
        writeResults(results)

    } else if err == nil {
        // 4. Read status feedback
        for _, manifestStatus := range existing.Status.ResourceStatus.Manifests {
            for _, feedback := range manifestStatus.StatusFeedbacks.Values {
                if feedback.Name == "status" {
                    var status HostedClusterStatus
                    json.Unmarshal([]byte(*feedback.Value.JsonRaw), &status)

                    // Check if HostedCluster is Available
                    available := "False"
                    for _, cond := range status.Conditions {
                        if cond.Type == "Available" && cond.Status == "True" {
                            available = "True"
                            break
                        }
                    }

                    fmt.Printf("HostedCluster Available: %s\n", available)

                    // Write results
                    results := map[string]interface{}{
                        "conditions": []map[string]string{
                            {"type": "Applied", "status": "True", "reason": "ManifestWorkExists"},
                            {"type": "Available", "status": available, "reason": "ControlPlaneReady"},
                            {"type": "Health", "status": "True", "reason": "NoIssues"},
                        },
                        "data": map[string]string{
                            "control_plane_endpoint": status.ControlPlaneEndpoint,
                        },
                    }
                    writeResults(results)
                }
            }
        }
    } else {
        panic(err)
    }
}

type HostedClusterStatus struct {
    Conditions           []Condition `json:"conditions"`
    ControlPlaneEndpoint string      `json:"controlPlaneEndpoint"`
}

type Condition struct {
    Type   string `json:"type"`
    Status string `json:"status"`
}

func writeResults(results map[string]interface{}) {
    file, _ := os.Create("/results/adapter-report.json")
    defer file.Close()
    json.NewEncoder(file).Encode(results)
}
```

This example shows:
1. Maestro SDK client setup
2. Idempotency check (GET before CREATE)
3. ManifestWork creation with feedbackRules
4. Status extraction from ManifestWork feedback
5. Decision-making based on HostedCluster status
6. Writing results for the status reporter sidecar

---

## References

- [Maestro SDK Examples](https://github.com/openshift-online/maestro/tree/main/examples/manifestworkclient) - Official
  SDK usage examples
- [HyperFleet Adapter Framework Design](adapter-frame-design.md) - Adapter framework documentation
- [Open Cluster Management ManifestWork API](https://open-cluster-management.io/concepts/manifestwork/) - ManifestWork
  specification
