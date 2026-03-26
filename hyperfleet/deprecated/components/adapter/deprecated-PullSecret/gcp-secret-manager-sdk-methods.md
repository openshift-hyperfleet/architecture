---
Status: Deprecated
Owner: HyperFleet Adapter Team
Last Updated: 2026-01-27
---

# GCP Secret Manager SDK Methods - Go Client Library Reference

## Table of Contents

1. [Overview](#overview)
2. [Go Client Library Setup](#go-client-library-setup)
3. [SDK Methods Reference](#sdk-methods-reference)
   - [CreateSecret](#1-createsecret---create-secret-resource)
   - [AddSecretVersion](#2-addsecretversion---store-secret-data)
   - [GetSecret](#3-getsecret---retrieve-secret-metadata)
   - [AccessSecretVersion](#4-accesssecretversion---retrieve-secret-data)
   - [ListSecrets](#5-listsecrets---list-all-secrets)
   - [DeleteSecret](#6-deletesecret---delete-secret)
   - [DestroySecretVersion](#7-destroysecretversion---destroy-secret-version)
   - [UpdateSecret](#8-updatesecret---update-secret-metadata)
4. [Complete Implementation Example](#complete-implementation-example)
5. [Error Handling](#error-handling)
6. [Best Practices](#best-practices)
7. [References](#references)

---

## Overview

This document provides a comprehensive reference for the **Google Cloud Secret Manager Go SDK** methods used by the HyperFleet Pull Secret Adapter to manage image pull secrets in GCP Secret Manager.

### Purpose

The Pull Secret Adapter Job uses these SDK methods to:
- Create secrets for OpenShift cluster image pull credentials
- Store and version pull secret data securely
- Verify secret accessibility and readiness
- Manage secret lifecycle (updates, cleanup)

### SDK Version

```
cloud.google.com/go/secretmanager v1.11.5+
```

---

## Go Client Library Setup

### Required Packages

```go
import (
    "context"
    "fmt"
    "log"

    secretmanager "cloud.google.com/go/secretmanager/apiv1"
    "cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"
    "google.golang.org/api/iterator"
    "google.golang.org/protobuf/types/known/fieldmaskpb"
)
```

### Go Module Dependencies

**go.mod:**
```go
module github.com/hyperfleet/pullsecret-job

go 1.21

require (
    cloud.google.com/go/secretmanager v1.11.5
    google.golang.org/api v0.162.0
    google.golang.org/genproto/googleapis/cloud/secretmanager/v1 v0.0.0-20240205150955-31a09d347014
)
```

### Client Initialization

```go
func NewSecretManagerClient(ctx context.Context) (*secretmanager.Client, error) {
    // Create the Secret Manager client
    // Automatically uses Application Default Credentials (ADC)
    // or Workload Identity in Kubernetes
    client, err := secretmanager.NewClient(ctx)
    if err != nil {
        return nil, fmt.Errorf("failed to create secretmanager client: %w", err)
    }
    return client, nil
}
```

### Authentication

The client uses **Workload Identity** when running in Kubernetes:
- Service Account: `pullsecret-adapter-job`
- GCP Service Account: Bound via Workload Identity
- Required IAM Role: `roles/secretmanager.admin` or custom role with specific permissions

---

## SDK Methods Reference

### 1. CreateSecret - Create Secret Resource

Creates a new secret resource in GCP Secret Manager without storing data. The actual secret data is added using `AddSecretVersion()`.

#### Go Client Method

```go
func (c *Client) CreateSecret(
    ctx context.Context,
    req *secretmanagerpb.CreateSecretRequest,
    opts ...gax.CallOption,
) (*secretmanagerpb.Secret, error)
```

#### Request Structure

```go
type CreateSecretRequest struct {
    Parent   string  // Format: "projects/{project-id}"
    SecretId string  // Secret name (not full path)
    Secret   *Secret // Secret configuration
}

type Secret struct {
    Replication *Replication          // Replication policy
    Labels      map[string]string     // Metadata labels
}
```

#### Usage Example

```go
func createSecret(ctx context.Context, client *secretmanager.Client, projectID, clusterID string) error {
    secretID := fmt.Sprintf("hyperfleet-%s-pull-secret", clusterID)

    req := &secretmanagerpb.CreateSecretRequest{
        Parent:   fmt.Sprintf("projects/%s", projectID),
        SecretId: secretID,
        Secret: &secretmanagerpb.Secret{
            Replication: &secretmanagerpb.Replication{
                Replication: &secretmanagerpb.Replication_Automatic_{
                    Automatic: &secretmanagerpb.Replication_Automatic{},
                },
            },
            Labels: map[string]string{
                "managed-by":         "hyperfleet",
                "adapter":            "pullsecret",
                "cluster-id":         clusterID,
                "cluster-name":       "production-cluster",
                "resource-type":      "pull-secret",
                "hyperfleet-version": "v1",
            },
        },
    }

    secret, err := client.CreateSecret(ctx, req)
    if err != nil {
        return fmt.Errorf("failed to create secret: %w", err)
    }

    log.Printf("Created secret: %s", secret.Name)
    return nil
}
```

#### Response

```go
type Secret struct {
    Name        string                // Full resource name
    Replication *Replication          // Replication configuration
    CreateTime  *timestamppb.Timestamp
    Labels      map[string]string
}
```

#### Required IAM Permission

- `secretmanager.secrets.create`

#### Error Codes

- `AlreadyExists`: Secret with this ID already exists
- `PermissionDenied`: Insufficient permissions
- `InvalidArgument`: Invalid secret ID or configuration

---

### 2. AddSecretVersion - Store Secret Data

Adds a new version containing the actual secret data to an existing secret. Each version is immutable.

#### Go Client Method

```go
func (c *Client) AddSecretVersion(
    ctx context.Context,
    req *secretmanagerpb.AddSecretVersionRequest,
    opts ...gax.CallOption,
) (*secretmanagerpb.SecretVersion, error)
```

#### Request Structure

```go
type AddSecretVersionRequest struct {
    Parent  string         // Format: "projects/{project}/secrets/{secret}"
    Payload *SecretPayload // Secret data
}

type SecretPayload struct {
    Data []byte // Secret data as bytes
}
```

#### Usage Example

```go
func addSecretVersion(ctx context.Context, client *secretmanager.Client, projectID, secretID string, pullSecretData []byte) error {
    parent := fmt.Sprintf("projects/%s/secrets/%s", projectID, secretID)

    req := &secretmanagerpb.AddSecretVersionRequest{
        Parent: parent,
        Payload: &secretmanagerpb.SecretPayload{
            Data: pullSecretData, // Dockercfg JSON format
        },
    }

    version, err := client.AddSecretVersion(ctx, req)
    if err != nil {
        return fmt.Errorf("failed to add secret version: %w", err)
    }

    log.Printf("Added secret version: %s", version.Name)
    return nil
}
```

#### Pull Secret Data Format

The data must be in **Dockercfg JSON format**:

```json
{
  "auths": {
    "registry.redhat.io": {
      "auth": "base64-encoded-credentials",
      "email": "user@example.com"
    },
    "quay.io": {
      "auth": "base64-encoded-credentials",
      "email": "user@example.com"
    }
  }
}
```

#### Response

```go
type SecretVersion struct {
    Name       string                 // Format: "projects/{project}/secrets/{secret}/versions/{version}"
    CreateTime *timestamppb.Timestamp
    State      SecretVersion_State    // ENABLED, DISABLED, DESTROYED
}
```

#### Required IAM Permission

- `secretmanager.versions.add`

#### Size Limits

- **Maximum secret size:** 64 KiB
- **Typical pull secret size:** < 5 KiB

---

### 3. GetSecret - Retrieve Secret Metadata

Retrieves metadata about a secret (without the actual secret data). Useful to check if a secret exists before creating it.

#### Go Client Method

```go
func (c *Client) GetSecret(
    ctx context.Context,
    req *secretmanagerpb.GetSecretRequest,
    opts ...gax.CallOption,
) (*secretmanagerpb.Secret, error)
```

#### Request Structure

```go
type GetSecretRequest struct {
    Name string // Format: "projects/{project}/secrets/{secret}"
}
```

#### Usage Example

```go
func secretExists(ctx context.Context, client *secretmanager.Client, projectID, secretID string) (bool, error) {
    name := fmt.Sprintf("projects/%s/secrets/%s", projectID, secretID)

    req := &secretmanagerpb.GetSecretRequest{
        Name: name,
    }

    secret, err := client.GetSecret(ctx, req)
    if err != nil {
        // Check if error is "NotFound"
        if status.Code(err) == codes.NotFound {
            return false, nil
        }
        return false, fmt.Errorf("failed to get secret: %w", err)
    }

    log.Printf("Secret exists: %s (created: %s)", secret.Name, secret.CreateTime)
    return true, nil
}
```

#### Response

```go
type Secret struct {
    Name        string
    Replication *Replication
    CreateTime  *timestamppb.Timestamp
    Labels      map[string]string
    Topics      []*Topic // Optional Pub/Sub topics
}
```

#### Required IAM Permission

- `secretmanager.secrets.get`

---

### 4. AccessSecretVersion - Retrieve Secret Data

Accesses the payload data of a specific secret version. This is used to retrieve the actual pull secret content.

#### Go Client Method

```go
func (c *Client) AccessSecretVersion(
    ctx context.Context,
    req *secretmanagerpb.AccessSecretVersionRequest,
    opts ...gax.CallOption,
) (*secretmanagerpb.AccessSecretVersionResponse, error)
```

#### Request Structure

```go
type AccessSecretVersionRequest struct {
    Name string // Format: "projects/{project}/secrets/{secret}/versions/{version}"
                // Use "latest" for the most recent enabled version
}
```

#### Usage Example

```go
func getSecretData(ctx context.Context, client *secretmanager.Client, projectID, secretID string) ([]byte, error) {
    name := fmt.Sprintf("projects/%s/secrets/%s/versions/latest", projectID, secretID)

    req := &secretmanagerpb.AccessSecretVersionRequest{
        Name: name,
    }

    result, err := client.AccessSecretVersion(ctx, req)
    if err != nil {
        return nil, fmt.Errorf("failed to access secret version: %w", err)
    }

    // Extract the payload data
    data := result.Payload.Data

    log.Printf("Retrieved secret data (%d bytes) from version: %s", len(data), result.Name)
    return data, nil
}
```

#### Response

```go
type AccessSecretVersionResponse struct {
    Name    string         // Full version resource name
    Payload *SecretPayload // Secret data
}

type SecretPayload struct {
    Data       []byte    // Secret data
    DataCrc32C *int64    // Optional CRC32C checksum
}
```

#### Required IAM Permission

- `secretmanager.versions.access`

#### Quota Limits

- **Access requests:** 90,000 per minute per project (highest quota)

---

### 5. ListSecrets - List All Secrets

Lists secrets within a project. Supports filtering by labels for cleanup operations.

#### Go Client Method

```go
func (c *Client) ListSecrets(
    ctx context.Context,
    req *secretmanagerpb.ListSecretsRequest,
    opts ...gax.CallOption,
) *SecretIterator
```

#### Request Structure

```go
type ListSecretsRequest struct {
    Parent   string // Format: "projects/{project}"
    PageSize int32  // Optional: number of results per page
    Filter   string // Optional: filter expression
}
```

#### Usage Example

```go
func listHyperfleetSecrets(ctx context.Context, client *secretmanager.Client, projectID string) error {
    req := &secretmanagerpb.ListSecretsRequest{
        Parent:   fmt.Sprintf("projects/%s", projectID),
        PageSize: 100,
        Filter:   "labels.managed-by=hyperfleet AND labels.adapter=pullsecret",
    }

    it := client.ListSecrets(ctx, req)

    for {
        secret, err := it.Next()
        if err == iterator.Done {
            break
        }
        if err != nil {
            return fmt.Errorf("failed to iterate secrets: %w", err)
        }

        log.Printf("Found secret: %s (cluster-id: %s)",
            secret.Name, secret.Labels["cluster-id"])
    }

    return nil
}
```

#### Filter Syntax

```
labels.managed-by=hyperfleet
labels.adapter=pullsecret
labels.cluster-id=cls-abc123
```

Combine with `AND`, `OR`:
```
labels.managed-by=hyperfleet AND labels.adapter=pullsecret
```

#### Required IAM Permission

- `secretmanager.secrets.list`

---

### 6. DeleteSecret - Delete Secret

Permanently deletes a secret and all of its versions. This operation is irreversible.

#### Go Client Method

```go
func (c *Client) DeleteSecret(
    ctx context.Context,
    req *secretmanagerpb.DeleteSecretRequest,
    opts ...gax.CallOption,
) error
```

#### Request Structure

```go
type DeleteSecretRequest struct {
    Name string // Format: "projects/{project}/secrets/{secret}"
    Etag string // Optional: for optimistic concurrency control
}
```

#### Usage Example

```go
func deleteSecret(ctx context.Context, client *secretmanager.Client, projectID, secretID string) error {
    name := fmt.Sprintf("projects/%s/secrets/%s", projectID, secretID)

    req := &secretmanagerpb.DeleteSecretRequest{
        Name: name,
    }

    err := client.DeleteSecret(ctx, req)
    if err != nil {
        return fmt.Errorf("failed to delete secret: %w", err)
    }

    log.Printf("Deleted secret: %s", name)
    return nil
}
```

#### Required IAM Permission

- `secretmanager.secrets.delete`

#### Use Cases

- Cluster decommissioning
- Cleanup of orphaned secrets
- Secret rotation (create new, delete old)

---

### 7. DestroySecretVersion - Destroy Secret Version

Permanently destroys a specific secret version. The secret itself remains, but the version data is irrecoverably deleted.

#### Go Client Method

```go
func (c *Client) DestroySecretVersion(
    ctx context.Context,
    req *secretmanagerpb.DestroySecretVersionRequest,
    opts ...gax.CallOption,
) (*secretmanagerpb.SecretVersion, error)
```

#### Request Structure

```go
type DestroySecretVersionRequest struct {
    Name string // Format: "projects/{project}/secrets/{secret}/versions/{version}"
    Etag string // Optional: for optimistic concurrency control
}
```

#### Usage Example

```go
func destroyOldVersion(ctx context.Context, client *secretmanager.Client, projectID, secretID string, versionID int) error {
    name := fmt.Sprintf("projects/%s/secrets/%s/versions/%d", projectID, secretID, versionID)

    req := &secretmanagerpb.DestroySecretVersionRequest{
        Name: name,
    }

    version, err := client.DestroySecretVersion(ctx, req)
    if err != nil {
        return fmt.Errorf("failed to destroy version: %w", err)
    }

    log.Printf("Destroyed version: %s (state: %s)", version.Name, version.State)
    return nil
}
```

#### Required IAM Permission

- `secretmanager.versions.destroy`

#### Use Cases

- Removing compromised secret versions
- Compliance with data retention policies
- Secret rotation cleanup

---

### 8. UpdateSecret - Update Secret Metadata

Updates the metadata of an existing secret (labels, topics). Does not affect secret versions or data.

#### Go Client Method

```go
func (c *Client) UpdateSecret(
    ctx context.Context,
    req *secretmanagerpb.UpdateSecretRequest,
    opts ...gax.CallOption,
) (*secretmanagerpb.Secret, error)
```

#### Request Structure

```go
type UpdateSecretRequest struct {
    Secret     *Secret     // Secret with updated fields
    UpdateMask *fieldmaskpb.FieldMask // Fields to update
}
```

#### Usage Example

```go
func updateSecretLabels(ctx context.Context, client *secretmanager.Client, projectID, secretID string, newLabels map[string]string) error {
    name := fmt.Sprintf("projects/%s/secrets/%s", projectID, secretID)

    req := &secretmanagerpb.UpdateSecretRequest{
        Secret: &secretmanagerpb.Secret{
            Name:   name,
            Labels: newLabels,
        },
        UpdateMask: &fieldmaskpb.FieldMask{
            Paths: []string{"labels"},
        },
    }

    secret, err := client.UpdateSecret(ctx, req)
    if err != nil {
        return fmt.Errorf("failed to update secret: %w", err)
    }

    log.Printf("Updated secret labels: %s", secret.Name)
    return nil
}
```

#### Updatable Fields

- `labels` - Metadata labels
- `topics` - Pub/Sub topics for notifications
- `annotations` - Additional metadata

#### Required IAM Permission

- `secretmanager.secrets.update`

---

## Complete Implementation Example

### Pull Secret Job Main Logic

```go
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "log"
    "os"

    secretmanager "cloud.google.com/go/secretmanager/apiv1"
    "cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
)

func main() {
    ctx := context.Background()

    // Read configuration from environment variables
    projectID := os.Getenv("GCP_PROJECT_ID")
    clusterID := os.Getenv("CLUSTER_ID")
    clusterName := os.Getenv("CLUSTER_NAME")
    secretName := os.Getenv("SECRET_NAME")
    pullSecretData := os.Getenv("PULL_SECRET_DATA")

    if projectID == "" || clusterID == "" || pullSecretData == "" {
        log.Fatal("Missing required environment variables")
    }

    if secretName == "" {
        secretName = fmt.Sprintf("hyperfleet-%s-pull-secret", clusterID)
    }

    // Initialize Secret Manager client
    client, err := secretmanager.NewClient(ctx)
    if err != nil {
        log.Fatalf("Failed to create client: %v", err)
    }
    defer client.Close()

    // Validate pull secret JSON format
    if err := validatePullSecret(pullSecretData); err != nil {
        log.Fatalf("Invalid pull secret format: %v", err)
    }

    // Create or update secret
    if err := createOrUpdateSecret(ctx, client, projectID, secretName, clusterID, clusterName, []byte(pullSecretData)); err != nil {
        log.Fatalf("Failed to create/update secret: %v", err)
    }

    // Verify secret is accessible
    if err := verifySecret(ctx, client, projectID, secretName); err != nil {
        log.Fatalf("Failed to verify secret: %v", err)
    }

    log.Printf("Successfully created/updated pull secret: %s", secretName)
}

func createOrUpdateSecret(ctx context.Context, client *secretmanager.Client, projectID, secretName, clusterID, clusterName string, data []byte) error {
    // Check if secret exists
    exists, err := secretExists(ctx, client, projectID, secretName)
    if err != nil {
        return err
    }

    if !exists {
        // Create new secret
        log.Printf("Creating new secret: %s", secretName)
        if err := createSecret(ctx, client, projectID, secretName, clusterID, clusterName); err != nil {
            return fmt.Errorf("failed to create secret: %w", err)
        }
    } else {
        log.Printf("Secret already exists: %s", secretName)
    }

    // Add secret version with data
    log.Printf("Adding secret version with pull secret data")
    return addSecretVersion(ctx, client, projectID, secretName, data)
}

func secretExists(ctx context.Context, client *secretmanager.Client, projectID, secretName string) (bool, error) {
    name := fmt.Sprintf("projects/%s/secrets/%s", projectID, secretName)

    req := &secretmanagerpb.GetSecretRequest{
        Name: name,
    }

    _, err := client.GetSecret(ctx, req)
    if err != nil {
        if status.Code(err) == codes.NotFound {
            return false, nil
        }
        return false, err
    }

    return true, nil
}

func createSecret(ctx context.Context, client *secretmanager.Client, projectID, secretName, clusterID, clusterName string) error {
    req := &secretmanagerpb.CreateSecretRequest{
        Parent:   fmt.Sprintf("projects/%s", projectID),
        SecretId: secretName,
        Secret: &secretmanagerpb.Secret{
            Replication: &secretmanagerpb.Replication{
                Replication: &secretmanagerpb.Replication_Automatic_{
                    Automatic: &secretmanagerpb.Replication_Automatic{},
                },
            },
            Labels: map[string]string{
                "managed-by":         "hyperfleet",
                "adapter":            "pullsecret",
                "cluster-id":         clusterID,
                "cluster-name":       clusterName,
                "resource-type":      "pull-secret",
                "hyperfleet-version": "v1",
            },
        },
    }

    _, err := client.CreateSecret(ctx, req)
    return err
}

func addSecretVersion(ctx context.Context, client *secretmanager.Client, projectID, secretName string, data []byte) error {
    parent := fmt.Sprintf("projects/%s/secrets/%s", projectID, secretName)

    req := &secretmanagerpb.AddSecretVersionRequest{
        Parent: parent,
        Payload: &secretmanagerpb.SecretPayload{
            Data: data,
        },
    }

    version, err := client.AddSecretVersion(ctx, req)
    if err != nil {
        return err
    }

    log.Printf("Created version: %s", version.Name)
    return nil
}

func verifySecret(ctx context.Context, client *secretmanager.Client, projectID, secretName string) error {
    name := fmt.Sprintf("projects/%s/secrets/%s/versions/latest", projectID, secretName)

    req := &secretmanagerpb.AccessSecretVersionRequest{
        Name: name,
    }

    result, err := client.AccessSecretVersion(ctx, req)
    if err != nil {
        return fmt.Errorf("failed to access secret: %w", err)
    }

    log.Printf("Verified secret (%d bytes)", len(result.Payload.Data))
    return nil
}

func validatePullSecret(pullSecretJSON string) error {
    var pullSecret map[string]interface{}
    if err := json.Unmarshal([]byte(pullSecretJSON), &pullSecret); err != nil {
        return fmt.Errorf("invalid JSON: %w", err)
    }

    auths, ok := pullSecret["auths"]
    if !ok {
        return fmt.Errorf("missing 'auths' key")
    }

    authsMap, ok := auths.(map[string]interface{})
    if !ok || len(authsMap) == 0 {
        return fmt.Errorf("'auths' must be a non-empty object")
    }

    return nil
}
```

---

## Error Handling

### Common Error Codes

```go
import "google.golang.org/grpc/codes"

func handleError(err error) {
    switch status.Code(err) {
    case codes.NotFound:
        log.Printf("Secret not found")
    case codes.AlreadyExists:
        log.Printf("Secret already exists")
    case codes.PermissionDenied:
        log.Printf("Insufficient permissions")
    case codes.InvalidArgument:
        log.Printf("Invalid request parameters")
    case codes.ResourceExhausted:
        log.Printf("Quota exceeded")
    case codes.DeadlineExceeded:
        log.Printf("Request timeout")
    default:
        log.Printf("Unexpected error: %v", err)
    }
}
```

### Retry Strategy

```go
import (
    "time"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
)

func isRetryable(err error) bool {
    code := status.Code(err)
    return code == codes.Unavailable ||
           code == codes.DeadlineExceeded ||
           code == codes.Internal
}

func retryWithBackoff(ctx context.Context, fn func() error, maxRetries int) error {
    var err error
    for i := 0; i < maxRetries; i++ {
        err = fn()
        if err == nil {
            return nil
        }

        if !isRetryable(err) {
            return err
        }

        backoff := time.Duration(1<<uint(i)) * time.Second
        log.Printf("Retry %d/%d after %s: %v", i+1, maxRetries, backoff, err)

        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-time.After(backoff):
        }
    }
    return err
}
```

---

## Best Practices

### 1. Secret Naming

- Use consistent naming: `hyperfleet-{cluster-id}-pull-secret`
- Keep names ≤ 255 characters
- Use lowercase letters, numbers, and hyphens only

### 2. Labels

Always include these labels for tracking and management:
```go
labels := map[string]string{
    "managed-by":         "hyperfleet",
    "adapter":            "pullsecret",
    "cluster-id":         clusterID,
    "cluster-name":       clusterName,
    "resource-type":      "pull-secret",
    "hyperfleet-version": "v1",
}
```

### 3. Replication Policy

- **MVP**: Use `Automatic` replication for simplicity
- **Production**: Consider `UserManaged` for specific regions

### 4. Secret Rotation

```go
// Add new version (old version remains available)
addSecretVersion(ctx, client, projectID, secretName, newData)

// After verification, destroy old version
destroySecretVersion(ctx, client, projectID, secretName, oldVersionID)
```

### 5. Cleanup

Always clean up secrets when clusters are decommissioned:
```go
// List secrets for specific cluster
filter := fmt.Sprintf("labels.cluster-id=%s", clusterID)
// Delete matching secrets
```

### 6. Quota Management

Monitor API usage to avoid hitting quotas:
- Cache `GetSecret` results
- Use batch operations when possible
- Implement exponential backoff for retries

### 7. Security

- Never log secret data
- Use Workload Identity (avoid service account keys)
- Apply least-privilege IAM permissions
- Enable audit logging

---

## References

### Official Documentation

- [GCP Secret Manager Overview](https://cloud.google.com/secret-manager/docs)
- [Creating and Accessing Secrets](https://cloud.google.com/secret-manager/docs/creating-and-accessing-secrets)
- [Go Client Library Reference](https://pkg.go.dev/cloud.google.com/go/secretmanager/apiv1)
- [API Reference](https://cloud.google.com/secret-manager/docs/reference/rest)

### Go SDK

- **Package**: `cloud.google.com/go/secretmanager/apiv1`

