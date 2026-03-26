#!/bin/bash

################################################################################
# GKE Cluster Creation Automation Script with Config Connector
#
# This script automates the creation of GKE clusters (Autopilot or Standard)
# with Config Connector add-on enabled.
#
# Usage:
#   ./create-gke-cluster.sh <ENV_FILE>
#
# Examples:
#   ./create-gke-cluster.sh cluster-envs/dev-standard-zonal.env
#
# Requirements:
#   - gcloud CLI installed and authenticated
#   - kubectl installed
#   - Appropriate GCP permissions
################################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Error handler
error_exit() {
    log_error "$1"
    exit 1
}

# Check if required tools are installed
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v gcloud &> /dev/null; then
        error_exit "gcloud CLI is not installed. Please install it from https://cloud.google.com/sdk/docs/install"
    fi

    if ! command -v kubectl &> /dev/null; then
        error_exit "kubectl is not installed. Please install it from https://kubernetes.io/docs/tasks/tools/"
    fi

    log_success "Prerequisites check passed"
}

# Load and validate configuration
load_config() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        error_exit "Configuration file '$config_file' not found."
    fi

    log_info "Loading configuration from $config_file..."
    # shellcheck disable=SC1090
    source "$config_file"

    # Validate required common variables
    [ -z "${PROJECT_ID:-}" ] && error_exit "PROJECT_ID is not set in configuration"
    [ -z "${CLUSTER_NAME:-}" ] && error_exit "CLUSTER_NAME is not set in configuration"
    [ -z "${REGION:-}" ] && error_exit "REGION is not set in configuration"
    [ -z "${CLUSTER_MODE:-}" ] && error_exit "CLUSTER_MODE is not set in configuration"

    # Validate cluster mode
    if [[ ! "$CLUSTER_MODE" =~ ^(autopilot|standard)$ ]]; then
        error_exit "CLUSTER_MODE must be 'autopilot' or 'standard'"
    fi

    # Validate network mode
    if [[ ! "${NETWORK_MODE:-create}" =~ ^(create|existing)$ ]]; then
        error_exit "NETWORK_MODE must be 'create' or 'existing'"
    fi

    # For standard mode, validate deployment type
    if [ "$CLUSTER_MODE" = "standard" ]; then
        if [[ ! "${DEPLOYMENT_TYPE:-regional}" =~ ^(zonal|regional)$ ]]; then
            error_exit "DEPLOYMENT_TYPE must be 'zonal' or 'regional' for standard clusters"
        fi
    fi

    log_success "Configuration loaded successfully"
}

# Validate and set GCP project
validate_project() {
    log_info "Validating GCP project configuration..."

    local current_project
    current_project=$(gcloud config get-value project 2>/dev/null || echo "")

    if [ -z "$current_project" ]; then
        log_warning "No default project is set"
    else
        log_info "Current gcloud project: $current_project"
    fi

    log_info "Setting project to: $PROJECT_ID"
    gcloud config set project "$PROJECT_ID" || error_exit "Failed to set project to $PROJECT_ID"

    # Verify project exists and we have access
    if ! gcloud projects describe "$PROJECT_ID" &>/dev/null; then
        error_exit "Project $PROJECT_ID does not exist or you don't have access to it"
    fi

    log_success "Project validation successful: $PROJECT_ID"
}

# Enable required GCP APIs
enable_apis() {
    log_info "Enabling required GCP APIs..."

    local apis=(
        "container.googleapis.com"
        "compute.googleapis.com"
        "cloudresourcemanager.googleapis.com"
        "serviceusage.googleapis.com"
    )

    for api in "${apis[@]}"; do
        log_info "Enabling $api..."
        gcloud services enable "$api" --project="$PROJECT_ID" || log_warning "Failed to enable $api (may already be enabled)"
    done

    log_success "API enablement completed"
}

