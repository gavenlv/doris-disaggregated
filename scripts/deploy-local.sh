#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")/k8s/local"

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

check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl first."
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Kubernetes cluster not accessible. Please ensure Docker Desktop Kubernetes is running."
        exit 1
    fi
    
    log_success "Kubernetes cluster is accessible."
}

check_docker_desktop() {
    log_info "Checking Docker Desktop Kubernetes..."
    
    local context=$(kubectl config current-context)
    if [[ "$context" != *"docker-desktop"* ]]; then
        log_warning "Current context is not docker-desktop: $context"
        log_info "Switching to docker-desktop context..."
        kubectl config use-context docker-desktop 2>/dev/null || {
            log_error "Failed to switch to docker-desktop context."
            exit 1
        }
    fi
    
    log_success "Using docker-desktop context."
}

deploy_minio() {
    log_info "Deploying MinIO..."
    
    kubectl apply -f "$K8S_DIR/00-minio.yaml"
    
    log_info "Waiting for MinIO to be ready..."
    kubectl wait --for=condition=ready pod -l app=minio -n doris --timeout=120s || {
        log_warning "MinIO pod not ready within timeout, checking status..."
        kubectl get pods -n doris -l app=minio
    }
    
    log_info "Waiting for MinIO setup job..."
    kubectl wait --for=condition=complete job/minio-setup -n doris --timeout=60s 2>/dev/null || {
        log_warning "MinIO setup job may have already completed."
    }
    
    log_success "MinIO deployed successfully."
}

