#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing_tools=()
    
    if ! command -v gcloud &> /dev/null; then
        missing_tools+=("gcloud")
    fi
    
    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    fi
    
    if ! command -v terraform &> /dev/null; then
        missing_tools+=("terraform")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Please install the missing tools and try again."
        exit 1
    fi
    
    log_success "All prerequisites are met."
}

deploy_infrastructure() {
    log_info "Deploying infrastructure with Terraform..."
    
    cd "$PROJECT_ROOT/terraform"
    
    if [ ! -f "terraform.tfvars" ]; then
        log_error "terraform.tfvars not found. Please create it from terraform.tfvars.example"
        exit 1
    fi
    
    terraform init
    terraform plan -out=tfplan
    terraform apply tfplan
    
    log_success "Infrastructure deployed successfully."
}

get_cluster_credentials() {
    log_info "Getting GKE cluster credentials..."
    
    local project_id=$(grep 'project_id' "$PROJECT_ROOT/terraform/terraform.tfvars" | cut -d'=' -f2 | tr -d ' "')
    local region=$(grep 'region' "$PROJECT_ROOT/terraform/terraform.tfvars" | cut -d'=' -f2 | tr -d ' "' | head -1)
    local cluster_name=$(grep 'cluster_name' "$PROJECT_ROOT/terraform/terraform.tfvars" | cut -d'=' -f2 | tr -d ' "')
    
    gcloud container clusters get-credentials "$cluster_name" --region "$region" --project "$project_id"
    
    log_success "Cluster credentials configured."
}

create_gcs_secret() {
    log_info "Creating GCS credentials secret..."
    
    local credentials_file="$PROJECT_ROOT/gcs-credentials.json"
    
    if [ ! -f "$credentials_file" ]; then
        log_error "GCS credentials file not found: $credentials_file"
        log_info "Please create a service account and download the credentials JSON file."
        exit 1
    fi
    
    kubectl create namespace doris --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret generic doris-gcs-secret \
        --from-file=google-credentials.json="$credentials_file" \
        -n doris \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_success "GCS secret created."
}

deploy_doris() {
    log_info "Deploying Doris components..."
    
    cd "$PROJECT_ROOT/k8s/base"
    
    kubectl apply -f 00-namespace-and-secrets.yaml
    
    log_info "Deploying Meta Service..."
    kubectl apply -f ms-statefulset.yaml
    kubectl wait --for=condition=ready pod -l app=doris-ms -n doris --timeout=300s || {
        log_error "Meta Service failed to start"
        exit 1
    }
    log_success "Meta Service is ready."
    
    log_info "Deploying Frontend..."
    kubectl apply -f fe-statefulset.yaml
    kubectl wait --for=condition=ready pod -l app=doris-fe -n doris --timeout=300s || {
        log_error "Frontend failed to start"
        exit 1
    }
    log_success "Frontend is ready."
    
    log_info "Deploying Backend..."
    kubectl apply -f be-statefulset.yaml
    kubectl wait --for=condition=ready pod -l app=doris-be -n doris --timeout=300s || {
        log_error "Backend failed to start"
        exit 1
    }
    log_success "Backend is ready."
    
    log_info "Deploying Compute Node..."
    kubectl apply -f cn-deployment.yaml
    kubectl wait --for=condition=ready pod -l app=doris-cn -n doris --timeout=300s || {
        log_error "Compute Node failed to start"
        exit 1
    }
    log_success "Compute Node is ready."
    
    log_info "Configuring autoscaling..."
    kubectl apply -f autoscaling.yaml
    log_success "Autoscaling configured."
    
    log_success "Doris deployment completed successfully!"
}

verify_deployment() {
    log_info "Verifying deployment..."
    
    echo ""
    log_info "Pod Status:"
    kubectl get pods -n doris -o wide
    
    echo ""
    log_info "Services:"
    kubectl get svc -n doris
    
    echo ""
    log_info "Horizontal Pod Autoscalers:"
    kubectl get hpa -n doris
    
    echo ""
    log_info "To connect to Doris:"
    echo "  kubectl port-forward svc/doris-fe 9030:9030 -n doris"
    echo "  mysql -h 127.0.0.1 -P 9030 -u root"
}

show_help() {
    echo "Doris GKE Deployment Script"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  all              Deploy everything (infrastructure + Doris)"
    echo "  infra            Deploy infrastructure only (Terraform)"
    echo "  doris            Deploy Doris components only"
    echo "  verify           Verify deployment status"
    echo "  help             Show this help message"
    echo ""
    echo "Prerequisites:"
    echo "  - gcloud CLI"
    echo "  - kubectl"
    echo "  - terraform"
    echo "  - GCS credentials file (gcs-credentials.json)"
}

case "${1:-help}" in
    all)
        check_prerequisites
        deploy_infrastructure
        get_cluster_credentials
        create_gcs_secret
        deploy_doris
        verify_deployment
        ;;
    infra)
        check_prerequisites
        deploy_infrastructure
        get_cluster_credentials
        ;;
    doris)
        check_prerequisites
        create_gcs_secret
        deploy_doris
        verify_deployment
        ;;
    verify)
        verify_deployment
        ;;
    help|*)
        show_help
        ;;
esac