# Create VPC network
create_network() {
    log_info "Creating VPC network: $NETWORK_NAME"

    if gcloud compute networks describe "$NETWORK_NAME" --project="$PROJECT_ID" &>/dev/null; then
        log_warning "Network $NETWORK_NAME already exists, skipping creation"
    else
        gcloud compute networks create "$NETWORK_NAME" \
            --project="$PROJECT_ID" \
            --subnet-mode=custom \
            --bgp-routing-mode=regional \
            || error_exit "Failed to create network"
        log_success "Network created: $NETWORK_NAME"
    fi
}

# Create subnet
create_subnet() {
    log_info "Creating subnet: $SUBNET_NAME"

    if gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        log_warning "Subnet $SUBNET_NAME already exists, skipping creation"
    else
        gcloud compute networks subnets create "$SUBNET_NAME" \
            --project="$PROJECT_ID" \
            --network="$NETWORK_NAME" \
            --region="$REGION" \
            --range="${SUBNET_RANGE:-10.0.0.0/24}" \
            || error_exit "Failed to create subnet"
        log_success "Subnet created: $SUBNET_NAME"
    fi
}

# Create firewall rules
create_firewall_rules() {
    log_info "Creating firewall rules..."

    # Allow internal traffic
    local fw_internal="${NETWORK_NAME}-allow-internal"
    if gcloud compute firewall-rules describe "$fw_internal" --project="$PROJECT_ID" &>/dev/null; then
        log_warning "Firewall rule $fw_internal already exists, skipping"
    else
        gcloud compute firewall-rules create "$fw_internal" \
            --project="$PROJECT_ID" \
            --network="$NETWORK_NAME" \
            --allow=tcp,udp,icmp \
            --source-ranges="${SUBNET_RANGE:-10.0.0.0/24}" \
            || log_warning "Failed to create internal firewall rule"
        log_success "Internal firewall rule created"
    fi

    # Allow SSH from anywhere (adjust source-ranges for production)
    local fw_ssh="${NETWORK_NAME}-allow-ssh"
    if gcloud compute firewall-rules describe "$fw_ssh" --project="$PROJECT_ID" &>/dev/null; then
        log_warning "Firewall rule $fw_ssh already exists, skipping"
    else
        gcloud compute firewall-rules create "$fw_ssh" \
            --project="$PROJECT_ID" \
            --network="$NETWORK_NAME" \
            --allow=tcp:22 \
            --source-ranges="${SSH_SOURCE_RANGES:-0.0.0.0/0}" \
            || log_warning "Failed to create SSH firewall rule"
        log_success "SSH firewall rule created"
    fi
}

# Setup network resources
setup_network() {
    if [ "${NETWORK_MODE}" = "create" ]; then
        log_info "Setting up new VPC network..."
        create_network
        create_subnet
        create_firewall_rules
    else
        log_info "Using existing network: $NETWORK_NAME and subnet: $SUBNET_NAME"

        # Validate existing network and subnet
        if ! gcloud compute networks describe "$NETWORK_NAME" --project="$PROJECT_ID" &>/dev/null; then
            error_exit "Network $NETWORK_NAME does not exist"
        fi

        if ! gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
            error_exit "Subnet $SUBNET_NAME does not exist in region $REGION"
        fi

        log_success "Existing network validated"
    fi
}

# Create GKE Autopilot cluster
create_autopilot_cluster() {
    log_info "Creating GKE Autopilot cluster: $CLUSTER_NAME"

    # Note: Autopilot clusters don't support --addons flag during creation
    # Workload Identity is enabled by default in Autopilot
    local create_cmd="gcloud container clusters create-auto \"$CLUSTER_NAME\" \
        --project=\"$PROJECT_ID\" \
        --region=\"$REGION\" \
        --network=\"$NETWORK_NAME\" \
        --subnetwork=\"$SUBNET_NAME\""

    # Add release channel if specified
    if [ -n "${RELEASE_CHANNEL:-}" ]; then
        create_cmd="$create_cmd --release-channel=\"$RELEASE_CHANNEL\""
    fi

    # Add cluster version if specified (for non-release-channel clusters)
    if [ -n "${CLUSTER_VERSION:-}" ] && [ -z "${RELEASE_CHANNEL:-}" ]; then
        create_cmd="$create_cmd --cluster-version=\"$CLUSTER_VERSION\""
    fi

    # Add labels if specified
    if [ -n "${LABELS:-}" ]; then
        create_cmd="$create_cmd --labels=\"$LABELS\""
    fi

    log_info "Executing: $create_cmd"
    eval "$create_cmd" || error_exit "Failed to create Autopilot cluster"

    log_success "Autopilot cluster created successfully"

    # Enable Config Connector addon for Autopilot cluster
    log_info "Enabling Config Connector addon..."
    gcloud container clusters update "$CLUSTER_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION" \
        --update-addons=ConfigConnector=ENABLED \
        || error_exit "Failed to enable Config Connector addon"

    log_success "Config Connector addon enabled"
}