deploy_doris() {
    log_info "Deploying Doris components..."
    
    kubectl apply -f "$K8S_DIR/00-storageclass.yaml"
    
    log_info "Deploying Frontend..."
    kubectl apply -f "$K8S_DIR/02-fe.yaml"
    kubectl wait --for=condition=ready pod -l app=doris-fe -n doris --timeout=180s || {
        log_error "Frontend failed to start"
        kubectl describe pod -l app=doris-fe -n doris
        exit 1
    }
    log_success "Frontend is ready."
    
    log_info "Deploying Backend..."
    kubectl apply -f "$K8S_DIR/03-be.yaml"
    kubectl wait --for=condition=ready pod -l app=doris-be -n doris --timeout=180s || {
        log_error "Backend failed to start"
        kubectl describe pod -l app=doris-be -n doris
        exit 1
    }
    log_success "Backend is ready."
    
    log_info "Registering Backend to Frontend..."
    be_pod_ip=$(kubectl get pod doris-be-0 -n doris -o jsonpath='{.status.podIP}')
    if [ -n "$be_pod_ip" ]; then
        log_info "BE Pod IP: $be_pod_ip"
        kubectl exec doris-fe-0 -n doris -- mysql -h 127.0.0.1 -P 9030 -u root -e "ALTER SYSTEM ADD BACKEND '${be_pod_ip}:9050';" 2>/dev/null
        sleep 10
        backend_status=$(kubectl exec doris-fe-0 -n doris -- mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW BACKENDS\G" 2>/dev/null | grep "Alive")
        log_info "Backend status: $backend_status"
    else
        log_warning "Could not get BE pod IP, skipping automatic registration."
    fi
    
    log_success "Doris deployment completed successfully!"
}

verify_deployment() {
    log_info "Verifying deployment..."
    
    echo ""
    log_info "=== Pod Status ==="
    kubectl get pods -n doris -o wide
    
    echo ""
    log_info "=== Services ==="
    kubectl get svc -n doris
    
    echo ""
    log_info "=== PVC Status ==="
    kubectl get pvc -n doris
    
    echo ""
    log_info "=== Component Health ==="
    
    local fe_ready=$(kubectl get pod -l app=doris-fe -n doris -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
    local be_ready=$(kubectl get pod -l app=doris-be -n doris -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
    local minio_ready=$(kubectl get pod -l app=minio -n doris -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
    
    echo "  MinIO:        $([[ "$minio_ready" == "True" ]] && echo -e "${GREEN}Ready${NC}" || echo -e "${RED}Not Ready${NC}")"
    echo "  Frontend:     $([[ "$fe_ready" == "True" ]] && echo -e "${GREEN}Ready${NC}" || echo -e "${RED}Not Ready${NC}")"
    echo "  Backend:      $([[ "$be_ready" == "True" ]] && echo -e "${GREEN}Ready${NC}" || echo -e "${RED}Not Ready${NC}")"
}

test_doris() {
    log_info "Testing Doris connectivity..."
    
    kubectl port-forward svc/doris-fe 9030:9030 -n doris &
    local pf_pid=$!
    sleep 5
    
    log_info "Testing MySQL connection..."
    
    if command -v mysql &> /dev/null; then
        mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW FRONTENDS;" 2>/dev/null && {
            log_success "MySQL connection successful!"
        } || {
            log_warning "MySQL connection failed. Trying HTTP API..."
        }
    else
        log_warning "MySQL client not found, skipping MySQL test."
    fi
    
    log_info "Testing HTTP API..."
    curl -s http://127.0.0.1:8030/api/health 2>/dev/null && {
        log_success "HTTP API is accessible!"
    } || {
        kubectl port-forward svc/doris-fe 8030:8030 -n doris &
        local http_pf_pid=$!
        sleep 3
        curl -s http://127.0.0.1:8030/api/health && {
            log_success "HTTP API is accessible!"
        } || {
            log_warning "HTTP API test failed."
        }
        kill $http_pf_pid 2>/dev/null || true
    }
    
    kill $pf_pid 2>/dev/null || true
    
    log_success "Doris connectivity test completed."
}

show_access_info() {
    echo ""
    log_info "=== Access Information ==="
    echo ""
    echo "所有端口转发已在后台运行:"
    echo ""
    echo "MinIO Console:"
    echo "  URL: http://127.0.0.1:9001"
    echo "  User: minioadmin"
    echo "  Password: minioadmin"
    echo ""
    echo "Doris FE (MySQL):"
    echo "  Host: 127.0.0.1:9030"
    echo "  User: root"
    echo "  Password: (空)"
    echo "  Command: mysql -h 127.0.0.1 -P 9030 -u root"
    echo ""
    echo "Doris FE (HTTP):"
    echo "  URL: http://127.0.0.1:8030"
    echo ""
    echo "后台启动端口转发命令:"
    echo "  kubectl port-forward -n doris svc/doris-fe 9030:9030 8030:8030 &"
    echo "  kubectl port-forward -n doris svc/minio 9001:9001 &"
    echo ""
}

cleanup() {
    log_warning "Cleaning up Doris deployment..."
    kubectl delete namespace doris --ignore-not-found=true
    log_success "Cleanup completed."
}

show_help() {
    echo "Doris Local Deployment Script for Docker Desktop Kubernetes"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  deploy     Deploy MinIO and Doris (default)"
    echo "  minio      Deploy MinIO only"
    echo "  doris      Deploy Doris components only"
    echo "  verify     Verify deployment status"
    echo "  test       Test Doris connectivity"
    echo "  info       Show access information"
    echo "  cleanup    Remove all resources"
    echo "  help       Show this help message"
    echo ""
    echo "Prerequisites:"
    echo "  - Docker Desktop with Kubernetes enabled"
    echo "  - kubectl configured"
    echo ""
}

case "${1:-deploy}" in
    deploy)
        check_kubectl
        check_docker_desktop
        deploy_minio
        deploy_doris
        verify_deployment
        
        log_info "Starting port-forwards in background..."
        kubectl port-forward -n doris svc/doris-fe 9030:9030 8030:8030 &
        kubectl port-forward -n doris svc/minio 9001:9001 &
        sleep 2
        
        show_access_info
        ;;
    minio)
        check_kubectl
        check_docker_desktop
        deploy_minio
        ;;
    doris)
        check_kubectl
        check_docker_desktop
        deploy_doris
        verify_deployment
        ;;
    verify)
        verify_deployment
        ;;
    test)
        test_doris
        ;;
    info)
        show_access_info
        ;;
    cleanup)
        cleanup
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
