#!/bin/bash

################################################################################
# GKE Cluster Deletion Script
#
# This script automates the deletion of GKE clusters and associated resources
# including network resources (VPC, subnets, firewall rules) if they were
# created by the create-gke-cluster.sh script.
#
# Usage:
#   ./delete-gke-cluster.sh <ENV_FILE> [OPTIONS]
#
# Examples:
#   ./delete-gke-cluster.sh cluster-envs/dev-autopilot.env
#   ./delete-gke-cluster.sh cluster-envs/dev-standard-regional.env --force
#   ./delete-gke-cluster.sh cluster-envs/dev-autopilot.env --cluster-only --dry-run
#
# Options:
#   --cluster-only     Delete only the cluster, keep network resources
#   --force            Skip confirmation prompts
#   --dry-run          Show what would be deleted without actually deleting
#
# Requirements:
#   - gcloud CLI installed and authenticated
#   - kubectl installed (optional, for pre-deletion cleanup)
#   - Appropriate GCP permissions
################################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Flags
CLUSTER_ONLY=false
FORCE=false
DRY_RUN=false
CONFIG_FILE=""

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_dry_run() {
    echo -e "${MAGENTA}[DRY-RUN]${NC} $1"
}

# Error handler
error_exit() {
    log_error "$1"
    exit 1
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-only)
                CLUSTER_ONLY=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 <ENV_FILE> [OPTIONS]"
                echo ""
                echo "Examples:"
                echo "  $0 cluster-envs/dev-autopilot.env"
                echo "  $0 cluster-envs/dev-standard-regional.env --force"
                echo ""
                echo "Options:"
                echo "  --cluster-only    Delete only the cluster, keep network resources"
                echo "  --force           Skip confirmation prompts"
                echo "  --dry-run         Show what would be deleted without actually deleting"
                echo "  -h, --help        Show this help message"
                exit 0
                ;;
            *)
                if [ -z "$CONFIG_FILE" ]; then
                    CONFIG_FILE="$1"
                else
                    echo "Error: Unknown option: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Check if CONFIG_FILE is provided
    if [ -z "$CONFIG_FILE" ]; then
        echo ""
        echo "Error: Environment file is required."
        echo ""
        echo "Usage: $0 <ENV_FILE> [OPTIONS]"
        echo ""
        echo "Available environment files:"
        ls -1 cluster-envs/*.env 2>/dev/null || echo "  No environment files found in cluster-envs/"
        echo ""
        echo "Example: $0 cluster-envs/dev-autopilot.env"
        exit 1
    fi
}

# Check if required tools are installed
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v gcloud &> /dev/null; then
        error_exit "gcloud CLI is not installed. Please install it from https://cloud.google.com/sdk/docs/install"
    fi

    log_success "Prerequisites check passed"
}

# Load and validate configuration
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error_exit "Configuration file '$CONFIG_FILE' not found. Please provide a valid configuration file."
    fi

    log_info "Loading configuration from $CONFIG_FILE..."
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    # Validate required variables
    [ -z "${PROJECT_ID:-}" ] && error_exit "PROJECT_ID is not set in configuration"
    [ -z "${CLUSTER_NAME:-}" ] && error_exit "CLUSTER_NAME is not set in configuration"
    [ -z "${REGION:-}" ] && error_exit "REGION is not set in configuration"

    # Set defaults for optional variables
    CLUSTER_MODE="${CLUSTER_MODE:-standard}"
    DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-regional}"
    NETWORK_MODE="${NETWORK_MODE:-create}"

    log_success "Configuration loaded successfully"
}

# Validate GCP project
validate_project() {
    log_info "Validating GCP project configuration..."

    gcloud config set project "$PROJECT_ID" || error_exit "Failed to set project to $PROJECT_ID"

    if ! gcloud projects describe "$PROJECT_ID" &>/dev/null; then
        error_exit "Project $PROJECT_ID does not exist or you don't have access to it"
    fi

    log_success "Project validation successful: $PROJECT_ID"
}

# Check if cluster exists
check_cluster_exists() {
    log_info "Checking if cluster exists..."

    local location
    if [ "$CLUSTER_MODE" = "autopilot" ] || [ "${DEPLOYMENT_TYPE}" = "regional" ]; then
        location="--region=$REGION"
    else
        local zone="${ZONE:-${REGION}-a}"
        location="--zone=$zone"
    fi

    if gcloud container clusters describe "$CLUSTER_NAME" $location --project="$PROJECT_ID" &>/dev/null; then
        log_info "Cluster $CLUSTER_NAME found"
        return 0
    else
        log_warning "Cluster $CLUSTER_NAME not found"
        return 1
    fi
}

# Cleanup cluster resources before deletion (optional)
cleanup_cluster_resources() {
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would cleanup cluster resources (PVCs, LoadBalancers, etc.)"
        return 0
    fi

    # Check cluster status first
    local location
    if [ "$CLUSTER_MODE" = "autopilot" ] || [ "${DEPLOYMENT_TYPE}" = "regional" ]; then
        location="--region=$REGION"
    else
        local zone="${ZONE:-${REGION}-a}"
        location="--zone=$zone"
    fi

    local cluster_status
    cluster_status=$(gcloud container clusters describe "$CLUSTER_NAME" $location --project="$PROJECT_ID" --format="value(status)" 2>/dev/null || echo "")

    # Skip resource checking if cluster is in ERROR or DEGRADED state
    if [[ "$cluster_status" == "ERROR" ]] || [[ "$cluster_status" == "DEGRADED" ]]; then
        log_warning "Cluster is in $cluster_status state. Skipping cluster resources check."
        return 0
    fi

    log_info "Checking for cluster resources that may prevent deletion..."

    # Try to get cluster credentials
    if command -v kubectl &> /dev/null; then
        if gcloud container clusters get-credentials "$CLUSTER_NAME" $location --project="$PROJECT_ID" &>/dev/null; then
            # Check for LoadBalancer services
            local lb_services
            lb_services=$(kubectl get svc --all-namespaces -o json 2>/dev/null | \
                jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")

            if [ -n "$lb_services" ]; then
                log_warning "Found LoadBalancer services. These will be cleaned up during cluster deletion."
                echo "$lb_services" | while read -r svc; do
                    log_info "  - $svc"
                done
            fi

            # Check for PersistentVolumeClaims
            local pvcs
            pvcs=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")

            if [ "$pvcs" -gt 0 ]; then
                log_warning "Found $pvcs PersistentVolumeClaim(s). These will be cleaned up during cluster deletion."
            fi
        fi
    fi
}

# Delete GKE cluster
delete_cluster() {
    if ! check_cluster_exists; then
        log_warning "Skipping cluster deletion - cluster does not exist"
        return 0
    fi

    cleanup_cluster_resources

    local location_flag
    local location_name
    if [ "$CLUSTER_MODE" = "autopilot" ] || [ "${DEPLOYMENT_TYPE}" = "regional" ]; then
        location_flag="--region=$REGION"
        location_name="region $REGION"
    else
        local zone="${ZONE:-${REGION}-a}"
        location_flag="--zone=$zone"
        location_name="zone $zone"
    fi

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would delete cluster: $CLUSTER_NAME in $location_name"
        return 0
    fi

    log_info "Deleting GKE cluster: $CLUSTER_NAME in $location_name..."
    log_warning "This operation may take several minutes..."

    gcloud container clusters delete "$CLUSTER_NAME" \
        $location_flag \
        --project="$PROJECT_ID" \
        --quiet \
        || error_exit "Failed to delete cluster"

    log_success "Cluster deleted successfully"
}

# Delete firewall rules
delete_firewall_rules() {
    if [ -z "${NETWORK_NAME:-}" ]; then
        log_warning "NETWORK_NAME not set, skipping firewall rules deletion"
        return 0
    fi

    log_info "Deleting firewall rules..."

    local fw_rules=(
        "${NETWORK_NAME}-allow-internal"
        "${NETWORK_NAME}-allow-ssh"
    )

    for fw_rule in "${fw_rules[@]}"; do
        if gcloud compute firewall-rules describe "$fw_rule" --project="$PROJECT_ID" &>/dev/null; then
            if [ "$DRY_RUN" = true ]; then
                log_dry_run "Would delete firewall rule: $fw_rule"
            else
                log_info "Deleting firewall rule: $fw_rule"
                gcloud compute firewall-rules delete "$fw_rule" \
                    --project="$PROJECT_ID" \
                    --quiet \
                    || log_warning "Failed to delete firewall rule: $fw_rule"
                log_success "Firewall rule deleted: $fw_rule"
            fi
        else
            log_info "Firewall rule $fw_rule does not exist, skipping"
        fi
    done
}

# Delete subnet
delete_subnet() {
    if [ -z "${SUBNET_NAME:-}" ] || [ -z "${REGION:-}" ]; then
        log_warning "SUBNET_NAME or REGION not set, skipping subnet deletion"
        return 0
    fi

    if gcloud compute networks subnets describe "$SUBNET_NAME" \
        --region="$REGION" \
        --project="$PROJECT_ID" &>/dev/null; then

        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would delete subnet: $SUBNET_NAME in region $REGION"
        else
            log_info "Deleting subnet: $SUBNET_NAME in region $REGION..."
            gcloud compute networks subnets delete "$SUBNET_NAME" \
                --region="$REGION" \
                --project="$PROJECT_ID" \
                --quiet \
                || log_warning "Failed to delete subnet: $SUBNET_NAME"
            log_success "Subnet deleted: $SUBNET_NAME"
        fi
    else
        log_info "Subnet $SUBNET_NAME does not exist, skipping"
    fi
}

# Delete VPC network
delete_network() {
    if [ -z "${NETWORK_NAME:-}" ]; then
        log_warning "NETWORK_NAME not set, skipping network deletion"
        return 0
    fi

    if gcloud compute networks describe "$NETWORK_NAME" --project="$PROJECT_ID" &>/dev/null; then
        if [ "$DRY_RUN" = true ]; then
            log_dry_run "Would delete VPC network: $NETWORK_NAME"
        else
            log_info "Deleting VPC network: $NETWORK_NAME..."
            gcloud compute networks delete "$NETWORK_NAME" \
                --project="$PROJECT_ID" \
                --quiet \
                || log_warning "Failed to delete network: $NETWORK_NAME"
            log_success "Network deleted: $NETWORK_NAME"
        fi
    else
        log_info "Network $NETWORK_NAME does not exist, skipping"
    fi
}

# Delete network resources
delete_network_resources() {
    if [ "$CLUSTER_ONLY" = true ]; then
        log_info "Cluster-only mode: Skipping network resources deletion"
        return 0
    fi

    if [ "${NETWORK_MODE}" = "existing" ]; then
        log_info "Network mode is 'existing': Skipping network resources deletion"
        log_info "The existing network, subnet, and firewall rules will be preserved"
        return 0
    fi

    log_info "Deleting network resources..."

    # Delete in order: firewall rules -> subnet -> network
    delete_firewall_rules
    delete_subnet
    delete_network
}

# Display deletion summary
display_summary() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                    DELETION SUMMARY                            ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "MODE: DRY RUN (no resources were actually deleted)"
        echo ""
    fi

    echo "Project:       $PROJECT_ID"
    echo "Cluster:       $CLUSTER_NAME"
    echo "Region:        $REGION"
    echo ""

    if [ "$CLUSTER_ONLY" = true ]; then
        echo "Resources deleted:"
        echo "  ✓ GKE Cluster"
        echo ""
        echo "Resources preserved:"
        echo "  - VPC Network: $NETWORK_NAME"
        echo "  - Subnet: $SUBNET_NAME"
        echo "  - Firewall rules"
    elif [ "${NETWORK_MODE}" = "existing" ]; then
        echo "Resources deleted:"
        echo "  ✓ GKE Cluster"
        echo ""
        echo "Resources preserved (existing network):"
        echo "  - VPC Network: $NETWORK_NAME"
        echo "  - Subnet: $SUBNET_NAME"
        echo "  - Firewall rules"
    else
        echo "Resources deleted:"
        echo "  ✓ GKE Cluster"
        echo "  ✓ VPC Network: ${NETWORK_NAME:-N/A}"
        echo "  ✓ Subnet: ${SUBNET_NAME:-N/A}"
        echo "  ✓ Firewall rules"
    fi

    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "To actually delete these resources, run this script without --dry-run"
        echo ""
    fi
}

# Confirm deletion
confirm_deletion() {
    if [ "$FORCE" = true ]; then
        return 0
    fi

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                      DELETION WARNING                          ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo -e "${RED}WARNING: This operation will permanently delete the following resources:${NC}"
    echo ""
    echo "  Project:  $PROJECT_ID"
    echo "  Cluster:  $CLUSTER_NAME"
    echo "  Region:   $REGION"
    echo ""

    if [ "$CLUSTER_ONLY" = true ]; then
        echo "  Scope: CLUSTER ONLY (network resources will be preserved)"
    elif [ "${NETWORK_MODE}" = "existing" ]; then
        echo "  Scope: CLUSTER ONLY (existing network will be preserved)"
    else
        echo "  Scope: CLUSTER + NETWORK RESOURCES"
        echo "         - VPC Network: $NETWORK_NAME"
        echo "         - Subnet: $SUBNET_NAME"
        echo "         - Firewall rules"
    fi

    echo ""
    echo -e "${YELLOW}This action cannot be undone!${NC}"
    echo ""

    read -p "Are you sure you want to proceed? (type 'yes' to confirm): " -r
    echo ""

    if [ "$REPLY" != "yes" ]; then
        log_info "Deletion cancelled by user"
        exit 0
    fi

    log_warning "Proceeding with deletion..."
}

# Main execution flow
main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║           GKE Cluster Deletion Automation Script              ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    # Parse arguments
    parse_args "$@"

    # Check prerequisites
    check_prerequisites

    # Load configuration
    load_config

    # Validate project
    validate_project

    # Confirm deletion (unless --force or --dry-run)
    if [ "$DRY_RUN" = false ]; then
        confirm_deletion
    else
        log_info "Running in DRY-RUN mode - no resources will be deleted"
        echo ""
    fi

    # Delete cluster
    delete_cluster

    # Delete network resources (if applicable)
    delete_network_resources

    # Display summary
    display_summary

    if [ "$DRY_RUN" = false ]; then
        log_success "All deletion operations completed successfully!"
    else
        log_info "Dry run completed. Review the summary above."
    fi

    echo ""
}

# Run main function
main "$@"