# Create GKE Standard cluster
create_standard_cluster() {
    log_info "Creating GKE Standard cluster: $CLUSTER_NAME (${DEPLOYMENT_TYPE})"

    local create_cmd="gcloud container clusters create \"$CLUSTER_NAME\" \
        --project=\"$PROJECT_ID\" \
        --network=\"$NETWORK_NAME\" \
        --subnetwork=\"$SUBNET_NAME\" \
        --workload-pool=\"${PROJECT_ID}.svc.id.goog\" \
        --addons=ConfigConnector \
        --enable-ip-alias \
        --enable-autorepair \
        --enable-autoupgrade"

    # Add regional or zonal configuration
    if [ "${DEPLOYMENT_TYPE}" = "regional" ]; then
        create_cmd="$create_cmd --region=\"$REGION\""
        if [ -n "${NUM_NODES:-}" ]; then
            create_cmd="$create_cmd --num-nodes=\"$NUM_NODES\""
        fi
    else
        # Zonal deployment
        local zone="${ZONE:-${REGION}-a}"
        create_cmd="$create_cmd --zone=\"$zone\""
        if [ -n "${NUM_NODES:-}" ]; then
            create_cmd="$create_cmd --num-nodes=\"$NUM_NODES\""
        fi
    fi

    # Add machine type if specified
    if [ -n "${MACHINE_TYPE:-}" ]; then
        create_cmd="$create_cmd --machine-type=\"$MACHINE_TYPE\""
    fi

    # Add disk size if specified
    if [ -n "${DISK_SIZE:-}" ]; then
        create_cmd="$create_cmd --disk-size=\"$DISK_SIZE\""
    fi

    # Add Spot VM configuration if specified
    # Spot VMs are the newer version of preemptible VMs in GKE
    if [ "${USE_SPOT_VMS:-false}" = "true" ]; then
        log_info "Configuring cluster with Spot VMs (up to 91% cheaper than regular VMs)"
        create_cmd="$create_cmd --spot"
    fi

    # Add min/max nodes for autoscaling if specified
    if [ -n "${MIN_NODES:-}" ] && [ -n "${MAX_NODES:-}" ]; then
        create_cmd="$create_cmd --enable-autoscaling --min-nodes=\"$MIN_NODES\" --max-nodes=\"$MAX_NODES\""
    fi

    # Add release channel if specified
    if [ -n "${RELEASE_CHANNEL:-}" ]; then
        create_cmd="$create_cmd --release-channel=\"$RELEASE_CHANNEL\""
    fi

    # Add cluster version if specified (for non-release-channel clusters)
    if [ -n "${CLUSTER_VERSION:-}" ] && [ -z "${RELEASE_CHANNEL:-}" ]; then
        create_cmd="$create_cmd --cluster-version=\"$CLUSTER_VERSION\""
    fi

    # Add labels if specified
    if [ -n "${LABELS:-}" ]; then
        create_cmd="$create_cmd --labels=\"$LABELS\""
    fi

    log_info "Executing: $create_cmd"
    eval "$create_cmd" || error_exit "Failed to create Standard cluster"

    log_success "Standard cluster created successfully"
}

# Create GKE cluster based on mode
create_cluster() {
    log_info "Creating GKE cluster in $CLUSTER_MODE mode..."

    # Check if cluster already exists
    if gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null 2>&1; then
        log_warning "Cluster $CLUSTER_NAME already exists in region $REGION"
        read -p "Do you want to continue and skip cluster creation? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error_exit "Cluster creation aborted by user"
        fi
        return 0
    elif [ "$CLUSTER_MODE" = "standard" ] && [ "${DEPLOYMENT_TYPE}" = "zonal" ]; then
        local zone="${ZONE:-${REGION}-a}"
        if gcloud container clusters describe "$CLUSTER_NAME" --zone="$zone" --project="$PROJECT_ID" &>/dev/null 2>&1; then
            log_warning "Cluster $CLUSTER_NAME already exists in zone $zone"
            read -p "Do you want to continue and skip cluster creation? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                error_exit "Cluster creation aborted by user"
            fi
            return 0
        fi
    fi

    if [ "$CLUSTER_MODE" = "autopilot" ]; then
        create_autopilot_cluster
    else
        create_standard_cluster
    fi
}

# Get cluster credentials
get_credentials() {
    log_info "Retrieving cluster credentials..."

    local get_creds_cmd
    if [ "$CLUSTER_MODE" = "autopilot" ] || [ "${DEPLOYMENT_TYPE:-regional}" = "regional" ]; then
        get_creds_cmd="gcloud container clusters get-credentials \"$CLUSTER_NAME\" \
            --region=\"$REGION\" \
            --project=\"$PROJECT_ID\""
    else
        local zone="${ZONE:-${REGION}-a}"
        get_creds_cmd="gcloud container clusters get-credentials \"$CLUSTER_NAME\" \
            --zone=\"$zone\" \
            --project=\"$PROJECT_ID\""
    fi

    eval "$get_creds_cmd" || error_exit "Failed to get cluster credentials"

    log_success "Credentials retrieved and configured"
}

# Configure Config Connector
configure_config_connector() {
    log_info "Configuring Config Connector..."

    # Create ConfigConnector resource
    log_info "Creating ConfigConnector resource..."

    local gsa_email="${CONFIG_CONNECTOR_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

    cat <<EOF | kubectl apply --request-timeout=120s -f -
apiVersion: core.cnrm.cloud.google.com/v1beta1
kind: ConfigConnector
metadata:
  name: configconnector.core.cnrm.cloud.google.com
spec:
  mode: cluster
  googleServiceAccount: "${gsa_email}"
EOF

    log_success "Config Connector configured"

    # Wait for Config Connector to be ready
    log_info "Waiting for Config Connector pods to be ready (this may take a few minutes)..."
    kubectl wait --for=condition=Ready pods --all -n cnrm-system --timeout=300s --request-timeout=120s || \
        log_warning "Some Config Connector pods may not be ready yet. Check with: kubectl get pods -n cnrm-system"

    log_success "Config Connector is ready"
}

# Display cluster information
display_cluster_info() {
    log_info "Gathering cluster information..."

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                  CLUSTER CREATION SUCCESSFUL                   ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Cluster Details:"
    echo "  Name:          $CLUSTER_NAME"
    echo "  Project:       $PROJECT_ID"
    echo "  Region:        $REGION"
    echo "  Mode:          $CLUSTER_MODE"
    if [ "$CLUSTER_MODE" = "standard" ]; then
        echo "  Type:          ${DEPLOYMENT_TYPE}"
        if [ "${USE_SPOT_VMS:-false}" = "true" ]; then
            echo "  VM Type:       Spot VMs (cost-optimized)"
        else
            echo "  VM Type:       Standard VMs"
        fi
    fi
    echo "  Network:       $NETWORK_NAME"
    echo "  Subnet:        $SUBNET_NAME"
    echo ""

    # Get cluster endpoint
    local endpoint
    if [ "$CLUSTER_MODE" = "autopilot" ] || [ "${DEPLOYMENT_TYPE:-regional}" = "regional" ]; then
        endpoint=$(gcloud container clusters describe "$CLUSTER_NAME" \
            --region="$REGION" \
            --project="$PROJECT_ID" \
            --format="value(endpoint)" 2>/dev/null || echo "N/A")
    else
        local zone="${ZONE:-${REGION}-a}"
        endpoint=$(gcloud container clusters describe "$CLUSTER_NAME" \
            --zone="$zone" \
            --project="$PROJECT_ID" \
            --format="value(endpoint)" 2>/dev/null || echo "N/A")
    fi

    echo "Cluster Endpoint: $endpoint"
    echo ""

    # Display current context
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || echo "N/A")
    echo "Current kubectl context: $current_context"
    echo ""

    # Basic cluster info
    echo "Cluster Info:"
    kubectl cluster-info 2>/dev/null || log_warning "Failed to get cluster info"
    echo ""

    # Config Connector status
    echo "Config Connector Status:"
    kubectl get pods -n cnrm-system 2>/dev/null || \
        log_warning "Failed to get Config Connector status"
    echo ""

    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                         NEXT STEPS                             ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "1. Verify cluster access:"
    echo "   kubectl get nodes"
    echo ""
    echo "2. Share cluster access with team members:"
    echo "   ./get-cluster-access.sh"
    echo "   (They should run the displayed command)"
    echo ""
    echo "3. Start using Config Connector:"
    echo "   kubectl apply -f your-gcp-resource.yaml"
    echo ""
    echo "4. View Config Connector logs:"
    echo "   kubectl logs -n cnrm-system -l cnrm.cloud.google.com/component=cnrm-controller-manager"
    echo ""
}

# Generate team access script
generate_access_script() {
    log_info "Generating team access helper script..."

    local script_path="./get-cluster-access.sh"

    cat > "$script_path" << 'EOFSCRIPT'
#!/bin/bash
# This script helps team members get access to the GKE cluster
EOFSCRIPT

    cat >> "$script_path" << EOFSCRIPT

PROJECT_ID="$PROJECT_ID"
CLUSTER_NAME="$CLUSTER_NAME"
REGION="$REGION"
CLUSTER_MODE="$CLUSTER_MODE"
DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-regional}"
ZONE="${ZONE:-${REGION}-a}"

echo "================================="
echo "GKE Cluster Access Instructions"
echo "================================="
echo ""
echo "Cluster: \$CLUSTER_NAME"
echo "Project: \$PROJECT_ID"
echo "Region:  \$REGION"
echo ""

echo "To access this cluster, run the following command:"
echo ""

if [ "\$CLUSTER_MODE" = "autopilot" ] || [ "\$DEPLOYMENT_TYPE" = "regional" ]; then
    echo "gcloud container clusters get-credentials \$CLUSTER_NAME --region=\$REGION --project=\$PROJECT_ID"
else
    echo "gcloud container clusters get-credentials \$CLUSTER_NAME --zone=\$ZONE --project=\$PROJECT_ID"
fi

echo ""
echo "Then verify access with:"
echo "  kubectl get nodes"
echo ""
echo "Note: You need appropriate IAM permissions on the project."
echo "Required roles:"
echo "  - roles/container.clusterViewer (minimum for read access)"
echo "  - roles/container.developer (for full access)"
echo ""
EOFSCRIPT

    chmod +x "$script_path"
    log_success "Team access script created: $script_path"
}

# Main execution flow
main() {
    # Check if env file parameter is provided
    if [ $# -eq 0 ]; then
        echo ""
        echo "Error: Environment file is required."
        echo ""
        echo "Usage: $0 <ENV_FILE>"
        echo ""
        echo "Available environment files:"
        ls -1 cluster-envs/*.env 2>/dev/null || echo "  No environment files found in cluster-envs/"
        echo ""
        echo "Example: $0 cluster-envs/dev-autopilot.env"
        exit 1
    fi

    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║     GKE Cluster Creation with Config Connector Automation      ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    # Check prerequisites
    check_prerequisites

    # Load configuration
    local config_file="$1"
    load_config "$config_file"

    # Validate project
    validate_project

    # Enable APIs
    enable_apis

    # Setup network
    setup_network

    # Create cluster
    create_cluster

    # Get credentials
    get_credentials

    # Configure Config Connector
    configure_config_connector

    # Generate access script
    generate_access_script

    # Display information
    display_cluster_info

    log_success "All operations completed successfully!"
}

# Run main function
main "$@"
